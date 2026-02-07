pub const pb = @import("beyond_generated");
const std = @import("std");

const enums = std.enums;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const WireType = enum(u32) {
    var_int = 0,
    int64 = 1,
    length_prefixed = 2,
    int32 = 5,

    pub fn of(comptime T: type) WireType {
        if (T == []const u8) return .length_prefixed;

        return switch (@typeInfo(T)) {
            .int, .bool, .@"enum" => .var_int,
            .float => |float| return switch (float.bits) {
                32 => .int32,
                64 => .int64,
                else => @compileError("only f32 and f64 are supported"),
            },
            .optional, .pointer => |container| of(container.child),
            .@"struct" => .length_prefixed,
            else => @compileError("unsupported type: " ++ @typeName(T)),
        };
    }
};

fn MsgIDEnum(comptime Message: type) type {
    if (comptime std.mem.startsWith(u8, Message.message_name, "SC_"))
        return pb.SCMessageID;

    if (comptime std.mem.startsWith(u8, Message.message_name, "CS_"))
        return pb.CSMessageID;

    comptime unreachable;
}

pub fn messageId(comptime Message: type) MsgIDEnum(Message) {
    comptime var lowercase: [Message.message_name.len]u8 = @splat(0);
    inline for (Message.message_name, 0..) |c, i|
        lowercase[i] = comptime std.ascii.toLower(c);

    return @field(MsgIDEnum(Message), &lowercase);
}

pub fn encodeMessage(w: *Io.Writer, message: anytype) !void {
    const Message = @TypeOf(message);

    inline for (@typeInfo(Message).@"struct".fields) |field| {
        if (comptime oneofUnion(field.type)) |_| {
            if (@field(message, field.name)) |oneof| {
                switch (oneof) {
                    inline else => |value, tag| {
                        try encodeField(w, value, @field(Message, @tagName(tag) ++ "_field_desc").number);
                    },
                }
            }
        } else {
            if (shouldEncodeField(@field(message, field.name)))
                try encodeField(w, @field(message, field.name), @field(Message, field.name ++ "_field_desc").number);
        }
    }
}

fn oneofUnion(comptime T: type) ?std.builtin.Type.Union {
    return switch (@typeInfo(T)) {
        .optional => |optional| switch (@typeInfo(optional.child)) {
            .@"union" => |u| u,
            else => null,
        },
        else => null,
    };
}

pub fn encodingLength(message: anytype) usize {
    var prober = Io.Writer.Discarding.init("");
    encodeMessage(&prober.writer, message) catch unreachable;
    return prober.fullCount();
}

fn shouldEncodeField(value: anytype) bool {
    const Value = @TypeOf(value);
    if (Repeated(Value)) |_| {
        return value.items.len != 0;
    } else if (Optional(Value)) |_| {
        return value != null;
    } else {
        if (Value == []const u8) return value.len != 0 else switch (@typeInfo(Value)) {
            .int => return value != 0,
            .bool => return value,
            .float => return value != 0,
            .@"enum" => return @as(i32, @intFromEnum(value)) != 0,
            .@"struct" => return true,
            else => @compileError("unsupported type: " ++ @typeName(Value)),
        }
    }
}

fn encodeField(w: *Io.Writer, value: anytype, comptime number: u32) !void {
    const Value = @TypeOf(value);
    if (Repeated(Value)) |_| {
        for (value.items) |item| try encodeField(w, item, number);
    } else if (Optional(Value)) |_| {
        if (value) |item| try encodeField(w, item, number);
    } else {
        try writeVarInt(w, comptime wireTag(number, .of(Value)));
        if (Value == []const u8) try writeBytes(w, value) else switch (@typeInfo(Value)) {
            .int => try writeVarInt(w, value),
            .bool => try writeVarInt(w, @as(u8, if (value) 1 else 0)),
            .float => |float| {
                const BackingInt = if (float.bits == 32) u32 else if (float.bits == 64) u64 else @compileError("encountered invalid float type: " ++ @typeName(Value));
                try w.writeInt(BackingInt, @bitCast(value), .little);
            },
            .@"enum" => try writeVarInt(w, @intFromEnum(value)),
            .@"struct" => {
                try writeVarInt(w, encodingLength(value));
                try encodeMessage(w, value);
            },
            else => @compileError("unsupported type: " ++ @typeName(Value)),
        }
    }
}

fn writeBytes(w: *Io.Writer, bytes: []const u8) !void {
    try writeVarInt(w, bytes.len);
    try w.writeAll(bytes);
}

fn Repeated(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"struct" => if (@hasField(T, "items")) switch (@typeInfo(@FieldType(T, "items"))) {
            .pointer => |pointer| if (T == std.ArrayList(pointer.child)) return pointer.child else null,
            else => null,
        } else null,
        else => null,
    };
}

fn Optional(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => null,
    };
}

inline fn wireTag(comptime field_number: u32, comptime wire_type: WireType) u32 {
    return (field_number << 3) | @intFromEnum(wire_type);
}

fn writeVarInt(w: *Io.Writer, value: anytype) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) {
        try w.writeByte(@intCast(0x80 | (v & 0x7F)));
    } else try w.writeByte(@intCast(v & 0x7F));
}

pub fn decodeMessage(r: *Io.Reader, allocator: Allocator, comptime Message: type) !Message {
    @setEvalBranchQuota(100_000);

    const fields = @typeInfo(Message).@"struct".fields;
    comptime var field_names: []const []const u8 = &.{};
    comptime var oneof_names: []const []const u8 = &.{};
    comptime var oneof_types: []const type = &.{};

    inline for (fields) |field| {
        if (@hasDecl(Message, field.name ++ "_field_desc")) {
            field_names = field_names ++ .{field.name};
        } else if (comptime oneofUnion(field.type)) |oneof| {
            oneof_names = oneof_names ++ .{field.name};
            oneof_types = oneof_types ++ .{field.type};
            inline for (oneof.fields) |oneof_field| {
                field_names = field_names ++ .{oneof_field.name};
            }
        }
    }

    const MessageField = std.meta.FieldEnum(Message);

    const FieldNumber = comptime blk: {
        var field_numbers: [field_names.len]u32 = @splat(0);
        for (field_names, 0..) |name, i| {
            field_numbers[i] = @field(Message, name ++ "_field_desc").number;
        }

        break :blk @Enum(u32, .exhaustive, field_names, &field_numbers);
    };

    var message: Message = .init;

    while (readVarInt(r, u32) catch null) |wire_tag| {
        const wire_type = enums.fromInt(WireType, wire_tag & 7) orelse return error.MalformedProtobuf;
        if (fields.len == 0) {
            try skipField(r, wire_type);
            continue;
        }

        const field_variant = enums.fromInt(FieldNumber, wire_tag >> 3) orelse {
            try skipField(r, wire_type);
            continue;
        };

        switch (field_variant) {
            inline else => |variant| {
                const field_name = @tagName(variant);
                if (@hasField(Message, field_name) and comptime oneofUnion(@FieldType(Message, field_name)) == null) {
                    const field = fields[@intFromEnum(comptime std.meta.stringToEnum(MessageField, field_name).?)];

                    if (Repeated(field.type)) |Item| {
                        if ((comptime WireType.of(Item) != .length_prefixed) and wire_type == .length_prefixed) {
                            const length = try readVarInt(r, usize); // packed list of scalar values
                            var reader = Io.Reader.fixed(try r.take(length));
                            while (decodeField(&reader, allocator, Item, .of(Item)) catch null) |value|
                                try @field(message, field.name).append(allocator, value);
                        } else {
                            const item = try decodeField(r, allocator, Item, wire_type);
                            try @field(message, field.name).append(allocator, item);
                        }
                    } else {
                        @field(message, field.name) = try decodeField(r, allocator, field.type, wire_type);
                    }
                } else inline for (oneof_names, oneof_types) |oneof_name, Oneof| inline for (@typeInfo(std.meta.Child(Oneof)).@"union".fields) |oneof_field| {
                    if (comptime std.mem.eql(u8, oneof_field.name, field_name)) {
                        @field(message, oneof_name) = @unionInit(std.meta.Child(Oneof), field_name, try decodeField(r, allocator, oneof_field.type, wire_type));
                        break;
                    }
                };
            },
        }
    }

    return message;
}

fn decodeField(r: *Io.Reader, allocator: Allocator, comptime T: type, wire_type: WireType) !T {
    if (Optional(T)) |C|
        return try decodeField(r, allocator, C, wire_type)
    else if (T == []const u8)
        return try r.readAlloc(allocator, try readVarInt(r, usize))
    else switch (@typeInfo(T)) {
        .int => return try readVarInt(r, T),
        .bool => return (try readVarInt(r, u8)) != 0,
        .float => |float| {
            const BackingInt = if (float.bits == 32) u32 else if (float.bits == 64) u64 else @compileError("encountered float type of incompatible width: " ++ float.bits);
            return @bitCast(try r.takeInt(BackingInt, .little));
        },
        .@"enum" => return enums.fromInt(T, try readVarInt(r, i32)) orelse @enumFromInt(0),
        .@"struct" => {
            var reader = Io.Reader.fixed(try r.take(try readVarInt(r, usize)));
            return try decodeMessage(&reader, allocator, T);
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

fn readVarInt(r: *Io.Reader, comptime T: type) !T {
    var shift: std.math.Log2Int(T) = 0;
    var result: T = 0;

    while (true) : (shift += 7) {
        const byte = try r.takeByte();
        result |= @as(T, @intCast(byte & 0x7F)) << shift;
        if ((byte & 0x80) != 0x80) return result;
        if (shift >= @bitSizeOf(T) - 7) return error.MalformedProtobuf;
    }
}

fn skipField(r: *Io.Reader, wire_type: WireType) !void {
    switch (wire_type) {
        .var_int => _ = try readVarInt(r, u64),
        .int32 => try r.discardAll(4),
        .int64 => try r.discardAll(8),
        .length_prefixed => try r.discardAll(try readVarInt(r, usize)),
    }
}
