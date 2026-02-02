const std = @import("std");
const routes = @import("routes.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Server = std.http.Server;

const net = Io.net;
const request_timeout: Io.Duration = .fromSeconds(5);

pub const ConcurrencyAvailability = enum {
    undetermined,
    unavailable,
    available,
};

pub const IoOptions = struct {
    // Indicates whether Io.concurrent() should be considered.
    concurrency: ConcurrencyAvailability,
    // Specifies the preferred system clock.
    preferred_clock: Io.Clock,
};

pub fn processClient(
    io: Io,
    stream: net.Stream,
    gpa: Allocator,
    options: IoOptions,
) Io.Cancelable!void {
    const log = std.log.scoped(.http);
    defer stream.close(io);

    log.debug("new connection from '{f}'", .{stream.socket.address});
    defer log.debug("client from '{f}' disconnected", .{stream.socket.address});

    var recv_buffer: [8192]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;

    var reader = stream.reader(io, &recv_buffer);
    var writer = stream.writer(io, &send_buffer);

    var server: Server = .init(&reader.interface, &writer.interface);
    var request = receiveRequest(io, options, &server) catch |err| switch (err) {
        error.Canceled, error.ConcurrencyUnavailable => return,
        else => |e| {
            log.err("failed to receive request from '{f}': {t}", .{ stream.socket.address, e });
            return;
        },
    };

    log.info(
        "received request from '{f}': {s} ({t})",
        .{ stream.socket.address, request.head.target, request.head.method },
    );

    routes.process(io, gpa, &request) catch |err| switch (err) {
        error.Canceled => return,
        error.RouteNotFound => {
            log.warn(
                "route '{s}' not found, requested by: '{f}'",
                .{ request.head.target, stream.socket.address },
            );

            request.respond("Not Found", .{ .status = .not_found }) catch return;
        },
        error.MethodNotAllowed => request.respond("Method Not Allowed", .{ .status = .method_not_allowed }) catch
            return,
        else => |e| log.err(
            "failed to process request from '{f}': {t}",
            .{ stream.socket.address, e },
        ),
    };
}

fn receiveRequest(io: Io, options: IoOptions, server: *Server) !Server.Request {
    return switch (options.concurrency) {
        .undetermined => unreachable,
        .unavailable => try server.receiveHead(),
        .available => {
            var receive = try io.concurrent(Server.receiveHead, .{server});
            errdefer _ = receive.cancel(io) catch {};

            var sleep = try io.concurrent(Io.sleep, .{ io, request_timeout, options.preferred_clock });
            defer sleep.cancel(io) catch {};

            return switch (try io.select(.{
                .receive = &receive,
                .sleep = &sleep,
            })) {
                .sleep => try receive.cancel(io),
                .receive => |request| request,
            };
        },
    };
}
