const ItemBag = @This();
const std = @import("std");
const common = @import("common");

const Allocator = std.mem.Allocator;

weapon_depot: std.MultiArrayList(Weapon),

pub fn deinit(bag: *ItemBag, gpa: Allocator) void {
    bag.weapon_depot.deinit(gpa);
}

pub const WeaponIndex = enum(u64) {
    _,

    pub fn instId(i: WeaponIndex) u64 {
        return @intFromEnum(i) + 1;
    }
};

pub const Weapon = struct {
    template_id: i32,
    exp: u32,
    weapon_lv: u32,
    refine_lv: u32,
    breakthrough_lv: u32,
    attach_gem_id: u64,
};
