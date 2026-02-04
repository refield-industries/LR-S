const std = @import("std");
const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");

const Player = logic.Player;
const messaging = logic.messaging;

pub fn onSceneSetTrackPoint(
    request: messaging.Request(pb.CS_SCENE_SET_TRACK_POINT),
    assets: *const Assets,
    scene: Player.Component(.scene),
    change_scene_tx: logic.event.Sender(.change_scene_begin),
    cur_scene_modified_tx: logic.event.Sender(.current_scene_modified),
) !void {
    const log = std.log.scoped(.scene_set_track_point);

    const track_point = request.message.track_point orelse return;
    const point_config = assets.map_mark_table.get(track_point.inst_id) orelse {
        log.debug("invalid point instance id: '{s}'", .{track_point.inst_id});
        return;
    };

    const teleport_validation = point_config.teleportValidationData() orelse {
        // Not a teleport point.
        return;
    };

    const validation_config = assets.teleport_validation_table.teleportValidationDatas.map.getPtr(teleport_validation.teleportValidationId) orelse {
        log.debug(
            "teleport validation config '{s}' doesn't exist",
            .{teleport_validation.teleportValidationId},
        );
        return;
    };

    const level_config = assets.level_config_table.getPtr(validation_config.sceneId) orelse {
        log.debug("level with id '{s}' doesn't exist", .{validation_config.sceneId});
        return;
    };

    scene.data.current.level_id = level_config.idNum;
    scene.data.current.position = .{
        validation_config.position.x,
        validation_config.position.y,
        validation_config.position.z,
    };

    try cur_scene_modified_tx.send(.{});
    try change_scene_tx.send(.{});

    log.info(
        "transitioning to scene '{s}', position: {any}",
        .{ validation_config.sceneId, scene.data.current.position },
    );
}
