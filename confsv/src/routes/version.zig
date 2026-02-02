const std = @import("std");
const routes = @import("../routes.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;

pub fn getOnlineAppVersion(io: Io, gpa: Allocator, request: *Request) routes.Error!void {
    _ = io;
    _ = gpa;

    var response_buffer: [1024]u8 = undefined;
    var body = try request.respondStreaming(&response_buffer, .{});

    const response: OnlineAppVersionResponse = .{
        .action = 0,
        .version = "1.0.14",
        .request_version = "1.0.14",
        .pkg = .{
            .packs = &.{},
            .total_size = 0,
            .file_path = "https://beyond.hg-cdn.com/YDUTE5gscDZ229CW/1.0/update/6/6/Windows/1.0.14_Qk2mXHuAH1JWKF37/files",
            .url = "",
            .md5 = "",
            .package_size = "0",
            .file_id = "0",
            .sub_channel = "6",
            .game_files_md5 = "c36ad08e5d4a7cfd580228971d7a4563",
        },
        .patch = null,
        .state = 0,
        .launcher_action = 0,
    };

    try body.writer.print("{f}", .{std.json.fmt(response, .{})});
    try body.end();
}

pub fn getLatestResources(io: Io, gpa: Allocator, request: *Request) routes.Error!void {
    _ = io;
    _ = gpa;

    var response_buffer: [1024]u8 = undefined;
    var body = try request.respondStreaming(&response_buffer, .{});

    const response: ResVersionData = .{
        .resources = &.{
            .{
                .name = "main",
                .version = "5439650-20",
                .path = "https://beyond.hg-cdn.com/YDUTE5gscDZ229CW/1.0/resource/Windows/main/5439650-20_PEuAF7OENsVNjc1L/files",
            },
            .{
                .name = "initial",
                .version = "5439650-20",
                .path = "https://beyond.hg-cdn.com/YDUTE5gscDZ229CW/1.0/resource/Windows/initial/5439650-20_2HA0Xw0M0B0XWdBV/files",
            },
        },
        .configs = "{\"kick_flag\":false}",
        .res_version = "initial_5439650-20_main_5439650-20",
        .patch_index_path = "",
        .domain = "https://beyond.hg-cdn.com",
    };

    try body.writer.print("{f}", .{std.json.fmt(response, .{})});
    try body.end();
}

const OnlineAppVersionResponse = struct {
    action: i32,
    version: []const u8,
    request_version: []const u8,
    pkg: struct {
        packs: []const struct {},
        total_size: u64,
        file_path: []const u8,
        url: []const u8,
        md5: []const u8,
        package_size: []const u8,
        file_id: []const u8,
        sub_channel: []const u8,
        game_files_md5: []const u8,
    },
    patch: ?struct {},
    state: u32,
    launcher_action: u32,
};

const ResVersionData = struct {
    resources: []const struct {
        name: []const u8,
        version: []const u8,
        path: []const u8,
    },
    configs: []const u8,
    res_version: []const u8,
    patch_index_path: []const u8,
    domain: []const u8,
};
