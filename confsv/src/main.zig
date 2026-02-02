const std = @import("std");
const common = @import("common");
const http = @import("http.zig");

const Io = std.Io;
const Init = std.process.Init;
const Allocator = std.mem.Allocator;
const ConcurrencyAvailability = http.ConcurrencyAvailability;

const net = Io.net;
const assert = std.debug.assert;

const log = std.log.scoped(.confsv);

const Options = struct {
    listen_address: []const u8 = "127.0.0.1:10001",
};

fn start(init: Init.Minimal, io: Io, gpa: Allocator) u8 {
    const args = common.args.parseOrPrintUsageAlloc(Options, gpa, init.args) orelse return 1;
    defer args.deinit();

    std.debug.print(
        \\    __    ____       _____
        \\   / /   / __ \     / ___/
        \\  / /   / /_/ /_____\__ \ 
        \\ / /___/ _, _/_____/__/ / 
        \\/_____/_/ |_|     /____/  
        \\
    , .{});

    const listen_address = net.IpAddress.parseLiteral(args.options.listen_address) catch {
        log.err("Invalid listen address specified.", .{});
        return 1;
    };

    var server = listen_address.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
        error.AddressInUse => {
            log.err(
                "Address '{f}' is in use. Another instance of this server might be already running.",
                .{listen_address},
            );
            return 1;
        },
        else => |e| {
            log.err("Failed to listen at '{f}': {t}", .{ listen_address, e });
            return 1;
        },
    };

    defer server.deinit(io);

    var http_processors: Io.Group = .init;
    defer http_processors.cancel(io);

    var preferred_clock: Io.Clock = .awake; // Prefer monotonic clock by default. Fallback to realtime.
    var concurrency_availability: ConcurrencyAvailability = .undetermined;

    log.info("listening at {f}", .{listen_address});
    defer log.info("shutting down...", .{});

    accept_loop: while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => break, // Shutdown requested
            error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => {
                // System is overloaded. Stop accepting new connections for now.
                while (true) {
                    if (io.sleep(.fromSeconds(1), preferred_clock)) break else |sleep_err| switch (sleep_err) {
                        error.Canceled => break :accept_loop, // Shutdown requested
                        error.UnsupportedClock => preferred_clock = if (preferred_clock == .awake)
                            .real
                        else
                            continue :accept_loop, // No clock available.
                        error.Unexpected => continue :accept_loop, // Sleep is unimportant then.
                    }
                }

                continue;
            },
            else => |e| { // Something else happened. We probably want to report this and continue.
                log.err("TCP accept failed: {t}", .{e});
                continue;
            },
        };

        var io_options: http.IoOptions = .{
            .preferred_clock = preferred_clock,
            .concurrency = .available,
        };

        if (http_processors.concurrent(io, http.processClient, .{ io, stream, gpa, io_options })) {
            concurrency_availability = .available;
        } else |err| switch (err) {
            error.ConcurrencyUnavailable => switch (concurrency_availability) {
                .available => stream.close(io), // Can't process more connections atm.
                .unavailable, .undetermined => {
                    // The environment doesn't support concurrency.
                    if (concurrency_availability != .unavailable)
                        log.warn("Environment doesn't support concurrency. One request at a time will be processed.", .{});

                    concurrency_availability = .unavailable;
                    io_options.concurrency = .unavailable;
                    http_processors.async(io, http.processClient, .{ io, stream, gpa, io_options });
                },
            },
        }
    }

    return 0;
}

pub fn main(init: Init.Minimal) u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer assert(.ok == debug_allocator.deinit());
    const gpa = debug_allocator.allocator();

    var poll: common.io.Poll(.{}) = .init(gpa);
    defer poll.deinit();
    const io = poll.io();

    return start(init, io, gpa);
}
