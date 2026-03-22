const std = @import("std");
const routes = @import("../routes.zig");
const encryption = @import("../encryption.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;
const Base64Encoder = std.base64.standard.Encoder;

const config_key = [16]u8{ 0x71, 0x99, 0xBC, 0xE9, 0x47, 0xC3, 0xA7, 0xF9, 0x20, 0x27, 0x76, 0xA0, 0x2B, 0x1F, 0x87, 0x64 };
const config_key_cn = [16]u8{ 0x5A, 0x0C, 0x6E, 0x82, 0x5E, 0x6A, 0x56, 0x2A, 0xF1, 0xEE, 0xBD, 0xE4, 0x9B, 0xA9, 0xD7, 0xB4 };

fn handleRemoteGameConfig(io: Io, gpa: Allocator, request: *Request, encryption_key: [16]u8,) routes.Error!void {
    var response_buffer: [1024]u8 = undefined;
    var body = try request.respondStreaming(&response_buffer, .{});

    const response: RemoteGameCfg = .{
        .enableHotUpdate = false,
        .mockLogin = true,
    };

    const content = try std.fmt.allocPrint(gpa, "{f}", .{std.json.fmt(response, .{})});
    defer gpa.free(content);

    const io_source: std.Random.IoSource = .{ .io = io };
    const ciphertext = try encryption.encryptAlloc(gpa, io_source.interface(), encryption_key, content);
    defer gpa.free(ciphertext);

    try body.writer.print("{b64}", .{ciphertext});
    try body.end();
}

pub fn getRemoteGameConfig(io: Io, gpa: Allocator, request: *Request) routes.Error!void {
    return handleRemoteGameConfig(io, gpa, request, config_key);
}

pub fn getCNRemoteGameConfig(io: Io, gpa: Allocator, request: *Request) routes.Error!void {
    return handleRemoteGameConfig(io, gpa, request, config_key_cn);
}

const RemoteGameCfg = struct {
    enableHotUpdate: bool,
    mockLogin: bool,
};
