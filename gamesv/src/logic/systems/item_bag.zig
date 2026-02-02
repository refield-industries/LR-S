const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Session = @import("../../Session.zig");

const Player = logic.Player;

pub fn syncItemBagScopes(
    rx: logic.event.Receiver(.login),
    session: *Session,
    item_bag: Player.Component(.item_bag),
    char_bag: Player.Component(.char_bag),
    arena: logic.Resource.Allocator(.arena),
) !void {
    _ = rx;

    var item_bag_scope_sync: pb.SC_ITEM_BAG_SCOPE_SYNC = .{
        .bag = .init,
        .quick_bar = .init,
        .assistant = .init,
        .scope_name = 1,
    };

    var weapon_depot: pb.SCD_ITEM_DEPOT = .init;
    try weapon_depot.inst_list.ensureTotalCapacity(arena.interface, item_bag.data.weapon_depot.len);

    const weapon_slice = item_bag.data.weapon_depot.slice();

    for (0..weapon_slice.len) |i| {
        const weapon_index: Player.ItemBag.WeaponIndex = @enumFromInt(i);
        const weapon = weapon_slice.get(i);

        weapon_depot.inst_list.appendAssumeCapacity(.{
            .count = 1,
            .inst = .{
                .inst_id = weapon_index.instId(),
                .inst_impl = .{ .weapon = .{
                    .inst_id = weapon_index.instId(),
                    .template_id = weapon.template_id,
                    .exp = weapon.exp,
                    .weapon_lv = weapon.weapon_lv,
                    .refine_lv = weapon.refine_lv,
                    .breakthrough_lv = weapon.breakthrough_lv,
                    .attach_gem_id = weapon.attach_gem_id,
                    .equip_char_id = if (char_bag.data.charIndexWithWeapon(weapon_index)) |char_index|
                        char_index.objectId()
                    else
                        0,
                } },
            },
        });
    }

    try item_bag_scope_sync.depot.append(arena.interface, .{ .key = 1, .value = weapon_depot });
    try session.send(item_bag_scope_sync);
}
