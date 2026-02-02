const std = @import("std");
const proto = @import("proto");
const logic = @import("../logic.zig");
const network = @import("../network.zig");
const Session = @import("../Session.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.messaging);
const meta = std.meta;

const namespaces = &.{
    @import("messaging/player.zig"),
    @import("messaging/scene.zig"),
    @import("messaging/char_bag.zig"),
    @import("messaging/friend_chat.zig"),
};

pub fn Request(comptime CSType: type) type {
    return struct {
        pub const CSMessage = CSType;

        message: *const CSMessage,
        session: *Session,
    };
}

const MsgID = blk: {
    var msg_types: []const type = &.{};

    for (namespaces) |namespace| {
        for (@typeInfo(namespace).@"struct".decls) |decl_info| {
            const decl = @field(namespace, decl_info.name);
            const fn_info = switch (@typeInfo(@TypeOf(decl))) {
                .@"fn" => |info| info,
                else => continue,
            };

            if (fn_info.params.len == 0) continue;
            const Param = fn_info.params[0].type.?;
            if (!@hasDecl(Param, "CSMessage")) continue;

            msg_types = msg_types ++ .{Param.CSMessage};
        }
    }

    var msg_names: [msg_types.len][]const u8 = @splat("");
    var msg_ids: [msg_types.len]i32 = @splat(0);

    for (msg_types, 0..) |CSMsg, i| {
        // Proven to exist by the code above.
        msg_names[i] = CSMsg.message_name;
        msg_ids[i] = @intFromEnum(proto.messageId(CSMsg));
    }

    break :blk @Enum(i32, .exhaustive, &msg_names, &msg_ids);
};

pub fn process(
    gpa: Allocator,
    world: *logic.World,
    request: *const network.Request,
) !void {
    const recv_msg_id = std.enums.fromInt(MsgID, request.head.msgid) orelse {
        return error.MissingHandler;
    };

    switch (recv_msg_id) {
        inline else => |msg_id| {
            handler_lookup: inline for (namespaces) |namespace| {
                inline for (@typeInfo(namespace).@"struct".decls) |decl_info| {
                    const decl = @field(namespace, decl_info.name);
                    const fn_info = switch (@typeInfo(@TypeOf(decl))) {
                        .@"fn" => |info| info,
                        else => continue,
                    };

                    if (fn_info.params.len == 0) continue;
                    const Param = fn_info.params[0].type.?;
                    if (!@hasDecl(Param, "CSMessage")) continue;

                    if (comptime !std.mem.eql(u8, @tagName(msg_id), Param.CSMessage.message_name))
                        continue;

                    var arena: std.heap.ArenaAllocator = .init(gpa);
                    defer arena.deinit();

                    var queue: logic.event.Queue = .init(arena.allocator());

                    var reader: Io.Reader = .fixed(request.body);
                    var message = proto.decodeMessage(&reader, arena.allocator(), Param.CSMessage) catch
                        return error.DecodeFailed;

                    var handler_args: meta.ArgsTuple(@TypeOf(decl)) = undefined;
                    handler_args[0] = .{
                        .message = &message,
                        .session = world.session,
                    };

                    inline for (fn_info.params[1..], 1..) |param, i| {
                        handler_args[i] = logic.queries.resolve(param.type.?, world, &queue, gpa, arena.allocator()) catch {
                            log.err("message handler for '{s}' requires an optional component", .{@typeName(Param.CSMessage)});
                            return;
                        };
                    }

                    try @call(.auto, decl, handler_args);
                    try logic.systems.run(world, &queue, gpa, arena.allocator());

                    break :handler_lookup;
                }
            } else comptime unreachable;
        },
    }
}
