const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const messaging = logic.messaging;

const Level = logic.Level;
const Player = logic.Player;

pub fn onSceneLoadFinish(
    _: messaging.Request(pb.CS_SCENE_LOAD_FINISH),
    sync_self_scene_tx: logic.event.Sender(.sync_self_scene),
) !void {
    try sync_self_scene_tx.send(.{ .reason = .entrance });
}

pub fn onMoveObjectMove(
    request: messaging.Request(pb.CS_MOVE_OBJECT_MOVE),
    char_bag: Player.Component(.char_bag),
    scene: Player.Component(.scene),
    level: *Level,
    cur_scene_modified_tx: logic.event.Sender(.current_scene_modified),
) !void {
    const team_index = char_bag.data.meta.curr_team_index;
    const leader_index = char_bag.data.teams.items(.leader_index)[team_index];

    for (request.message.move_info.items) |move_info| {
        if (move_info.scene_num_id != scene.data.current.level_id) continue;
        const motion = move_info.motion_info orelse continue;

        const position: Level.Object.Vector = if (motion.position) |v| .{
            .x = v.X,
            .y = v.Y,
            .z = v.Z,
        } else continue;

        const rotation: Level.Object.Vector = if (motion.rotation) |v| .{
            .x = v.X,
            .y = v.Y,
            .z = v.Z,
        } else continue;

        const net_id: Level.Object.NetID = @enumFromInt(move_info.objid);
        const handle = level.getObjectByNetId(net_id) orelse continue;
        level.moveObject(handle, position, rotation);

        if (@intFromEnum(net_id) == leader_index.objectId() and motion.state == .MOTION_WALK) {
            scene.data.current.position = .{
                position.x,
                position.y,
                position.z,
            };

            scene.data.current.rotation = .{
                rotation.x,
                rotation.y,
                rotation.z,
            };

            try cur_scene_modified_tx.send(.{});
        }
    }
}
