const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Session = @import("../../Session.zig");

pub fn syncPersonalData(
    rx: logic.event.Receiver(.login),
    session: *Session,
) !void {
    _ = rx;

    // TODO
    try session.send(pb.SC_FRIEND_PERSONAL_DATA_SYNC{
        .data = .{
            .user_avatar_id = 7,
            .User_avatar_frame_id = 3,
            .business_card_topic_id = 11,
        },
    });
}
