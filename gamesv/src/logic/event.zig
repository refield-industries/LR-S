const std = @import("std");
pub const kinds = @import("event/kinds.zig");

const Allocator = std.mem.Allocator;
const meta = std.meta;

// Describes the event receiver
pub fn Receiver(comptime kind: meta.Tag(Kind)) type {
    return struct {
        pub const rx_event_kind = kind;
        pub const Event = @field(
            kinds,
            @typeInfo(kinds).@"struct".decls[@intFromEnum(kind)].name,
        );

        payload: Event,
    };
}

// Describes the event sender
pub fn Sender(comptime kind: meta.Tag(Kind)) type {
    return struct {
        pub const tx_event_kind = kind;
        pub const Event = @field(
            kinds,
            @typeInfo(kinds).@"struct".decls[@intFromEnum(kind)].name,
        );

        event_queue: *Queue,

        pub fn send(s: @This(), event: Event) Allocator.Error!void {
            try s.event_queue.push(@unionInit(Kind, @tagName(kind), event));
        }
    };
}

pub const Queue = struct {
    arena: Allocator,
    deque: std.Deque(Kind),

    pub fn init(arena: Allocator) Queue {
        return .{ .arena = arena, .deque = .empty };
    }

    pub fn push(queue: *Queue, event: Kind) Allocator.Error!void {
        try queue.deque.pushBack(queue.arena, event);
    }
};

pub const Kind = blk: {
    var types: []const type = &.{};
    var indices: []const u16 = &.{};
    var names: []const []const u8 = &.{};

    for (@typeInfo(kinds).@"struct".decls, 0..) |decl, i| {
        const declaration = @field(kinds, decl.name);
        if (@TypeOf(declaration) != type) continue;
        if (meta.activeTag(@typeInfo(declaration)) == .@"struct") {
            indices = indices ++ .{@as(u16, @intCast(i))};
            types = types ++ .{@field(kinds, decl.name)};
            names = names ++ .{toSnakeCase(decl.name)};
        }
    }

    const EventTag = @Enum(u16, .exhaustive, names, indices[0..names.len]);
    break :blk @Union(.auto, EventTag, names, types[0..names.len], &@splat(.{}));
};

inline fn toSnakeCase(comptime name: []const u8) []const u8 {
    var result: []const u8 = "";

    for (name, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i != 0) result = result ++ "_";
            result = result ++ .{std.ascii.toLower(c)};
        } else result = result ++ .{c};
    }

    return result;
}
