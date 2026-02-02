const std = @import("std");
const pb = @import("proto").pb;
const Session = @import("../Session.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.auth);

pub const Error = error{LoginFailed} || Session.SendError || Allocator.Error || Io.Cancelable;

pub const Result = struct {
    uid: u64, // It's a string in SC_LOGIN tho
};

pub fn processLoginRequest(io: Io, session: *Session, request: *const pb.CS_LOGIN) Error!Result {
    log.info("login request received: {any}", .{request});

    const uid = std.fmt.parseInt(u64, request.uid, 10) catch
        return error.LoginFailed;

    try session.send(pb.SC_LOGIN{
        .uid = request.uid,
        .server_time = @intCast((Io.Clock.real.now(io) catch Io.Timestamp.zero).toSeconds()),
        .server_time_zone = 3,
    });

    return .{ .uid = uid };
}
