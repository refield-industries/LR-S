const std = @import("std");

pub fn LimitedString(comptime limit: usize) type {
    return struct {
        const String = @This();

        pub const max_length = limit;
        pub const empty: String = .{};

        bytes: [max_length + 1]u8 = @splat(0),

        pub fn init(value: []const u8) error{TooLongString}!String {
            var string: String = .{};
            try string.set(value);

            return string;
        }

        pub fn constant(comptime value: []const u8) String {
            errdefer comptime unreachable; // Constant string literal is too long.
            return try comptime String.init(value);
        }

        pub fn view(string: *const String) [:0]const u8 {
            std.debug.assert(string.bytes[max_length] == 0);
            return std.mem.span(@as([*:0]const u8, @ptrCast(&string.bytes)));
        }

        pub fn set(string: *String, value: []const u8) error{TooLongString}!void {
            if (value.len > max_length) return error.TooLongString;

            @memcpy(string.bytes[0..value.len], value);
            string.bytes[value.len] = 0;
        }

        pub fn jsonStringify(string: *const String, jws: anytype) !void {
            try jws.write(string.view());
        }

        pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !String {
            return switch (try source.nextAlloc(a, options.allocate.?)) {
                inline .string, .allocated_string => |string| String.init(string) catch error.LengthMismatch,
                else => return error.UnexpectedToken,
            };
        }
    };
}
