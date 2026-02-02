const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Session = @import("../../Session.zig");

// Sends the dummy 'SYNC' messages for the components that aren't implemented yet.
pub fn loginSyncStub(
    rx: logic.event.Receiver(.login),
    session: *Session,
) !void {
    _ = rx;

    try session.send(pb.SC_ADVENTURE_SYNC_ALL{
        .level = 1,
        .world_level = 1,
        .unlock_world_level = 1,
    });

    try session.send(pb.SC_ADVENTURE_BOOK_SYNC{
        .adventure_book_stage = 1,
    });

    try session.send(pb.SC_SYNC_ALL_MINI_GAME.init);
    try session.send(pb.SC_SYNC_ALL_MAIL.init);
    try session.send(pb.SC_KITE_STATION_SYNC_ALL.init);
    try session.send(pb.SC_SYNC_ALL_GUIDE.init);
    try session.send(pb.SC_GLOBAL_EFFECT_SYNC_ALL.init);
    try session.send(pb.SC_SYNC_ALL_DOODAD_GROUP.init);
    try session.send(pb.SC_SETTLEMENT_SYNC_ALL.init);
    try session.send(pb.SC_DOMAIN_DEPOT_SYNC_ALL_INFO.init);
    try session.send(pb.SC_SYNC_ALL_DIALOG.init);
    try session.send(pb.SC_SYNC_ALL_ROLE_SCENE.init);
    try session.send(pb.SC_SYNC_ALL_WIKI.init);
    try session.send(pb.SC_RECYCLE_BIN_SYSTEM_SYNC_ALL.init);
    try session.send(pb.SC_SYNC_ALL_STAT.init);
    try session.send(pb.SC_BP_SYNC_ALL{
        .season_data = .init,
        .level_data = .init,
        .bp_track_mgr = .init,
        .bp_task_mgr = .init,
    });
    try session.send(pb.SC_SYNC_ALL_MISSION.init);
    try session.send(pb.SC_SPACESHIP_SYNC{
        .assist_data = .init,
        .expedition_data = .init,
    });

    try session.send(pb.SC_ACHIEVE_SYNC{
        .achieve_display_info = .init,
    });
}
