const std = @import("std");
const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Session = @import("../../Session.zig");

const Player = logic.Player;

pub fn syncAllBitset(
    rx: logic.event.Receiver(.login),
    session: *Session,
    bitset: Player.Component(.bitset),
) !void {
    _ = rx;

    var sync_all_bitset: pb.SC_SYNC_ALL_BITSET = .init;
    var sets_buf: [Player.Bitset.Type.count]pb.BITSET_DATA = undefined;
    sync_all_bitset.bitset = .initBuffer(&sets_buf);

    for (&bitset.data.sets, 1..) |*set, i| {
        sync_all_bitset.bitset.appendAssumeCapacity(.{
            .type = @intCast(i),
            .value = .{ .items = @constCast(&set.masks) },
        });
    }

    try session.send(sync_all_bitset);
}
