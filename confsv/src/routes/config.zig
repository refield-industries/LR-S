const std = @import("std");
const routes = @import("../routes.zig");
const encryption = @import("../encryption.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const Base64Encoder = std.base64.standard.Encoder;

const config_key = [16]u8{ 0x71, 0x99, 0xBC, 0xE9, 0x47, 0xC3, 0xA7, 0xF9, 0x20, 0x27, 0x76, 0xA0, 0x2B, 0x1F, 0x87, 0x64 };

pub fn getRemoteGameConfig(io: Io, gpa: Allocator, request: *Request) routes.Error!void {
    var response_buffer: [1024]u8 = undefined;
    var body = try request.respondStreaming(&response_buffer, .{});

    const response: RemoteGameCfg = .{
        .enableHotUpdate = false,
        .mockLogin = true,
    };

    const content = try std.fmt.allocPrint(gpa, "{f}", .{std.json.fmt(response, .{})});
    defer gpa.free(content);

    const io_source: std.Random.IoSource = .{ .io = io };
    const ciphertext = try encryption.encryptAlloc(gpa, io_source.interface(), config_key, content);
    defer gpa.free(ciphertext);

    try body.writer.print("{b64}", .{ciphertext});
    try body.end();
}

const RemoteGameCfg = struct {
    enableHotUpdate: bool,
    mockLogin: bool,
};
