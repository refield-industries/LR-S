const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Session = @import("../../Session.zig");

const Player = logic.Player;

pub fn syncBaseDataOnLogin(
    rx: logic.event.Receiver(.login),
    session: *Session,
    base_comp: Player.Component(.base),
) !void {
    _ = rx;

    try session.send(pb.SC_SYNC_BASE_DATA{
        .roleid = base_comp.data.role_id,
        .role_name = base_comp.data.role_name.view(),
        .level = @intFromEnum(base_comp.data.level),
        .gender = @enumFromInt(@intFromEnum(base_comp.data.gender)),
        .short_id = "1",
    });
}
