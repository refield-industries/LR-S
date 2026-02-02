const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const Session = @import("../../Session.zig");

pub fn syncDomainDevSystem(
    rx: logic.event.Receiver(.login),
    session: *Session,
    assets: *const Assets,
    arena: logic.Resource.Allocator(.arena),
) !void {
    _ = rx;

    var domain_dev_sync: pb.SC_DOMAIN_DEVELOPMENT_SYSTEM_SYNC = .init;
    for (assets.table(.domain_data).keys()) |chapter_id| {
        try domain_dev_sync.domains.append(arena.interface, .{
            .chapter_id = chapter_id,
            .dev_degree = .{ .level = 1 },
        });
    }

    try session.send(domain_dev_sync);
}
