const Level = @This();
const std = @import("std");
pub const Object = @import("Level/Object.zig");
const logic = @import("../logic.zig");

const max_team_size = logic.Player.CharBag.Team.slots_count;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const MultiArrayList = std.MultiArrayList;
const HashMap = std.AutoArrayHashMapUnmanaged;

pub const init: Level = .{
    .object_id_map = .empty,
    .objects = .empty,
    .team_characters = @splat(.none),
};

object_id_map: HashMap(u64, u32),
objects: MultiArrayList(Object),
team_characters: [max_team_size]Object.NetID,

pub const TeamIterator = struct {
    ids: []const Object.NetID,

    pub fn next(iterator: *TeamIterator) Object.NetID {
        while (iterator.ids.len != 0) {
            defer iterator.ids = iterator.ids[1..];
            if (iterator.ids[0] != .none) return iterator.ids[0];
        } else return .none;
    }
};

pub fn deinit(level: *Level, gpa: Allocator) void {
    level.object_id_map.deinit(gpa);
    level.objects.deinit(gpa);
}

pub fn team(level: *Level) TeamIterator {
    return .{ .ids = &level.team_characters };
}

pub fn countTeamMembers(level: *Level) usize {
    var count: usize = 0;
    for (level.team_characters) |id| {
        if (id != .none) count += 1;
    }

    return count;
}

pub const SpawnParams = struct {
    template_id: i32,
    position: Object.Vector,
    rotation: Object.Vector,
    hp: f64,
};

pub const ExtraSpawnParams = union(enum) {
    character: struct {
        level: i32,
        char_index: logic.Player.CharBag.CharIndex,
    },
};

pub const SpawnError = Allocator.Error;

pub fn spawn(
    level: *Level,
    gpa: Allocator,
    common_params: SpawnParams,
    extra_params: ExtraSpawnParams,
) SpawnError!Object.Handle {
    const index = try level.objects.addOne(gpa);
    errdefer level.objects.swapRemove(index);

    const net_id = switch (extra_params) {
        .character => |params| blk: {
            const object_id = params.char_index.objectId();

            const team_slot_index = level.countTeamMembers();
            std.debug.assert(team_slot_index < max_team_size); // Forgot to remove previous characters?
            level.team_characters[team_slot_index] = @enumFromInt(object_id);

            break :blk object_id;
        },
    };

    try level.object_id_map.put(gpa, net_id, @intCast(index));

    errdefer comptime unreachable;

    level.objects.set(index, .{
        .net_id = @enumFromInt(net_id),
        .template_id = common_params.template_id,
        .position = common_params.position,
        .rotation = common_params.rotation,
        .hp = common_params.hp,
        .extra = switch (extra_params) {
            .character => |extra| .{ .character = .{
                .level = extra.level,
                .char_index = extra.char_index,
            } },
        },
    });

    return @enumFromInt(index);
}

pub fn despawn(level: *Level, handle: Object.Handle) void {
    const index = @intFromEnum(handle);
    const prev_net_id = level.objects.items(.net_id)[index];

    for (level.team_characters, 0..) |id, i| if (prev_net_id == id) {
        level.team_characters[i] = .none;
    };

    _ = level.object_id_map.swapRemove(@intFromEnum(prev_net_id));
    level.objects.swapRemove(index);

    if (index < level.objects.len) {
        const net_id = level.objects.items(.net_id)[index];
        level.object_id_map.getPtr(@intFromEnum(net_id)).?.* = index;
    }
}

pub fn reset(level: *Level) void {
    level.team_characters = @splat(.none);
    level.object_id_map.clearRetainingCapacity();
    level.objects.clearRetainingCapacity();
}

pub fn getObjectByNetId(level: *Level, net_id: Object.NetID) ?Object.Handle {
    const index = level.object_id_map.get(@intFromEnum(net_id)) orelse return null;
    return @enumFromInt(index);
}

pub fn moveObject(
    level: *Level,
    handle: Object.Handle,
    position: Object.Vector,
    rotation: Object.Vector,
) void {
    const index = @intFromEnum(handle);
    const objects = level.objects.slice();

    objects.items(.position)[index] = position;
    objects.items(.rotation)[index] = rotation;
}
