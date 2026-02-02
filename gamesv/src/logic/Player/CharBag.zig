const CharBag = @This();
const std = @import("std");
const common = @import("common");
const Player = @import("../Player.zig");

const Allocator = std.mem.Allocator;

teams: std.MultiArrayList(Team),
chars: std.MultiArrayList(Char),
meta: Meta,

pub const CharIndex = enum(u64) {
    _,

    // Returns an 'objectId' for network serialization.
    pub fn objectId(i: CharIndex) u64 {
        return @intFromEnum(i) + 1;
    }

    pub fn fromObjectId(id: u64) CharIndex {
        return @enumFromInt(id - 1);
    }
};

pub fn deinit(bag: *CharBag, gpa: Allocator) void {
    bag.teams.deinit(gpa);
    bag.chars.deinit(gpa);
}

pub fn charIndexById(bag: *const CharBag, template_id: i32) ?CharIndex {
    const idx: u64 = @intCast(
        std.mem.findScalar(i32, bag.chars.items(.template_id), template_id) orelse
            return null,
    );

    return @enumFromInt(idx);
}

pub fn charIndexWithWeapon(bag: *const CharBag, weapon: Player.ItemBag.WeaponIndex) ?CharIndex {
    const idx: u64 = @intCast(
        std.mem.findScalar(Player.ItemBag.WeaponIndex, bag.chars.items(.weapon_id), weapon) orelse
            return null,
    );

    return @enumFromInt(idx);
}

// Checks:
// 1. Existence of the team.
// 2. Existence of the specified character index in the team.
pub fn ensureTeamMember(bag: *const CharBag, team_index: usize, char_index: CharIndex) error{
    InvalidTeamIndex,
    NotTeamMember,
}!void {
    if (team_index < 0 or team_index >= bag.teams.len) {
        return error.InvalidTeamIndex;
    }

    const char_team = &bag.teams.items(.char_team)[team_index];

    _ = std.mem.findScalar(u64, @ptrCast(char_team), @intFromEnum(char_index)) orelse
        return error.NotTeamMember;
}

pub const Meta = struct {
    curr_team_index: u32,
};

pub const Team = struct {
    pub const slots_count: usize = 4;
    pub const SlotArray = [Team.slots_count]Team.Slot;

    pub const Slot = enum(u64) {
        empty = std.math.maxInt(u64),
        _,

        pub fn charIndex(s: Slot) ?CharIndex {
            return if (s != .empty) @enumFromInt(@intFromEnum(s)) else null;
        }

        pub fn fromCharIndex(i: CharIndex) Slot {
            return @enumFromInt(@intFromEnum(i));
        }
    };

    name: common.mem.LimitedString(15) = .empty,
    char_team: [slots_count]Slot = @splat(Slot.empty),
    leader_index: CharIndex,
};

pub const Char = struct {
    template_id: i32,
    level: i32,
    exp: i32,
    is_dead: bool,
    hp: f64,
    ultimate_sp: f32,
    weapon_id: Player.ItemBag.WeaponIndex,
    own_time: i64,
    equip_medicine_id: i32,
    potential_level: u32,
};
