const std = @import("std");
const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Session = @import("../../Session.zig");
const Assets = @import("../../Assets.zig");

const Player = logic.Player;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const default_level = "map02_lv001";

pub fn enterSceneOnLogin(
    rx: logic.event.Receiver(.login),
    session: *Session,
    assets: *const Assets,
    base_comp: Player.Component(.base),
) !void {
    _ = rx;

    const level_config = assets.level_config_table.getPtr(default_level).?;
    const position: pb.VECTOR = .{
        .X = level_config.playerInitPos.x,
        .Y = level_config.playerInitPos.y,
        .Z = level_config.playerInitPos.z,
    };

    try session.send(pb.SC_CHANGE_SCENE_BEGIN_NOTIFY{
        .scene_num_id = level_config.idNum,
        .position = position,
        .pass_through_data = .init,
    });

    try session.send(pb.SC_ENTER_SCENE_NOTIFY{
        .role_id = base_comp.data.role_id,
        .scene_num_id = level_config.idNum,
        .position = position,
        .pass_through_data = .init,
    });
}

pub fn refreshCharTeam(
    rx: logic.event.Receiver(.char_bag_team_modified),
    char_bag: Player.Component(.char_bag),
    sync_tx: logic.event.Sender(.sync_self_scene),
) !void {
    switch (rx.payload.modification) {
        .set_leader => return, // Doesn't require any action from server.
        .set_char_team => if (rx.payload.team_index == char_bag.data.meta.curr_team_index) {
            // If the current active team has been modified, it has to be re-spawned.
            try sync_tx.send(.{ .reason = .team_modified });
        },
    }
}

pub fn syncSelfScene(
    rx: logic.event.Receiver(.sync_self_scene),
    session: *Session,
    arena: logic.Resource.Allocator(.arena),
    char_bag: logic.Player.Component(.char_bag),
    assets: *const Assets,
) !void {
    const reason: pb.SELF_INFO_REASON_TYPE = switch (rx.payload.reason) {
        .entrance => .SLR_ENTER_SCENE,
        .team_modified => .SLR_CHANGE_TEAM,
    };

    const level_config = assets.level_config_table.getPtr(default_level).?;
    const position: pb.VECTOR = .{
        .X = level_config.playerInitPos.x,
        .Y = level_config.playerInitPos.y,
        .Z = level_config.playerInitPos.z,
    };

    const team_index = char_bag.data.meta.curr_team_index;
    const leader_index = char_bag.data.teams.items(.leader_index)[team_index];

    var self_scene_info: pb.SC_SELF_SCENE_INFO = .{
        .scene_num_id = level_config.idNum,
        .self_info_reason = @intFromEnum(reason),
        .teamInfo = .{
            .team_type = .CHAR_BAG_TEAM_TYPE_MAIN,
            .team_index = @intCast(team_index),
            .cur_leader_id = leader_index.objectId(),
            .team_change_token = 0,
        },
        .scene_impl = .{ .empty = .{} },
        .detail = .{},
    };

    for (char_bag.data.teams.items(.char_team)[team_index]) |slot| {
        const char_index = slot.charIndex() orelse continue;
        const char_template_id_num = char_bag.data.chars.items(.template_id)[@intFromEnum(char_index)];
        const char_template_id = assets.numToStr(.char_id, char_template_id_num).?;
        const char_data = assets.table(.character).getPtr(char_template_id).?;

        var scene_char: pb.SCENE_CHARACTER = .{
            .level = 1,
            .battle_info = .{
                .msg_generation = @intCast(char_index.objectId()),
                .battle_inst_id = @intCast(char_index.objectId()),
                .part_inst_info = .{},
            },
            .common_info = .{
                .id = char_index.objectId(),
                .templateid = char_template_id,
                .position = position,
                .rotation = .{},
                .scene_num_id = level_config.idNum,
            },
        };

        for (char_data.attributes[0].Attribute.attrs) |attr| {
            if (attr.attrType == .max_hp)
                scene_char.common_info.?.hp = attr.attrValue;

            try scene_char.attrs.append(arena.interface, .{
                .attr_type = @intFromEnum(attr.attrType),
                .basic_value = attr.attrValue,
                .value = attr.attrValue,
            });
        }

        scene_char.battle_info.?.skill_list = try packCharacterSkills(
            arena.interface,
            assets,
            char_template_id,
        );

        try self_scene_info.detail.?.char_list.append(arena.interface, scene_char);
    }

    try session.send(self_scene_info);
}

fn packCharacterSkills(
    arena: Allocator,
    assets: *const Assets,
    template_id: []const u8,
) Allocator.Error!ArrayList(pb.SERVER_SKILL) {
    const char_skills = assets.char_skill_map.map.getPtr(template_id).?.all_skills;
    var list: ArrayList(pb.SERVER_SKILL) = try .initCapacity(
        arena,
        char_skills.len + assets.common_skill_config.config.Character.skillConfigs.len,
    );

    errdefer comptime unreachable;

    for (char_skills, 1..) |name, i| {
        list.appendAssumeCapacity(.{
            .skill_id = .{
                .id_impl = .{ .str_id = name },
                .type = .BATTLE_ACTION_OWNER_TYPE_SKILL,
            },
            .blackboard = .{},
            .inst_id = (100 + i),
            .level = 1,
            .source = .BATTLE_SKILL_SOURCE_DEFAULT,
            .potential_lv = 1,
            .is_enable = true,
        });
    }

    for (assets.common_skill_config.config.Character.skillConfigs, char_skills.len + 1..) |config, i| {
        list.appendAssumeCapacity(.{
            .skill_id = .{
                .id_impl = .{ .str_id = config.skillId },
                .type = .BATTLE_ACTION_OWNER_TYPE_SKILL,
            },
            .blackboard = .{},
            .inst_id = (100 + i),
            .level = 1,
            .source = .BATTLE_SKILL_SOURCE_DEFAULT,
            .potential_lv = 1,
            .is_enable = true,
        });
    }

    return list;
}
