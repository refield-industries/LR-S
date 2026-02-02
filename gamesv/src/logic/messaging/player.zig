const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const messaging = logic.messaging;

pub fn onCsPing(
    request: messaging.Request(pb.CS_PING),
    timer: *logic.Resource.PingTimer,
) !void {
    timer.last_client_ts = request.message.client_ts;

    try request.session.send(pb.SC_PING{
        .client_ts = request.message.client_ts,
        .server_ts = timer.serverTime(),
    });
}

pub fn onCsFlushSync(
    request: messaging.Request(pb.CS_FLUSH_SYNC),
    timer: *logic.Resource.PingTimer,
) !void {
    timer.last_client_ts = request.message.client_ts;

    try request.session.send(pb.SC_FLUSH_SYNC{
        .client_ts = request.message.client_ts,
        .server_ts = timer.serverTime(),
    });
}
