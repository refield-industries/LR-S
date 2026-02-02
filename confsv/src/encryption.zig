const std = @import("std");
const aes = std.crypto.core.aes;

const Random = std.Random;
const Allocator = std.mem.Allocator;

pub fn CBC(comptime BlockCipher: anytype) type {
    const EncryptCtx = aes.AesEncryptCtx(BlockCipher);

    return struct {
        const Self = @This();
        const block_length = EncryptCtx.block_length;

        ctx: EncryptCtx,

        pub fn init(key: [BlockCipher.key_bits / 8]u8) Self {
            return .{ .ctx = BlockCipher.initEnc(key) };
        }

        pub fn paddedLength(length: usize) usize {
            return (std.math.divCeil(usize, length + 1, block_length) catch unreachable) * EncryptCtx.block_length;
        }

        pub fn encrypt(self: Self, dst: []u8, src: []const u8, iv: *const [block_length]u8) void {
            const padded_length = paddedLength(src.len);
            std.debug.assert(dst.len == padded_length); // destination buffer must hold the padded plaintext
            var cv = iv.*;
            var i: usize = 0;
            while (i + block_length <= src.len) : (i += block_length) {
                const in = src[i..][0..block_length];
                for (cv[0..], in) |*x, y| x.* ^= y;
                self.ctx.encrypt(&cv, &cv);
                @memcpy(dst[i..][0..block_length], &cv);
            }

            // Last block
            var in: [block_length]u8 = @splat(0);
            const padding_length: u8 = @intCast(padded_length - src.len);
            @memset(&in, padding_length);
            @memcpy(in[0 .. src.len - i], src[i..]);
            for (cv[0..], in) |*x, y| x.* ^= y;
            self.ctx.encrypt(&cv, &cv);
            @memcpy(dst[i..], cv[0 .. dst.len - i]);
        }
    };
}

// Caller owns the returned buffer.
pub fn encryptAlloc(gpa: Allocator, random: Random, key: [16]u8, data: []const u8) Allocator.Error![]u8 {
    const Cipher = CBC(aes.Aes128);
    const result = try gpa.alloc(u8, Cipher.block_length + Cipher.paddedLength(data.len));

    random.bytes(result[0..Cipher.block_length]); // IV

    const cipher: Cipher = .init(key);
    cipher.encrypt(result[Cipher.block_length..], data, result[0..Cipher.block_length]);

    return result;
}
