const Scene = @This();

current: Current,

pub const Current = struct {
    level_id: i32,
    position: [3]f32,
    rotation: [3]f32,
};
