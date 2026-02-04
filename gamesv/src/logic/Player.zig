const Player = @This();
const std = @import("std");
const meta = std.meta;

const Allocator = std.mem.Allocator;

pub const Base = @import("Player/Base.zig");
pub const GameVars = @import("Player/GameVars.zig");
pub const Unlock = @import("Player/Unlock.zig");
pub const CharBag = @import("Player/CharBag.zig");
pub const ItemBag = @import("Player/ItemBag.zig");
pub const Bitset = @import("Player/Bitset.zig");
pub const Scene = @import("Player/Scene.zig");

base: Base,
game_vars: GameVars,
unlock: Unlock,
char_bag: CharBag,
item_bag: ItemBag,
bitset: Bitset,
scene: Scene,

pub fn deinit(player: *Player, gpa: Allocator) void {
    player.game_vars.deinit(gpa);
    player.unlock.deinit(gpa);
    player.char_bag.deinit(gpa);
    player.item_bag.deinit(gpa);
}

// Describes the dependency on an individual player component.
pub fn Component(comptime tag: meta.FieldEnum(Player)) type {
    return struct {
        pub const player_component_tag = tag;

        data: *@FieldType(Player, @tagName(tag)),
    };
}

pub fn isComponent(comptime T: type) bool {
    if (!@hasDecl(T, "player_component_tag")) return false;

    return T == Component(T.player_component_tag);
}

pub fn getComponentByType(player: *Player, comptime T: type) T {
    return .{ .data = &@field(player, @tagName(T.player_component_tag)) };
}
