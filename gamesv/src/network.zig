const std = @import("std");
const proto = @import("proto");
const pb = proto.pb;

const Io = std.Io;
const Crc32 = std.hash.Crc32;

pub const Request = struct {
    head: pb.CSHead,
    body: []u8,

    pub const ReadError = error{
        HeadDecodeError,
        ChecksumMismatch,
        InvalidMessageId,
    } || Io.Reader.Error;

    pub fn read(reader: *Io.Reader) ReadError!Request {
        const header_length = try reader.takeInt(u8, .little);
        const body_length = try reader.takeInt(u16, .little);
        const payload = try reader.take(header_length + body_length);

        var head_reader: Io.Reader = .fixed(payload[0..header_length]);
        const head = proto.decodeMessage(
            &head_reader,
            .failing, // CSHead contains only scalar fields. No allocation needed.
            pb.CSHead,
        ) catch return error.HeadDecodeError;

        if (std.enums.fromInt(pb.CSMessageID, head.msgid) == null)
            return error.InvalidMessageId;

        const body = payload[header_length..];
        const checksum = Crc32.hash(body);

        if (checksum != head.checksum)
            return error.ChecksumMismatch;

        return .{ .head = head, .body = body };
    }

    pub fn msgId(request: *const Request) pb.CSMessageID {
        return @enumFromInt(request.head.msgid);
    }
};
