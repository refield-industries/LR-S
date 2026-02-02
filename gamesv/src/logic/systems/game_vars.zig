const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Session = @import("../../Session.zig");

const Player = logic.Player;

pub fn syncAllGameVars(
    rx: logic.event.Receiver(.login),
    session: *Session,
    game_vars: Player.Component(.game_vars),
    arena: logic.Resource.Allocator(.arena),
) !void {
    _ = rx;

    var sync_all_game_var: pb.SC_SYNC_ALL_GAME_VAR = .init;
    try sync_all_game_var.server_vars.ensureTotalCapacity(arena.interface, game_vars.data.server_vars.len);
    try sync_all_game_var.client_vars.ensureTotalCapacity(arena.interface, game_vars.data.client_vars.len);

    for (game_vars.data.server_vars) |sv| {
        sync_all_game_var.server_vars.appendAssumeCapacity(
            .{ .key = @intFromEnum(sv.key), .value = sv.value },
        );
    }

    for (game_vars.data.client_vars) |cv| {
        sync_all_game_var.client_vars.appendAssumeCapacity(
            .{ .key = cv.key, .value = cv.value },
        );
    }

    try session.send(sync_all_game_var);
}
