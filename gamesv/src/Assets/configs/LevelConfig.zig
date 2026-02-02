id: []const u8,
idNum: i32,
scope: u8,
isSeamless: bool,
mapIdStr: []const u8,
isDimensionLevel: bool,
dimensionSourceLevelId: []const u8,
startPos: Vector,
playerInitPos: Vector,
playerInitRot: Vector,

pub const Vector = struct {
    x: f32,
    y: f32,
    z: f32,
};
