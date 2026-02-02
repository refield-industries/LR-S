// Describes player-local state of the world.
const World = @This();
const std = @import("std");
const logic = @import("../logic.zig");
const Session = @import("../Session.zig");
const Assets = @import("../Assets.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const PlayerId = struct { uid: u64 };

player_id: PlayerId,
session: *Session, // TODO: should it be here this way? Do we need an abstraction?
res: logic.Resource,
player: logic.Player,

pub fn init(
    session: *Session,
    assets: *const Assets,
    uid: u64,
    player: logic.Player,
    gpa: Allocator,
    io: Io,
) World {
    _ = gpa;
    return .{
        .player_id = .{ .uid = uid },
        .session = session,
        .player = player,
        .res = .init(assets, io),
    };
}

pub fn deinit(world: *World, gpa: Allocator) void {
    world.player.deinit(gpa);
}

pub const GetComponentError = error{
    ComponentUnavailable,
};

pub fn getComponentByType(world: *World, comptime T: type) GetComponentError!T {
    switch (T) {
        PlayerId => return world.player_id,
        *Session => return world.session,
        *logic.Resource.PingTimer => return &world.res.ping_timer,
        *const Assets => return world.res.assets,
        Io => return world.res.io(),
        else => {
            if (comptime logic.Player.isComponent(T)) {
                return world.player.getComponentByType(T);
            }

            @compileError("World.getComponentByType(" ++ @typeName(T) ++ ") is unsupported");
        },
    }
}
