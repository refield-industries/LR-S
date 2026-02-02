const Session = @This();
const std = @import("std");
const proto = @import("proto");
const logic = @import("logic.zig");
const network = @import("network.zig");
const auth = @import("Session/auth.zig");
const fs = @import("fs.zig");
const Assets = @import("Assets.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.Crc32;

const pb = proto.pb;
const net = Io.net;

const first_request_timeout: Io.Duration = .fromSeconds(5);
const subsequent_request_timeout: Io.Duration = .fromSeconds(30);

pub const ConcurrencyAvailability = enum {
    undetermined,
    unavailable,
    available,
};

pub const IoOptions = struct {
    // Indicates whether Io.concurrent() should be considered.
    concurrency: ConcurrencyAvailability,
    // Specifies the preferred system clock.
    preferred_clock: Io.Clock,
};

writer: *Io.Writer,
client_seq_id: u64 = 0,
server_seq_id: u64 = 0,

pub fn process(
    io: Io,
    gpa: Allocator,
    assets: *const Assets,
    stream: net.Stream,
    options: IoOptions,
) Io.Cancelable!void {
    const log = std.log.scoped(.net);
    defer stream.close(io);

    log.debug("new connection from '{f}'", .{stream.socket.address});
    defer log.debug("client from '{f}' disconnected", .{stream.socket.address});

    var recv_buffer: [64 * 1024]u8 = undefined;
    var send_buffer: [4 * 1024]u8 = undefined;

    var reader = stream.reader(io, &recv_buffer);
    var writer = stream.writer(io, &send_buffer);

    var session: Session = .{
        .writer = &writer.interface,
    };

    var world: ?logic.World = null;
    defer if (world) |*w| w.deinit(gpa);

    var receive_timeout = first_request_timeout;

    while (receiveNetRequest(io, &reader.interface, receive_timeout, options)) |request| {
        session.client_seq_id = request.head.up_seqid;
        log.debug("received header: {any}", .{request.head});
        log.debug("received body: {X}", .{request.body});

        if (world) |*w| {
            logic.messaging.process(gpa, w, &request) catch |err| switch (err) {
                error.MissingHandler => log.warn("no handler for {t}", .{request.msgId()}),
                error.DecodeFailed => {
                    log.err(
                        "received malformed message of type '{t}' from '{f}', disconnecting",
                        .{ request.msgId(), stream.socket.address },
                    );
                    return;
                },
                error.Canceled, error.WriteFailed, error.OutOfMemory => return,
            };
        } else {
            const result = processFirstRequest(io, gpa, &session, &request) catch |err| switch (err) {
                error.UnexpectedMessage => {
                    log.err(
                        "received unexpected first message '{t}' from '{f}', disconnecting",
                        .{ request.msgId(), stream.socket.address },
                    );
                    return;
                },
                error.DecodeFailed => {
                    log.err(
                        "received malformed login request from '{t}', disconnecting",
                        .{stream.socket.address},
                    );
                    return;
                },
                error.LoginFailed => {
                    log.err(
                        "session from '{f}' has failed to login, disconnecting",
                        .{stream.socket.address},
                    );
                    return;
                },
                // Regardless which one, the session is invalidated by now.
                error.WriteFailed, error.OutOfMemory => return,
                error.Canceled => |e| return e,
            };

            const player = fs.persistence.loadPlayer(io, gpa, assets, result.uid) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| {
                    log.err("failed to load data for player with uid {d}: {t}, disconnecting", .{ result.uid, e });
                    return;
                },
            };

            log.info(
                "client from '{f}' has successfully logged into account with uid: {d}",
                .{ stream.socket.address, result.uid },
            );

            world = logic.World.init(&session, assets, result.uid, player, gpa, io);
            receive_timeout = subsequent_request_timeout;

            logic.systems.triggerEvent(.{ .login = .{} }, &world.?, gpa) catch |err| switch (err) {
                error.Canceled, error.OutOfMemory, error.WriteFailed => return,
            };
        }
    } else |err| switch (err) {
        error.Canceled,
        error.ConcurrencyUnavailable,
        error.ReadFailed,
        error.EndOfStream,
        => {},
        error.HeadDecodeError,
        error.ChecksumMismatch,
        error.InvalidMessageId,
        => |e| log.err(
            "failed to receive request from '{f}': {t}",
            .{ stream.socket.address, e },
        ),
    }
}

pub const SendError = Io.Writer.Error;

pub fn send(session: *Session, message: anytype) SendError!void {
    var buffer: [128]u8 = undefined;

    var discarding: Io.Writer.Discarding = .init("");
    var hashed: Io.Writer.Hashed(Crc32) = .initHasher(&discarding.writer, .init(), &buffer);
    proto.encodeMessage(&hashed.writer, message) catch unreachable; // Discarding + Hashed can't fail.
    hashed.writer.flush() catch unreachable;

    const head: pb.CSHead = .{
        .msgid = @intFromEnum(proto.messageId(@TypeOf(message))),
        .up_seqid = session.client_seq_id, // Why? No idea. But FlushSync kills itself if it's not like that
        .down_seqid = 0,
        .total_pack_count = 0,
        .checksum = hashed.hasher.final(),
    };

    const head_size = proto.encodingLength(head);
    const body_size = discarding.fullCount();

    try session.writer.writeInt(u8, @intCast(head_size), .little);
    try session.writer.writeInt(u16, @intCast(body_size), .little);
    try proto.encodeMessage(session.writer, head);
    try proto.encodeMessage(session.writer, message);
    try session.writer.flush();

    session.server_seq_id += 1;
}

fn processFirstRequest(io: Io, gpa: Allocator, session: *Session, request: *const network.Request) !auth.Result {
    if (request.msgId() != .cs_login)
        return error.UnexpectedMessage;

    var reader: Io.Reader = .fixed(request.body);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const cs_login = proto.decodeMessage(&reader, arena.allocator(), pb.CS_LOGIN) catch
        return error.DecodeFailed;

    return try auth.processLoginRequest(io, session, &cs_login);
}

const ReceiveError = Io.Cancelable || Io.ConcurrentError || network.Request.ReadError;

fn receiveNetRequest(
    io: Io,
    reader: *Io.Reader,
    timeout: Io.Duration,
    options: IoOptions,
) ReceiveError!network.Request {
    return switch (options.concurrency) {
        .undetermined => unreachable,
        .unavailable => try network.Request.read(reader),
        .available => {
            var receive = try io.concurrent(network.Request.read, .{reader});
            errdefer _ = receive.cancel(io) catch {};

            var sleep = try io.concurrent(Io.sleep, .{ io, timeout, options.preferred_clock });
            defer sleep.cancel(io) catch {};

            return switch (try io.select(.{
                .receive = &receive,
                .sleep = &sleep,
            })) {
                .sleep => try receive.cancel(io),
                .receive => |request| request,
            };
        },
    };
}
