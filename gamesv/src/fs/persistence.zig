const std = @import("std");
const fs = @import("../fs.zig");
const logic = @import("../logic.zig");
const Assets = @import("../Assets.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Player = logic.Player;

const player_data_dir = "store/player/";
const base_component_file = "base_data";
const server_game_vars_file = "server_game_vars";
const client_game_vars_file = "client_game_vars";
const unlocked_systems_file = "unlocked_systems";
const bitset_file = "bitset";
const char_bag_path = "char_bag";
const char_bag_chars_file = "chars";
const char_bag_teams_file = "teams";
const char_bag_meta_file = "meta";
const item_bag_path = "item_bag";
const item_bag_weapon_depot_file = "weapon_depot";

const default_team: []const []const u8 = &.{
    "chr_0026_lastrite",
    "chr_0009_azrila",
    "chr_0016_laevat",
    "chr_0022_bounda",
};

const LoadPlayerError = error{
    InputOutput,
    SystemResources,
} || Allocator.Error || Io.Cancelable;

const log = std.log.scoped(.persistence);

// Opens or creates data directory for the player with specified uid.
pub fn openPlayerDataDir(io: Io, uid: u64) !Io.Dir {
    var dir_path_buf: [player_data_dir.len + 20]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_path_buf, player_data_dir ++ "{d}", .{uid}) catch
        unreachable; // Since we're printing a u64, it shouldn't exceed the buffer.

    const cwd: Io.Dir = .cwd();
    return cwd.openDir(io, dir_path, .{}) catch |open_err| switch (open_err) {
        error.Canceled => |e| return e,
        error.FileNotFound => cwd.createDirPathOpen(io, dir_path, .{}) catch |create_err| switch (create_err) {
            error.Canceled => |e| return e,
            else => return error.InputOutput,
        },
        else => return error.InputOutput,
    };
}

// Loads player data. Creates components that do not exist.
// Resets component to default if its data is corrupted.
pub fn loadPlayer(io: Io, gpa: Allocator, assets: *const Assets, uid: u64) !Player {
    const data_dir = try openPlayerDataDir(io, uid);
    defer data_dir.close(io);

    var result: Player = undefined;

    result.base = try loadBaseComponent(io, data_dir, uid);

    result.game_vars = try loadGameVarsComponent(io, gpa, data_dir, uid);
    errdefer result.game_vars.deinit(gpa);

    result.unlock = try loadUnlockComponent(io, gpa, data_dir, uid);
    errdefer result.unlock.deinit(gpa);

    result.item_bag = try loadItemBagComponent(io, gpa, data_dir);
    errdefer result.item_bag.deinit(gpa);

    result.char_bag = loadCharBagComponent(io, gpa, data_dir, uid) catch |err| switch (err) {
        error.NeedsReset => try createDefaultCharBagComponent(io, gpa, assets, &result.item_bag, data_dir),
        else => |e| return e,
    };

    errdefer result.char_bag.deinit(gpa);

    result.bitset = loadBitsetComponent(io, data_dir, uid) catch |err| switch (err) {
        error.NeedsReset => try createDefaultBitsetComponent(io, data_dir, assets),
        else => |e| return e,
    };

    return result;
}

fn loadBaseComponent(
    io: Io,
    data_dir: Io.Dir,
    uid: u64,
) !Player.Base {
    return fs.loadStruct(Player.Base, io, data_dir, base_component_file) catch |err| switch (err) {
        inline error.FileNotFound, error.ChecksumMismatch, error.ReprSizeMismatch => |e| reset: {
            if (e == error.ChecksumMismatch) {
                log.err(
                    "checksum mismatched for base_data of player {d}, resetting to defaults.",
                    .{uid},
                );
            }

            if (e == error.ReprSizeMismatch) {
                log.err(
                    "struct layout mismatched for base_data of player {d}, resetting to defaults.",
                    .{uid},
                );
            }

            var defaults: Player.Base = .init;
            try fs.saveStruct(Player.Base, &defaults, io, data_dir, base_component_file);

            break :reset defaults;
        },
        error.Canceled => |e| return e,
        else => return error.InputOutput,
    };
}

fn loadGameVarsComponent(io: Io, gpa: Allocator, data_dir: Io.Dir, uid: u64) !Player.GameVars {
    var game_vars: Player.GameVars = undefined;

    game_vars.server_vars = try loadArray(
        Player.GameVars.ServerVar,
        io,
        gpa,
        data_dir,
        uid,
        server_game_vars_file,
        Player.GameVars.default_server_vars,
    );

    errdefer gpa.free(game_vars.server_vars);

    game_vars.client_vars = try loadArray(
        Player.GameVars.ClientVar,
        io,
        gpa,
        data_dir,
        uid,
        client_game_vars_file,
        Player.GameVars.default_client_vars,
    );

    errdefer gpa.free(game_vars.client_vars);

    return game_vars;
}

fn loadUnlockComponent(io: Io, gpa: Allocator, data_dir: Io.Dir, uid: u64) !Player.Unlock {
    var unlock: Player.Unlock = undefined;

    unlock.unlocked_systems = try loadArray(
        Player.Unlock.SystemType,
        io,
        gpa,
        data_dir,
        uid,
        unlocked_systems_file,
        Player.Unlock.default_unlocked_systems,
    );

    errdefer gpa.free(unlock.unlocked_systems);

    return unlock;
}

fn loadCharBagComponent(io: Io, gpa: Allocator, data_dir: Io.Dir, uid: u64) !Player.CharBag {
    const char_bag_dir = data_dir.openDir(io, char_bag_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NeedsReset,
        error.Canceled => |e| return e,
        else => return error.InputOutput,
    };

    defer char_bag_dir.close(io);

    var chars = fs.loadMultiArrayList(Player.CharBag.Char, io, char_bag_dir, gpa, char_bag_chars_file) catch |err| switch (err) {
        error.FileNotFound, error.ChecksumMismatch, error.ReprSizeMismatch => return error.NeedsReset,
        error.Canceled, error.OutOfMemory => |e| return e,
        else => return error.InputOutput,
    };

    errdefer chars.deinit(gpa);

    var teams = fs.loadMultiArrayList(Player.CharBag.Team, io, char_bag_dir, gpa, char_bag_teams_file) catch |err| switch (err) {
        error.FileNotFound, error.ChecksumMismatch, error.ReprSizeMismatch => return error.NeedsReset,
        error.Canceled, error.OutOfMemory => |e| return e,
        else => return error.InputOutput,
    };

    errdefer teams.deinit(gpa);

    if (teams.len == 0) return error.NeedsReset;

    const meta = fs.loadStruct(Player.CharBag.Meta, io, char_bag_dir, char_bag_meta_file) catch |err| switch (err) {
        inline error.FileNotFound, error.ChecksumMismatch, error.ReprSizeMismatch => |e| reset: {
            if (e == error.ChecksumMismatch) {
                log.err(
                    "checksum mismatched for char bag metadata of player {d}, resetting to defaults.",
                    .{uid},
                );
            }

            if (e == error.ReprSizeMismatch) {
                log.err(
                    "struct layout mismatched for char bag metadata of player {d}, resetting to defaults.",
                    .{uid},
                );
            }

            const defaults: Player.CharBag.Meta = .{ .curr_team_index = 0 };
            try fs.saveStruct(Player.CharBag.Meta, &defaults, io, data_dir, base_component_file);

            break :reset defaults;
        },
        error.Canceled => |e| return e,
        else => return error.InputOutput,
    };

    if (meta.curr_team_index >= teams.len)
        return error.NeedsReset;

    return .{
        .chars = chars,
        .teams = teams,
        .meta = meta,
    };
}

fn createDefaultCharBagComponent(
    io: Io,
    gpa: Allocator,
    assets: *const Assets,
    // Depends on ItemBag because it has to create weapons for the new characters.
    item_bag: *Player.ItemBag,
    data_dir: Io.Dir,
) !Player.CharBag {
    const char_bag_dir = data_dir.createDirPathOpen(io, char_bag_path, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.InputOutput,
    };

    defer char_bag_dir.close(io);

    var chars = try std.MultiArrayList(
        Player.CharBag.Char,
    ).initCapacity(gpa, assets.table(.character).count());

    errdefer chars.deinit(gpa);

    for (assets.table(.character).keys(), assets.table(.character).values()) |id, char_data| {
        const char_id_num = assets.strToNum(.char_id, id) orelse continue;

        if (!assets.char_skill_map.map.contains(id))
            continue; // Dummy Character

        const weapon_template_id: i32 = blk: {
            if (assets.table(.char_wpn_recommend).getPtr(id)) |recommend| {
                if (recommend.weaponIds1.len > 0)
                    break :blk assets.strToNum(.item_id, recommend.weaponIds1[0]).?;
            }

            for (assets.table(.weapon_basic).values()) |weapon| {
                if (weapon.weaponType == char_data.weaponType)
                    break :blk assets.strToNum(.item_id, weapon.weaponId).?;
            } else continue; // No suitable weapon, don't create this character because it'll be broken in-game.
        };

        try item_bag.weapon_depot.append(gpa, .{
            .template_id = weapon_template_id,
            .exp = 0,
            .weapon_lv = 1,
            .refine_lv = 0,
            .breakthrough_lv = 0,
            .attach_gem_id = 0,
        });

        const weapon_id: Player.ItemBag.WeaponIndex = @enumFromInt(
            @as(u64, @intCast(item_bag.weapon_depot.len - 1)),
        );

        const hp = for (char_data.attributes[0].Attribute.attrs) |attr| {
            if (attr.attrType == .max_hp)
                break attr.attrValue;
        } else 100;

        const sp = for (char_data.attributes[0].Attribute.attrs) |attr| {
            if (attr.attrType == .max_ultimate_sp)
                break attr.attrValue;
        } else 100;

        chars.appendAssumeCapacity(.{
            .template_id = char_id_num,
            .level = 1,
            .exp = 0,
            .is_dead = false,
            .hp = hp,
            .ultimate_sp = @floatCast(sp),
            .weapon_id = weapon_id,
            .own_time = 0,
            .equip_medicine_id = 0,
            .potential_level = 5,
        });
    }

    var teams = try std.MultiArrayList(Player.CharBag.Team).initCapacity(gpa, 1);
    errdefer teams.deinit(gpa);

    var result: Player.CharBag = .{
        .chars = chars,
        .teams = teams,
        .meta = .{ .curr_team_index = 0 },
    };

    var team: Player.CharBag.Team.SlotArray = @splat(.empty);

    for (default_team, 0..) |char_template_id, i| {
        const id_num = assets.strToNum(.char_id, char_template_id).?;
        const char_index = result.charIndexById(id_num).?;
        team[i] = .fromCharIndex(char_index);
    }

    result.teams.appendAssumeCapacity(.{
        .name = .constant("reversedrooms"),
        .char_team = team,
        .leader_index = team[0].charIndex().?,
    });

    try saveItemBagComponent(io, data_dir, item_bag);

    try fs.saveMultiArrayList(Player.CharBag.Char, &result.chars, io, char_bag_dir, char_bag_chars_file);
    try fs.saveMultiArrayList(Player.CharBag.Team, &result.teams, io, char_bag_dir, char_bag_teams_file);

    try fs.saveStruct(Player.CharBag.Meta, &result.meta, io, char_bag_dir, char_bag_meta_file);

    return result;
}

fn loadItemBagComponent(io: Io, gpa: Allocator, data_dir: Io.Dir) !Player.ItemBag {
    const item_bag_dir = data_dir.openDir(io, "item_bag", .{}) catch |open_err| switch (open_err) {
        error.FileNotFound => data_dir.createDirPathOpen(io, "item_bag", .{}) catch |create_err| switch (create_err) {
            error.Canceled => |e| return e,
            else => return error.InputOutput,
        },
        error.Canceled => |e| return e,
        else => return error.InputOutput,
    };

    defer item_bag_dir.close(io);

    var weapon_depot = fs.loadMultiArrayList(Player.ItemBag.Weapon, io, item_bag_dir, gpa, item_bag_weapon_depot_file) catch |err| switch (err) {
        error.FileNotFound,
        error.ChecksumMismatch,
        error.ReprSizeMismatch,
        => std.MultiArrayList(Player.ItemBag.Weapon).empty,
        error.Canceled, error.OutOfMemory => |e| return e,
        else => return error.InputOutput,
    };

    errdefer weapon_depot.deinit(gpa);

    return .{ .weapon_depot = weapon_depot };
}

pub fn saveItemBagComponent(io: Io, data_dir: Io.Dir, component: *const Player.ItemBag) !void {
    const item_bag_dir = data_dir.createDirPathOpen(io, item_bag_path, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.InputOutput,
    };

    defer item_bag_dir.close(io);

    try fs.saveMultiArrayList(Player.ItemBag.Weapon, &component.weapon_depot, io, item_bag_dir, item_bag_weapon_depot_file);
}

pub fn saveCharBagComponent(
    io: Io,
    data_dir: Io.Dir,
    component: *const Player.CharBag,
    comptime what: union(enum) { all, chars, teams, meta },
) !void {
    const char_bag_dir = data_dir.createDirPathOpen(io, char_bag_path, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.InputOutput,
    };

    defer char_bag_dir.close(io);

    if (what == .all or what == .chars) {
        try fs.saveMultiArrayList(Player.CharBag.Char, &component.chars, io, char_bag_dir, char_bag_chars_file);
    }

    if (what == .all or what == .teams) {
        try fs.saveMultiArrayList(Player.CharBag.Team, &component.teams, io, char_bag_dir, char_bag_teams_file);
    }

    if (what == .all or what == .meta) {
        try fs.saveStruct(Player.CharBag.Meta, &component.meta, io, char_bag_dir, char_bag_meta_file);
    }
}

fn loadBitsetComponent(io: Io, data_dir: Io.Dir, uid: u64) !Player.Bitset {
    return fs.loadStruct(Player.Bitset, io, data_dir, bitset_file) catch |err| switch (err) {
        inline error.FileNotFound, error.ChecksumMismatch, error.ReprSizeMismatch => |e| {
            if (e == error.ChecksumMismatch) {
                log.err(
                    "checksum mismatched for bitset of player {d}, resetting to defaults.",
                    .{uid},
                );
            }

            if (e == error.ReprSizeMismatch) {
                log.err(
                    "struct layout mismatched for bitset of player {d}, resetting to defaults.",
                    .{uid},
                );
            }

            return error.NeedsReset;
        },
        error.Canceled => |e| return e,
        else => return error.InputOutput,
    };
}

fn createDefaultBitsetComponent(io: Io, data_dir: Io.Dir, assets: *const Assets) !Player.Bitset {
    var bitset: Player.Bitset = .init;

    for (assets.level_config_table.values()) |config| {
        bitset.set(.level_have_been, @intCast(config.idNum)) catch |err| switch (err) {
            error.ValueOutOfRange => { // This means we have to increase Bitset.max_value
                std.debug.panic(
                    "createDefaultBitsetComponent: value is out of range! ({d}/{d})",
                    .{ config.idNum, Player.Bitset.max_value },
                );
            },
        };

        bitset.set(.level_map_first_view, @intCast(config.idNum)) catch unreachable;
        bitset.set(.read_level, @intCast(config.idNum)) catch unreachable;
    }

    try fs.saveStruct(Player.Bitset, &bitset, io, data_dir, bitset_file);
    return bitset;
}

fn loadArray(
    comptime T: type,
    io: Io,
    gpa: Allocator,
    data_dir: Io.Dir,
    uid: u64,
    sub_path: []const u8,
    defaults: []const T,
) ![]T {
    return fs.loadDynamicArray(T, io, data_dir, gpa, sub_path) catch |err| switch (err) {
        inline error.FileNotFound, error.ChecksumMismatch, error.ReprSizeMismatch => |e| reset: {
            if (e == error.ChecksumMismatch) {
                log.err(
                    "checksum mismatched for '{s}' of player {d}, resetting to defaults.",
                    .{ sub_path, uid },
                );
            }

            if (e == error.ReprSizeMismatch) {
                log.err(
                    "struct layout mismatched for '{s}' of player {d}, resetting to defaults.",
                    .{ sub_path, uid },
                );
            }

            try fs.saveDynamicArray(T, defaults, io, data_dir, sub_path);
            break :reset try gpa.dupe(T, defaults);
        },
        error.Canceled, error.OutOfMemory => |e| return e,
        else => return error.InputOutput,
    };
}
