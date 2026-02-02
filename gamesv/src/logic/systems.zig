const std = @import("std");
const logic = @import("../logic.zig");
const Session = @import("../Session.zig");

const meta = std.meta;
const event = logic.event;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const namespaces = &.{
    @import("systems/base.zig"),
    @import("systems/game_vars.zig"),
    @import("systems/unlock.zig"),
    @import("systems/item_bag.zig"),
    @import("systems/char_bag.zig"),
    @import("systems/bitset.zig"),
    @import("systems/dungeon.zig"),
    @import("systems/domain_dev.zig"),
    @import("systems/factory.zig"),
    @import("systems/stubs.zig"),
    @import("systems/friend.zig"),
    @import("systems/scene.zig"),
    @import("systems/player_saves.zig"),
};

pub const RunSystemsError = Io.Cancelable || Session.SendError || Allocator.Error;

// Initiate an event frame by triggering one.
pub fn triggerEvent(kind: event.Kind, world: *logic.World, gpa: Allocator) RunSystemsError!void {
    var arena: std.heap.ArenaAllocator = .init(gpa); // Arena for the event frame.
    defer arena.deinit();

    var queue: event.Queue = .init(arena.allocator());
    try queue.push(kind);

    try run(world, &queue, gpa, arena.allocator());
}

// Execute the event frame.
pub fn run(world: *logic.World, queue: *event.Queue, gpa: Allocator, arena: Allocator) RunSystemsError!void {
    while (queue.deque.popFront()) |event_kind| {
        try dispatchEvent(event_kind, world, queue, gpa, arena);
    }
}

// Process single event of the frame.
fn dispatchEvent(
    kind: event.Kind,
    world: *logic.World,
    queue: *event.Queue,
    gpa: Allocator,
    arena: Allocator,
) RunSystemsError!void {
    switch (kind) {
        inline else => |payload, tag| inline for (namespaces) |namespace| {
            inline for (@typeInfo(namespace).@"struct".decls) |decl_info| {
                const decl = @field(namespace, decl_info.name);
                const fn_info = switch (@typeInfo(@TypeOf(decl))) {
                    .@"fn" => |info| info,
                    else => continue,
                };

                if (fn_info.params.len == 0) continue;

                const Param = fn_info.params[0].type.?;
                if (!@hasDecl(Param, "rx_event_kind")) continue;
                if (Param.rx_event_kind != tag) continue;

                try invoke(payload, decl, world, queue, gpa, arena);
            }
        },
    }
}

fn invoke(
    payload: anytype,
    decl: anytype,
    world: *logic.World,
    queue: *event.Queue,
    gpa: Allocator,
    arena: Allocator,
) !void {
    var handler_args: meta.ArgsTuple(@TypeOf(decl)) = undefined;
    handler_args[0] = .{ .payload = payload };

    inline for (@typeInfo(@TypeOf(decl)).@"fn".params[1..], 1..) |param, i| {
        handler_args[i] = logic.queries.resolve(param.type.?, world, queue, gpa, arena) catch {
            return;
        };
    }

    try @call(.auto, decl, handler_args);
}
