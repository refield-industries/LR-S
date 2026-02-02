const std = @import("std");
const routes = @import("../routes.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;

pub fn get(io: Io, gpa: Allocator, request: *Request) routes.Error!void {
    _ = io;
    _ = gpa;

    var response_buffer: [1024]u8 = undefined;
    var body = try request.respondStreaming(&response_buffer, .{});

    const response: ServerList = .{
        .servers = &.{.{ .name = "LR", .addr = "127.0.0.1", .port = 30000 }},
    };

    try body.writer.print("{f}", .{std.json.fmt(response, .{})});
    try body.end();
}

const ServerDesc = struct {
    name: []const u8,
    addr: []const u8,
    port: i32,
};

const ServerList = struct {
    servers: []const ServerDesc,
};
