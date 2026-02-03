const std = @import("std");

teleportValidationDatas: std.json.ArrayHashMap(TeleportValidationData),

pub const TeleportValidationData = struct {
    id: []const u8,
    teleportReason: i32,
    sceneId: []const u8,
    position: struct { x: f32, y: f32, z: f32 },
};
