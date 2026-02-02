const Tables = @This();
const std = @import("std");
const json = std.json;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const StringArrayHashMap = std.StringArrayHashMapUnmanaged;

const log = std.log.scoped(.tables);

pub const CharacterData = @import("Tables/CharacterData.zig");
pub const SkillPatchDataBundleList = @import("Tables/SkillPatchDataBundleList.zig");
pub const WeaponBasicData = @import("Tables/WeaponBasicData.zig");
pub const CharWpnRecommendData = @import("Tables/CharWpnRecommendData.zig");
pub const DomainData = @import("Tables/DomainData.zig");

pub const StrToNum = struct {
    pub const file = "StrIdNumTable.json";
    dic: StringTable(i32),
};

pub const NumToStr = struct {
    pub const file = "NumIdStrTable.json";
    dic: IntTable(i32, []const u8),
};

character: StringArrayHashMap(CharacterData),
skill_patch: StringArrayHashMap(SkillPatchDataBundleList),
weapon_basic: StringArrayHashMap(WeaponBasicData),
str_to_num: StringArrayHashMap(StrToNum),
num_to_str: StringArrayHashMap(NumToStr),
char_wpn_recommend: StringArrayHashMap(CharWpnRecommendData),
domain_data: StringArrayHashMap(DomainData),

pub const LoadError = error{
    NotStarted,
    ReadFail,
    ParseFail,
} || Io.Cancelable || Allocator.Error;

const LoadResults = blk: {
    var field_names: []const []const u8 = &.{};

    for (@typeInfo(Tables).@"struct".fields) |field| {
        field_names = field_names ++ .{field.name};
    }

    var field_types: [field_names.len]type = undefined;
    var field_attrs: [field_names.len]std.builtin.Type.StructField.Attributes = undefined;

    for (field_names, 0..) |name, i| {
        field_types[i] = LoadError!@FieldType(Tables, name);
        field_attrs[i] = .{
            .default_value_ptr = &@as(LoadError!@FieldType(Tables, name), LoadError.NotStarted),
        };
    }

    break :blk @Struct(.auto, null, field_names, &field_types, &field_attrs);
};

pub const Owned = struct {
    tables: Tables,
    arenas: [@typeInfo(Tables).@"struct".fields.len]?ArenaAllocator,

    pub fn deinit(owned: Owned) void {
        for (owned.arenas) |maybe_arena| if (maybe_arena) |arena| {
            arena.deinit();
        };
    }
};

pub fn load(io: Io, gpa: Allocator) (error{LoadFailed} || Io.Cancelable)!Owned {
    var owned: Owned = .{
        .tables = undefined,
        .arenas = @splat(null),
    };

    errdefer owned.deinit();

    var loaders: Io.Group = .init;
    defer loaders.cancel(io);

    var results: LoadResults = .{};
    inline for (@typeInfo(Tables).@"struct".fields, 0..) |field, i| {
        owned.arenas[i] = .init(gpa);

        loaders.async(
            io,
            Loader(field.type).startLoading,
            .{ &@field(results, field.name), io, owned.arenas[i].?.allocator() },
        );
    }

    try loaders.await(io);

    var has_errors = false;

    inline for (@typeInfo(Tables).@"struct".fields) |field| {
        if (@field(results, field.name)) |table| {
            @field(owned.tables, field.name) = table;
        } else |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => |e| {
                has_errors = true;
                log.err("failed to load table '{s}': {t}", .{ field.name, e });
            },
        }
    }

    return if (!has_errors) owned else error.LoadFailed;
}

fn Loader(comptime Table: type) type {
    return struct {
        pub fn startLoading(
            result: *LoadError!Table,
            io: Io,
            arena: Allocator,
        ) Io.Cancelable!void {
            const Value = @FieldType(Table.KV, "value");

            const file = Io.Dir.cwd().openFile(io, "assets/tables/" ++ Value.file, .{}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    result.* = LoadError.ReadFail;
                    return;
                },
            };

            defer file.close(io);

            var buffer: [16384]u8 = undefined;
            var file_reader = file.reader(io, &buffer);

            var json_reader: json.Reader = .init(arena, &file_reader.interface);
            defer json_reader.deinit();

            if (json.parseFromTokenSourceLeaky(
                StringTable(Value),
                arena,
                &json_reader,
                .{ .ignore_unknown_fields = true },
            )) |st| {
                result.* = st.map;
            } else |_| {
                result.* = LoadError.ParseFail;
            }
        }
    };
}

// HashMap wrapper to deserialize from an array of ["Key": "String", "Value": {...}]
fn StringTable(comptime V: type) type {
    return struct {
        const ST = @This();

        map: StringArrayHashMap(V) = .empty,

        const IntermediateKV = struct {
            Key: []const u8,
            Value: V,
        };

        pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: json.ParseOptions) !ST {
            if (try source.nextAlloc(a, options.allocate.?) != .array_begin)
                return error.UnexpectedToken;

            var map: StringArrayHashMap(V) = .empty;
            errdefer map.deinit(a);

            while (source.peekNextTokenType()) |t| switch (t) {
                .object_begin => {
                    const kv = json.innerParse(IntermediateKV, a, source, options) catch unreachable;
                    try map.put(a, kv.Key, kv.Value);
                },
                .array_end => {
                    _ = try source.next();
                    break;
                },
                else => return error.UnexpectedToken,
            } else |err| return err;

            return .{ .map = map };
        }
    };
}

// HashMap wrapper to deserialize from an array of ["Key": Int, "Value": {...}]
fn IntTable(comptime K: type, comptime V: type) type {
    return struct {
        const ST = @This();

        map: std.AutoArrayHashMapUnmanaged(K, V) = .empty,

        const IntermediateKV = struct {
            Key: K,
            Value: V,
        };

        pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: json.ParseOptions) !ST {
            if (try source.nextAlloc(a, options.allocate.?) != .array_begin)
                return error.UnexpectedToken;

            var map: std.AutoArrayHashMapUnmanaged(K, V) = .empty;
            errdefer map.deinit(a);

            while (source.peekNextTokenType()) |t| switch (t) {
                .object_begin => {
                    const kv = json.innerParse(IntermediateKV, a, source, options) catch unreachable;
                    try map.put(a, kv.Key, kv.Value);
                },
                .array_end => {
                    _ = try source.next();
                    break;
                },
                else => return error.UnexpectedToken,
            } else |err| return err;

            return .{ .map = map };
        }
    };
}
