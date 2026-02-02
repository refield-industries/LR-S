const std = @import("std");
const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Session = @import("../../Session.zig");
const fs = @import("../../fs.zig");

const Io = std.Io;
const Player = logic.Player;

const log = std.log.scoped(.player_saves);

pub fn saveCharBagTeams(
    _: logic.event.Receiver(.char_bag_team_modified),
    char_bag: Player.Component(.char_bag),
    player_id: logic.World.PlayerId,
    io: Io,
) !void {
    const data_dir = fs.persistence.openPlayerDataDir(io, player_id.uid) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| {
            log.err(
                "failed to open data dir for player with uid {d}: {t}",
                .{ player_id.uid, e },
            );
            return;
        },
    };

    defer data_dir.close(io);

    fs.persistence.saveCharBagComponent(io, data_dir, char_bag.data, .teams) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| {
            log.err("save failed: {t}", .{e});
            return;
        },
    };
}
