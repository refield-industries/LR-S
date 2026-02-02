const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const messaging = logic.messaging;

pub fn onCsFriendChatListSimpleSync(
    request: messaging.Request(pb.CS_FRIEND_CHAT_LIST_SIMPLE_SYNC),
) !void {
    try request.session.send(pb.SC_FRIEND_CHAT_LIST_SIMPLE_SYNC{});
}
