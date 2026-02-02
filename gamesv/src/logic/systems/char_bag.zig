const std = @import("std");
const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const Session = @import("../../Session.zig");

const Player = logic.Player;

pub fn syncCharBag(
    rx: logic.event.Receiver(.login),
    assets: *const Assets,
    session: *Session,
    char_bag: Player.Component(.char_bag),
    arena: logic.Resource.Allocator(.arena),
) !void {
    _ = rx;

    var sync_char_bag: pb.SC_SYNC_CHAR_BAG_INFO = .{
        .curr_team_index = @intCast(char_bag.data.meta.curr_team_index),
        .temp_team_info = .init,
        .scope_name = 1,
        .max_char_team_member_count = comptime @intCast(Player.CharBag.Team.slots_count),
    };

    const teams = char_bag.data.teams.slice();

    try sync_char_bag.team_info.ensureTotalCapacity(arena.interface, teams.len);
    const all_team_slots = try arena.interface.alloc([4]u64, teams.len);

    for (
        0..,
        teams.items(.name),
        teams.items(.char_team),
        teams.items(.leader_index),
    ) |i, name, slots, leader_index| {
        var char_team: std.ArrayList(u64) = .initBuffer(&all_team_slots[i]);

        for (slots) |slot| if (slot != .empty) {
            char_team.appendAssumeCapacity(@intFromEnum(slot) + 1);
        };

        sync_char_bag.team_info.appendAssumeCapacity(.{
            .team_name = name.view(),
            .char_team = .{ .items = char_team.items },
            .leaderid = leader_index.objectId(),
        });
    }

    const chars = char_bag.data.chars.slice();
    try sync_char_bag.char_info.ensureTotalCapacity(arena.interface, chars.len);

    for (0..chars.len) |i| {
        const index: Player.CharBag.CharIndex = @enumFromInt(i);

        const template_id = assets.numToStr(.char_id, chars.items(.template_id)[i]) orelse continue;
        const skills = assets.char_skill_map.map.getPtr(template_id).?;

        var char_info: pb.CHAR_INFO = .{
            .objid = index.objectId(),
            .templateid = template_id,
            .char_type = .default_type,
            .level = chars.items(.level)[i],
            .exp = chars.items(.exp)[i],
            .is_dead = chars.items(.is_dead)[i],
            .weapon_id = chars.items(.weapon_id)[i].instId(),
            .own_time = chars.items(.own_time)[i],
            .equip_medicine_id = chars.items(.equip_medicine_id)[i],
            .potential_level = chars.items(.potential_level)[i],
            .normal_skill = skills.normal_skill,
            .battle_info = .{ .hp = chars.items(.hp)[i], .ultimatesp = chars.items(.ultimate_sp)[i] },
            .skill_info = .{
                .normal_skill = skills.normal_skill,
                .combo_skill = skills.combo_skill,
                .ultimate_skill = skills.ultimate_skill,
                .disp_normal_attack_skill = skills.attack_skill,
            },
            .talent = .{},
            .battle_mgr_info = .{
                .msg_generation = @truncate(index.objectId()),
                .battle_inst_id = @truncate(index.objectId()),
                .part_inst_info = .{},
            },
            .trial_data = .{},
        };

        try char_info.skill_info.?.level_info.ensureTotalCapacity(arena.interface, skills.all_skills.len);
        for (skills.all_skills) |name| {
            char_info.skill_info.?.level_info.appendAssumeCapacity(.{
                .skill_id = name,
                .skill_level = 1,
                .skill_max_level = 1,
                .skill_enhanced_level = 1,
            });
        }

        try sync_char_bag.char_info.append(arena.interface, char_info);
    }

    try session.send(sync_char_bag);
}
