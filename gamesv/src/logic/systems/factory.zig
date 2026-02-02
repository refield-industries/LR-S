const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const Session = @import("../../Session.zig");

const default_chapter = "domain_2";

pub fn syncFactoryData(
    rx: logic.event.Receiver(.login),
    session: *Session,
    assets: *const Assets,
    arena: logic.Resource.Allocator(.arena),
) !void {
    _ = rx;

    try session.send(pb.SC_FACTORY_SYNC{
        .stt = .init,
        .formula_man = .init,
        .progress_status = .init,
    });

    var factory_sync_scope: pb.SC_FACTORY_SYNC_SCOPE = .{
        .scope_name = 1,
        .current_chapter_id = default_chapter,
        .transport_route = .init,
        .book_mark = .init,
        .sign_mgr = .init,
        .shared_mgr = .init,
    };

    for (assets.table(.domain_data).keys()) |chapter_id| {
        try factory_sync_scope.active_chapter_ids.append(arena.interface, chapter_id);
    }

    try session.send(factory_sync_scope);

    for (assets.table(.domain_data).keys()) |chapter_id| {
        try session.send(pb.SC_FACTORY_SYNC_CHAPTER{
            .chapter_id = chapter_id,
            .blackboard = .{ .power = .{ .is_stop_by_power = true } },
            .pin_board = .{},
            .statistic = .{},
            .pending_place = .{},
        });

        try session.send(pb.SC_FACTORY_HS{
            .blackboard = .{
                .power = .{ .is_stop_by_power = true },
            },
            .chapter_id = chapter_id,
        });
    }
}
