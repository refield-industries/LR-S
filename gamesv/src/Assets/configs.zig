const std = @import("std");
const json = std.json;

pub const CommonSkillConfig = @import("configs/CommonSkillConfig.zig");
pub const LevelConfig = @import("configs/LevelConfig.zig");
pub const ClientSingleMapMarkData = @import("configs/ClientSingleMapMarkData.zig");
pub const TeleportValidationDataTable = @import("configs/TeleportValidationDataTable.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn loadJsonConfig(
    comptime T: type,
    io: Io,
    arena: Allocator,
    filename: []const u8,
) !T {
    const config_dir = try Io.Dir.cwd().openDir(io, "assets/configs/", .{});
    defer config_dir.close(io);

    const file = try config_dir.openFile(io, filename, .{});
    defer file.close(io);

    var buffer: [16384]u8 = undefined;
    var file_reader = file.reader(io, &buffer);

    var json_reader: json.Reader = .init(arena, &file_reader.interface);
    defer json_reader.deinit();

    return try json.parseFromTokenSourceLeaky(
        T,
        arena,
        &json_reader,
        .{ .ignore_unknown_fields = true },
    );
}
