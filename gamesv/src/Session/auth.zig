const std = @import("std");
const pb = @import("proto").pb;
const mem = @import("common").mem;
const Session = @import("../Session.zig");
const PlayerId = @import("../logic.zig").World.PlayerId;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.auth);

pub const Error = error{LoginFailed} || Session.SendError || Allocator.Error || Io.Cancelable;

pub const Result = struct {
    uid: mem.LimitedString(PlayerId.max_length),

    pub const FromUidSliceError = error{
        TooLongString,
        InvalidCharacters,
    };

    pub fn fromUidSlice(slice: []const u8) FromUidSliceError!Result {
        const result: Result = .{ .uid = try .init(slice) };
        for (slice) |c| if (!std.ascii.isAlphanumeric(c)) {
            return error.InvalidCharacters;
        };

        return result;
    }
};

pub fn processLoginRequest(io: Io, session: *Session, request: *const pb.CS_LOGIN) Error!Result {
    log.info("login request received: {any}", .{request});

    const result = Result.fromUidSlice(request.uid) catch |err| {
        log.err("invalid UID received: {t}", .{err});
        return error.LoginFailed;
    };

    try session.send(pb.SC_LOGIN{
        .uid = request.uid,
        .server_time = @intCast((Io.Clock.real.now(io) catch Io.Timestamp.zero).toSeconds()),
        .server_time_zone = 3,
    });

    return result;
}
