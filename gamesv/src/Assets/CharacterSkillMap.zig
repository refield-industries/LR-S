// Maps character ids to list of their skills.
const CharacterSkillMap = @This();
const std = @import("std");

const Tables = @import("Tables.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.skill_map);

map: std.StringArrayHashMapUnmanaged(CharacterSkills),

const CharacterSkills = struct {
    all_skills: []const []const u8,
    combo_skill: []const u8,
    normal_skill: []const u8,
    attack_skill: []const u8,
    ultimate_skill: []const u8,
};

pub fn init(arena: Allocator, tables: *const Tables) !CharacterSkillMap {
    var result: CharacterSkillMap = .{ .map = .empty };

    for (tables.character.keys()) |char_id| {
        var skill_ids: std.ArrayList([]const u8) = .empty;
        var combo_skill: ?[]const u8 = null;
        var normal_skill: ?[]const u8 = null;
        var attack_skill: ?[]const u8 = null;
        var ultimate_skill: ?[]const u8 = null;

        for (tables.skill_patch.keys()) |skill_id| {
            if (std.mem.startsWith(u8, skill_id, char_id)) {
                try skill_ids.append(arena, skill_id);

                if (std.mem.find(u8, skill_id, "normal_skill") != null) {
                    normal_skill = skill_id;
                } else if (std.mem.find(u8, skill_id, "combo_skill") != null) {
                    combo_skill = skill_id;
                } else if (std.mem.find(u8, skill_id, "ultimate_skill") != null) {
                    ultimate_skill = skill_id;
                } else if (std.mem.find(u8, skill_id, "_attack1") != null) {
                    attack_skill = skill_id;
                }
            }
        }

        if (skill_ids.items.len == 0) // Dummy Character
            continue;

        if (combo_skill == null) {
            log.err("no combo_skill for {s}", .{char_id});
            return error.MalformedData;
        }

        if (normal_skill == null) {
            log.err("no normal_skill for {s}", .{char_id});
            return error.MalformedData;
        }

        if (attack_skill == null) {
            log.err("no attack_skill for {s}", .{char_id});
            return error.MalformedData;
        }

        if (ultimate_skill == null) {
            log.err("no ultimate_skill for {s}", .{char_id});
            return error.MalformedData;
        }

        try result.map.put(arena, char_id, .{
            .combo_skill = combo_skill.?,
            .normal_skill = normal_skill.?,
            .attack_skill = attack_skill.?,
            .ultimate_skill = ultimate_skill.?,
            .all_skills = skill_ids.items,
        });
    }

    return result;
}
