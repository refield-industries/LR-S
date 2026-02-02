const Assets = @This();
const std = @import("std");
pub const configs = @import("Assets/configs.zig");
pub const Tables = @import("Assets/Tables.zig");
pub const CharacterSkillMap = @import("Assets/CharacterSkillMap.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const meta = std.meta;
const log = std.log.scoped(.assets);

arena: ArenaAllocator,
owned_tables: Tables.Owned,
char_skill_map: CharacterSkillMap,
str_to_num_dicts: IndexDictionaries.StrToNum,
num_to_str_dicts: IndexDictionaries.NumToStr,
common_skill_config: configs.CommonSkillConfig,
level_config_table: std.StringArrayHashMapUnmanaged(configs.LevelConfig),

pub const IdGroup = enum {
    char_id,
    item_id,
};

const IndexDictionaries = blk: {
    const names = meta.fieldNames(IdGroup);

    break :blk .{
        .StrToNum = @Struct(.auto, null, names, &@splat(*const Tables.StrToNum), &@splat(.{})),
        .NumToStr = @Struct(.auto, null, names, &@splat(*const Tables.NumToStr), &@splat(.{})),
    };
};

pub fn load(io: Io, gpa: Allocator) !Assets {
    const owned_tables = try Tables.load(io, gpa);
    errdefer owned_tables.deinit();

    var arena: ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const char_skill_map = try CharacterSkillMap.init(arena.allocator(), &owned_tables.tables);

    var str_to_num_dicts: IndexDictionaries.StrToNum = undefined;
    var num_to_str_dicts: IndexDictionaries.NumToStr = undefined;

    inline for (@typeInfo(IdGroup).@"enum".fields) |field| {
        @field(str_to_num_dicts, field.name) = owned_tables.tables.str_to_num.getPtr(field.name) orelse {
            log.err("missing str-to-num dictionary: " ++ field.name, .{});
            return error.MissingData;
        };

        @field(num_to_str_dicts, field.name) = owned_tables.tables.num_to_str.getPtr(field.name) orelse {
            log.err("missing num-to-str dictionary: " ++ field.name, .{});
            return error.MissingData;
        };
    }

    const common_skill_config = try configs.loadJsonConfig(
        configs.CommonSkillConfig,
        io,
        arena.allocator(),
        configs.CommonSkillConfig.file,
    );

    const level_config_table = try configs.loadJsonConfig(
        std.json.ArrayHashMap(configs.LevelConfig),
        io,
        arena.allocator(),
        "LevelConfigTable.json",
    );

    return .{
        .arena = arena,
        .owned_tables = owned_tables,
        .char_skill_map = char_skill_map,
        .str_to_num_dicts = str_to_num_dicts,
        .num_to_str_dicts = num_to_str_dicts,
        .common_skill_config = common_skill_config,
        .level_config_table = level_config_table.map,
    };
}

pub fn deinit(assets: *Assets) void {
    assets.owned_tables.deinit();
    assets.arena.deinit();
}

pub inline fn table(
    assets: *const Assets,
    comptime t: std.meta.FieldEnum(Tables),
) *const @FieldType(Tables, @tagName(t)) {
    return &@field(assets.owned_tables.tables, @tagName(t));
}

pub fn strToNum(
    assets: *const Assets,
    comptime group: IdGroup,
    str: []const u8,
) ?i32 {
    const str_to_num = @field(assets.str_to_num_dicts, @tagName(group));
    return str_to_num.dic.map.get(str);
}

pub fn numToStr(
    assets: *const Assets,
    comptime group: IdGroup,
    num: i32,
) ?[]const u8 {
    const num_to_str = @field(assets.num_to_str_dicts, @tagName(group));
    return num_to_str.dic.map.get(num);
}
