const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;

const version = @import("routes/version.zig");
const config = @import("routes/config.zig");
const server_list = @import("routes/server_list.zig");

const routes = .{
    .{ "/api/game/get_latest", version.getOnlineAppVersion },
    .{ "/api/remote_config/v2/1003/prod-obt/default/Windows/game_config", config.getRemoteGameConfig },
    .{ "/get_server_list", server_list.get },
    .{ "/api/game/get_latest_resources", version.getLatestResources },
};

const Route = blk: {
    var field_names: [routes.len][:0]const u8 = undefined;
    var field_values: [routes.len]usize = undefined;

    for (routes, 0..) |route, i| {
        const path, _ = route;
        field_names[i] = path;
        field_values[i] = i;
    }

    break :blk @Enum(usize, .exhaustive, &field_names, &field_values);
};

pub const ProcessError = error{ RouteNotFound, MethodNotAllowed } || Error;
pub const Error = Io.Cancelable || Request.ExpectContinueError || Allocator.Error;

pub fn process(
    io: Io,
    gpa: Allocator,
    request: *Request,
) ProcessError!void {
    const log = std.log.scoped(.routing);

    switch (request.head.method) {
        .GET, .POST => {},
        else => |method| {
            log.debug("method not allowed: {t}", .{method});
            return error.MethodNotAllowed;
        },
    }

    const path = if (std.mem.findScalar(u8, request.head.target, '?')) |query_i|
        request.head.target[0..query_i]
    else
        request.head.target;

    const route = std.meta.stringToEnum(Route, path) orelse
        return error.RouteNotFound;

    switch (route) {
        inline else => |tag| inline for (routes) |pair| {
            const name, const processFn = pair;
            if (comptime std.mem.eql(u8, name, @tagName(tag))) {
                try processFn(io, gpa, request);
                break;
            }
        } else comptime unreachable,
    }
}
