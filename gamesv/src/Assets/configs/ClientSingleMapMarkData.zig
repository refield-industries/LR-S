const ClientSingleMapMarkData = @This();

basicData: MapMarkBasicData,
detailedData: ?MapMarkDetailedData = null,

pub const MapMarkBasicData = struct {
    templateId: []const u8,
    markInstId: []const u8,
    pos: struct {
        x: f32,
        y: f32,
        z: f32,
    },
};

pub const MapMarkDetailedData = struct {
    logicIdGlobal: ?u64 = null,
    teleportValidationId: ?[]const u8 = null,

    pub const TeleportValidationData = struct {
        logicIdGlobal: u64,
        teleportValidationId: []const u8,
    };
};

pub fn teleportValidationData(
    csmmd: *const ClientSingleMapMarkData,
) ?MapMarkDetailedData.TeleportValidationData {
    const details = csmmd.detailedData orelse return null;

    return .{
        .logicIdGlobal = details.logicIdGlobal orelse return null,
        .teleportValidationId = details.teleportValidationId orelse return null,
    };
}
