const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Session = @import("../../Session.zig");

const Player = logic.Player;

pub fn syncAllUnlock(
    rx: logic.event.Receiver(.login),
    session: *Session,
    unlock: Player.Component(.unlock),
    arena: logic.Resource.Allocator(.arena),
) !void {
    _ = rx;

    var sync_all_unlock: pb.SC_SYNC_ALL_UNLOCK = .init;
    try sync_all_unlock.unlock_systems.appendSlice(
        arena.interface,
        @ptrCast(unlock.data.unlocked_systems),
    );

    try session.send(sync_all_unlock);
}
