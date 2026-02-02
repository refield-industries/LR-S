const std = @import("std");
const logic = @import("../logic.zig");

const meta = std.meta;

const Allocator = std.mem.Allocator;

pub fn resolve(
    comptime Query: type,
    world: *logic.World,
    event_queue: *logic.event.Queue,
    gpa: Allocator,
    arena: Allocator,
) !Query {
    if (comptime meta.activeTag(@typeInfo(Query)) == .@"struct") {
        if (@hasDecl(Query, "allocator_kind")) {
            switch (Query.allocator_kind) {
                .gpa => return .{ .interface = gpa },
                .arena => return .{ .interface = arena },
            }
        } else if (@hasDecl(Query, "tx_event_kind")) {
            return .{ .event_queue = event_queue };
        }
    }

    return world.getComponentByType(Query);
}
