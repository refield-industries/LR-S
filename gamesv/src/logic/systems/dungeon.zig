const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Session = @import("../../Session.zig");

pub fn syncFullDungeonStatus(
    rx: logic.event.Receiver(.login),
    session: *Session,
) !void {
    _ = rx;

    // TODO
    try session.send(pb.SC_SYNC_FULL_DUNGEON_STATUS{
        .cur_stamina = 200,
        .max_stamina = 200,
    });
}
