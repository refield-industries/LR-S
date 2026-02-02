const Resource = @This();
const std = @import("std");
const mem = std.mem;
const Assets = @import("../Assets.zig");

const Io = std.Io;

pub const AllocatorKind = enum {
    gpa,
    arena,
};

pub const PingTimer = struct {
    io: Io,
    last_client_ts: u64 = 0,

    pub fn serverTime(pt: PingTimer) u64 {
        return if (Io.Clock.real.now(pt.io)) |ts|
            @intCast(ts.toMilliseconds())
        else |_|
            pt.last_client_ts;
    }
};

assets: *const Assets,
ping_timer: PingTimer,

pub fn init(assets: *const Assets, io_impl: Io) Resource {
    return .{
        .assets = assets,
        .ping_timer = .{ .io = io_impl },
    };
}

pub fn io(res: *const Resource) Io {
    return res.ping_timer.io; // TODO: move to the root of resources.
}

// Describes the dependency on an allocator.
pub fn Allocator(comptime kind: AllocatorKind) type {
    return struct {
        pub const allocator_kind = kind;

        interface: mem.Allocator,
    };
}
