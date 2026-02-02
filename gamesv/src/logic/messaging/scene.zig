const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const messaging = logic.messaging;

pub fn onSceneLoadFinish(
    _: messaging.Request(pb.CS_SCENE_LOAD_FINISH),
    sync_self_scene_tx: logic.event.Sender(.sync_self_scene),
) !void {
    try sync_self_scene_tx.send(.{ .reason = .entrance });
}
