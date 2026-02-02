const std = @import("std");
const meta = std.meta;
const enums = std.enums;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub fn Parsed(comptime Args: type) type {
    return struct {
        const P = @This();

        arena: ArenaAllocator,
        options: Args,

        pub fn deinit(p: P) void {
            p.arena.deinit();
        }
    };
}

pub fn parseOrPrintUsageAlloc(comptime Args: type, gpa: std.mem.Allocator, args: std.process.Args) ?Parsed(Args) {
    var arena: ArenaAllocator = .init(gpa);
    const args_slice = args.toSlice(arena.allocator()) catch return null;

    const parsed_args = parse(Args, args_slice[1..]) orelse {
        printUsage(Args, args_slice[0]);
        arena.deinit();
        return null;
    };

    return .{
        .arena = arena,
        .options = parsed_args,
    };
}

pub fn parse(comptime Args: type, args: []const [:0]const u8) ?Args {
    const fields = @typeInfo(Args).@"struct".fields;
    const ArgField = comptime meta.FieldEnum(Args);
    const Flag = comptime blk: {
        const field_names = meta.fieldNames(ArgField);
        var flags: [field_names.len]u8 = undefined;

        for (field_names, 0..) |name, i| {
            flags[i] = name[0];
        }

        break :blk @Enum(u8, .exhaustive, field_names, &flags);
    };

    var result: Args = .{};

    var arg_stack_buffer: [fields.len]Flag = undefined;
    var arg_stack = std.ArrayList(Flag).initBuffer(arg_stack_buffer[0..]);

    for (args) |arg| {
        if (arg[0] == '-') {
            for (arg[1..]) |flag| {
                if (arg_stack.items.len == fields.len) return null;
                arg_stack.appendAssumeCapacity(std.enums.fromInt(Flag, flag) orelse return null);
            }
        } else {
            if (arg_stack.items.len == 0) return null;
            switch (arg_stack.swapRemove(0)) {
                inline else => |flag| @field(result, @tagName(flag)) = arg,
            }
        }
    }

    return if (arg_stack.items.len == 0) result else null;
}

pub fn printUsage(comptime Args: type, program_name: []const u8) void {
    const usage_string = comptime blk: {
        var fmt: []const u8 = "Usage: {s} [-";
        for (@typeInfo(Args).@"struct".fields) |field| {
            fmt = fmt ++ .{field.name[0]};
        }

        fmt = fmt ++ "] ";

        for (@typeInfo(Args).@"struct".fields) |field| {
            fmt = fmt ++ "[" ++ field.name ++ "] ";
        }

        break :blk fmt ++ "\n";
    };

    std.debug.print(usage_string, .{program_name});
}
