const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const linux = std.os.linux;

const windows = std.os.windows;
const ws2_32 = windows.ws2_32;

const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const SinglyLinkedList = std.SinglyLinkedList;
const DoublyLinkedList = std.DoublyLinkedList;

const assert = std.debug.assert;
const native_os = builtin.os.tag;
const native_arch = builtin.cpu.arch;

const iovlen_t = @FieldType(posix.msghdr_const, "iovlen");

pub const IoOptions = struct {
    stack_size: usize = 1024 * 1024, // 1MB
    max_iovecs_len: usize = 8,
    splat_buffer_size: usize = 64,
    interruption_behavior: InterruptionBehavior = .global_cancelation,

    pub const InterruptionBehavior = enum {
        none,
        global_cancelation,
    };
};

pub fn StackPool(comptime stack_size: usize) type {
    return struct {
        const ThisStackPool = @This();
        pub const init: ThisStackPool = .{};

        used_list: SinglyLinkedList = .{},
        free_list: SinglyLinkedList = .{},

        pub const Item = struct {
            stack: [stack_size]u8 = undefined,
            node: SinglyLinkedList.Node = .{},
        };

        pub fn deinit(sp: *ThisStackPool, gpa: Allocator) void {
            while (sp.used_list.popFirst()) |node| {
                const item: *Item = @fieldParentPtr("node", node);
                gpa.destroy(item);
            }

            while (sp.free_list.popFirst()) |node| {
                const item: *Item = @fieldParentPtr("node", node);
                gpa.destroy(item);
            }
        }

        pub fn allocate(sp: *ThisStackPool, gpa: Allocator) Allocator.Error!*Item {
            if (sp.free_list.popFirst()) |node| {
                const item: *Item = @fieldParentPtr("node", node);
                sp.used_list.prepend(&item.node);
                return item;
            } else {
                const item = try gpa.create(Item);
                item.* = .{};

                sp.used_list.prepend(&item.node);
                return item;
            }
        }

        pub fn recycle(sp: *ThisStackPool, stack: *Item) void {
            sp.used_list.remove(&stack.node);
            sp.free_list.prepend(&stack.node);
        }
    };
}

const Context = switch (native_arch) {
    .x86_64 => extern struct {
        rsp: u64 = 0,
        rbp: u64 = 0,
        rip: u64 = 0,
    },
    else => @compileError("architecture '" ++ @tagName(native_arch) ++ "' is not supported yet"),
};

const ContextPair = extern struct {
    save: *Context, // The instance registers will be saved into.
    restore: *const Context, // The instance registers will be loaded from.
};

pub fn Poll(comptime io_options: IoOptions) type {
    return struct {
        const ThisPoll = @This();
        const Stacks = StackPool(io_options.stack_size);

        const eventLoop = switch (native_os) {
            .linux => eventLoopLinux,
            .windows => eventLoopWindows,
            else => eventLoopPosix,
        };

        const ResumeEvent = switch (native_os) {
            .linux => linux.epoll_event,
            else => void,
        };

        const Subscribers = switch (native_os) {
            // For epoll
            .linux => struct {
                pub const init: @This() = .{
                    .list = .empty,
                };

                pub const Subscriber = struct {
                    fd: i32,
                    on_event: PollSubscriber.Action,
                };

                list: std.MultiArrayList(Subscriber),

                pub fn deinit(s: *@This(), gpa: Allocator) void {
                    s.list.deinit(gpa);
                }
            },
            // For ppoll/WSAPoll
            else => struct {
                pub const init: @This() = .{
                    .list = .empty,
                    .modified = false,
                };

                list: std.MultiArrayList(PollSubscriber),
                modified: bool,

                pub fn deinit(s: *@This(), gpa: Allocator) void {
                    s.list.deinit(gpa);
                }
            },
        };

        gpa: Allocator,
        stack_pool: Stacks = .init,
        wait_scheduler: WaitScheduler = .init,
        restore_points: SinglyLinkedList = .{},
        idle_fiber: ?*Fiber = null, // The fiber the `eventLoop` is running on.
        active_fiber: ?*Fiber = null, // The fiber that is currently running.
        subscribers: Subscribers = .init,
        interrupted: bool = false, // ctrl+c
        waker: Waker,
        epollfd: if (native_os == .linux) i32 else void = undefined,
        canceled_fibers: DoublyLinkedList = .{},

        const Fiber = struct {
            const CancelationStatus = enum {
                none,
                requested,
                acknowledged,
            };

            stack: *Stacks.Item,
            context: Context = undefined, // last yield point of fiber
            cancelation: CancelationStatus = .none,
            cancelation_node: DoublyLinkedList.Node = .{},
            awaiter: ?*RestorePoint = null,

            pub inline fn cancelationRequested(f: *const Fiber) bool {
                return f.cancelation != .none; // TODO: subject to cancelation protection.
            }

            pub fn deinit(f: *Fiber, p: *ThisPoll) void {
                if (f.cancelation == .requested) {
                    f.cancelation = .acknowledged;
                    p.canceled_fibers.remove(&f.cancelation_node);
                }
            }
        };

        const ClosureState = enum {
            scheduled,
            running,
            finished,
        };

        const RestorePoint = struct {
            point: union(enum) {
                fiber: *Fiber,
                raw: Context,
            },
            node: SinglyLinkedList.Node = .{},

            pub fn fiber(rp: *const RestorePoint) ?*Fiber {
                return switch (rp.point) {
                    .fiber => |f| f,
                    .raw => null,
                };
            }

            pub fn context(rp: *RestorePoint) *Context {
                return switch (rp.point) {
                    .fiber => |f| &f.context,
                    .raw => |*raw| raw,
                };
            }

            pub fn contextConst(rp: *const RestorePoint) *const Context {
                return switch (rp.point) {
                    .fiber => |f| &f.context,
                    .raw => |*raw| raw,
                };
            }
        };

        const PollSubscriber = struct {
            pub const dummy_fd = if (native_os == .windows) ws2_32.INVALID_SOCKET else 0;
            pub const Pollfd = if (native_os == .windows) ws2_32.WSAPOLLFD else posix.pollfd;
            pub const Events = if (native_os == .windows) ws2_32.POLL else posix.POLL;

            on_event: Action,
            pollfd: Pollfd,

            pub const Action = union(enum) {
                resume_execution: RestorePoint,
                interrupt: void, // waker socket event
            };

            pub fn ready(action: *const Action, pollfd: *const Pollfd, interrupted: bool) bool {
                if (pollfd.fd == dummy_fd or pollfd.events == 0) return false;
                if (pollfd.revents != 0) return true;

                return switch (action.*) {
                    .interrupt => false,
                    .resume_execution => |point| {
                        if (interrupted) return true;

                        return if (point.fiber()) |fiber|
                            fiber.cancelationRequested()
                        else
                            false;
                    },
                };
            }
        };

        const WaitScheduler = struct {
            pub const init: WaitScheduler = .{};

            const Futex = struct {
                ptr: *const u32,
                expected: u32,
            };

            sleepers: SinglyLinkedList = .{},

            const Sleeper = struct {
                until: ?Io.Clock.Timestamp,
                futex: ?Futex,
                restore: RestorePoint,

                pub fn create(
                    gpa: Allocator,
                    rp: RestorePoint,
                    until: ?Io.Clock.Timestamp,
                    futex: ?Futex,
                ) Allocator.Error!*Sleeper {
                    assert(until != null or futex != null); // no wakeup condition besides cancelation

                    const sleeper = try gpa.create(WaitScheduler.Sleeper);
                    sleeper.* = .{
                        .until = until,
                        .futex = futex,
                        .restore = rp,
                    };

                    return sleeper;
                }

                pub fn ready(sleeper: *const Sleeper) bool {
                    if (sleeper.restore.fiber()) |fiber| {
                        // Wake up immediately
                        if (fiber.cancelationRequested()) return true;
                    }

                    if (sleeper.futex) |futex| {
                        if (futex.expected != futex.ptr.*) return true;
                    }

                    if (sleeper.remainingTimeNanoseconds()) |ns| {
                        return ns <= 0;
                    }

                    return false;
                }

                pub fn remainingTimeNanoseconds(sleeper: *const Sleeper) ?i96 {
                    const until = sleeper.until orelse return null;

                    const ts = currentTime(until.clock) catch unreachable;
                    return until.raw.nanoseconds - ts.nanoseconds;
                }

                pub fn fromNode(node: *SinglyLinkedList.Node) *Sleeper {
                    const rp: *RestorePoint = @alignCast(@fieldParentPtr("node", node));
                    return @alignCast(@fieldParentPtr("restore", rp));
                }
            };

            pub fn nextWakeupTime(s: *WaitScheduler) ?posix.timespec {
                var smallest_period: ?i96 = null;
                var next = s.sleepers.first;

                while (next) |node| {
                    next = node.next;
                    const sleeper = Sleeper.fromNode(node);

                    if (sleeper.ready()) return .{ .sec = 0, .nsec = 0 };

                    const remaining = sleeper.remainingTimeNanoseconds() orelse continue;
                    smallest_period = if (smallest_period) |smallest| @min(remaining, smallest) else remaining;
                }

                return if (smallest_period) |ns| .{
                    .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
                    .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
                } else null;
            }

            pub fn removeNextAwake(s: *WaitScheduler, gpa: Allocator, interrupted: bool) ?RestorePoint {
                var next_node = s.sleepers.first;
                var prev_node: ?*SinglyLinkedList.Node = null;

                while (next_node) |node| {
                    const sleeper = Sleeper.fromNode(node);

                    if (sleeper.ready() or interrupted) {
                        // remove from list
                        if (prev_node) |prev| {
                            _ = prev.removeNext();
                            next_node = prev.next;
                        } else {
                            _ = s.sleepers.popFirst();
                            next_node = s.sleepers.first;
                        }

                        const restore_point = sleeper.restore;
                        gpa.destroy(sleeper);

                        return restore_point;
                    } else {
                        prev_node = node;
                        next_node = node.next;
                    }
                }

                return null;
            }
        };

        const AsyncClosure = struct {
            fiber: Fiber,
            context: []const u8,
            result: []u8,
            state: ClosureState,

            pub fn create(gpa: Allocator, fiber: Fiber, context: []const u8, result_len: usize) Allocator.Error!*AsyncClosure {
                const closure = try gpa.create(AsyncClosure);
                errdefer gpa.destroy(closure);

                // Context should be cloned, because it's on the stack of another coroutine which will get overwritten if it doesn't linearly wait for completion.
                const owned_context = try gpa.dupe(u8, context);
                errdefer gpa.free(owned_context);

                const result_buffer = try gpa.alloc(u8, result_len);
                closure.* = .{
                    .fiber = fiber,
                    .context = owned_context,
                    .result = result_buffer,
                    .state = .scheduled,
                };

                return closure;
            }

            pub fn destroy(ac: *AsyncClosure, gpa: Allocator) void {
                gpa.free(ac.result);
                gpa.destroy(ac);
            }

            pub fn entryPoint(
                ac: *AsyncClosure,
                runtime: *ThisPoll,
                userStart: *const fn (context: *const anyopaque, result: *anyopaque) void,
            ) noreturn {
                assert(ac.state == .scheduled);
                ac.state = .running;

                @call(
                    .auto,
                    userStart,
                    .{ @as(*const anyopaque, @ptrCast(ac.context)), @as(*anyopaque, @ptrCast(ac.result)) },
                );

                ac.state = .finished;
                ac.fiber.deinit(runtime);
                runtime.stack_pool.recycle(ac.fiber.stack);
                runtime.gpa.free(ac.context);

                if (ac.fiber.awaiter) |awaiter| {
                    runtime.active_fiber = awaiter.fiber();

                    switchContext(&.{
                        .save = &ac.fiber.context,
                        .restore = awaiter.context(),
                    });
                } else {
                    runtime.yield(null); // don't save anything, fiber is finished
                }

                unreachable; // switched to a dead fiber
            }
        };

        const GroupClosure = struct {
            fiber: Fiber,
            context: []const u8,
            group: *Io.Group,
            state: ClosureState,
            node: SinglyLinkedList.Node,

            pub fn create(gpa: Allocator, fiber: Fiber, context: []const u8, group: *Io.Group) Allocator.Error!*GroupClosure {
                const closure = try gpa.create(GroupClosure);
                errdefer gpa.destroy(closure);

                // Context should be cloned, because it's on the stack of another coroutine which will get overwritten if it doesn't linearly wait for completion.
                const owned_context = try gpa.dupe(u8, context);
                errdefer gpa.free(owned_context);

                closure.* = .{
                    .fiber = fiber,
                    .context = owned_context,
                    .group = group,
                    .state = .scheduled,
                    .node = .{},
                };

                return closure;
            }

            pub fn destroy(gc: *GroupClosure, gpa: Allocator) void {
                gpa.destroy(gc);
            }

            pub fn reinit(gc: *GroupClosure, gpa: Allocator, fiber: Fiber, context: []const u8) Allocator.Error!void {
                const owned_context = try gpa.dupe(u8, context);
                errdefer gpa.free(owned_context);

                gc.fiber = fiber;
                gc.context = owned_context;
                gc.state = .scheduled;
            }

            pub fn entryPoint(
                gc: *GroupClosure,
                runtime: *ThisPoll,
                userStart: *const fn (context: *const anyopaque) Io.Cancelable!void,
            ) noreturn {
                assert(gc.state == .scheduled);
                gc.state = .running;

                @call(
                    .auto,
                    userStart,
                    .{@as(*const anyopaque, @ptrCast(gc.context))},
                ) catch { // Canceled
                    // Anything to do about it?
                };

                gc.state = .finished;
                gc.fiber.deinit(runtime);
                runtime.stack_pool.recycle(gc.fiber.stack);
                runtime.gpa.free(gc.context);

                if (gc.group.token.raw) |raw_token| {
                    const gt: *GroupToken = @ptrCast(@alignCast(raw_token));
                    gt.recycle(gc);
                }

                if (gc.fiber.awaiter) |awaiter| {
                    runtime.active_fiber = awaiter.fiber();

                    switchContext(&.{
                        .save = &gc.fiber.context,
                        .restore = awaiter.context(),
                    });
                } else {
                    runtime.yield(null); // don't save anything, fiber is finished
                }

                unreachable; // switched to a dead fiber
            }
        };

        const GroupToken = struct {
            running_closures: SinglyLinkedList,
            finished_closures: SinglyLinkedList,

            const WaitMode = enum {
                await,
                cancel,
            };

            pub fn create(gpa: Allocator) Allocator.Error!*GroupToken {
                const token = try gpa.create(GroupToken);
                token.* = .{
                    .running_closures = .{},
                    .finished_closures = .{},
                };

                return token;
            }

            pub fn destroy(token: *GroupToken, gpa: Allocator) void {
                while (token.running_closures.popFirst()) |node| {
                    const closure: *GroupClosure = @fieldParentPtr("node", node);
                    closure.destroy(gpa);
                }

                while (token.finished_closures.popFirst()) |node| {
                    const closure: *GroupClosure = @fieldParentPtr("node", node);
                    closure.destroy(gpa);
                }

                gpa.destroy(token);
            }

            pub fn alloc(
                token: *GroupToken,
                gpa: Allocator,
                type_erased: *Io.Group,
                stack: *Stacks.Item,
                context: []const u8,
            ) Allocator.Error!*GroupClosure {
                if (token.finished_closures.popFirst()) |node| {
                    const closure: *GroupClosure = @alignCast(@fieldParentPtr("node", node));
                    if (closure.reinit(gpa, .{ .stack = stack }, context)) {
                        token.running_closures.prepend(&closure.node);
                        return closure;
                    } else |err| {
                        token.finished_closures.prepend(&closure.node);
                        return err;
                    }
                } else {
                    const closure = try GroupClosure.create(gpa, .{ .stack = stack }, context, type_erased);
                    token.running_closures.prepend(&closure.node);
                    return closure;
                }
            }

            pub fn recycle(token: *GroupToken, closure: *GroupClosure) void {
                token.running_closures.remove(&closure.node);
                token.finished_closures.prepend(&closure.node);
            }

            pub fn waitAll(
                token: *GroupToken,
                runtime: *ThisPoll,
                comptime mode: WaitMode,
            ) switch (mode) {
                .await => Io.Cancelable!void,
                .cancel => void,
            } {
                var next = token.running_closures.first;
                while (next) |node| {
                    next = node.next;

                    if (mode == .await) try checkCancel(runtime);
                    const closure: *GroupClosure = @fieldParentPtr("node", node);

                    if (closure.state != .finished) {
                        var restore_point = runtime.obtainCurrentRestorePoint();
                        closure.fiber.awaiter = &restore_point;

                        if (mode == .cancel and !closure.fiber.cancelationRequested()) {
                            closure.fiber.cancelation = .requested;
                            closure.fiber.cancelation_node = .{};
                            runtime.canceled_fibers.append(&closure.fiber.cancelation_node);
                        }

                        runtime.yield(restore_point.context());
                    }
                }
            }
        };

        pub fn init(gpa: Allocator) ThisPoll {
            if (native_os == .windows) {
                initWSA();
            }

            const waker = if (Waker != void) Waker.init() else {};

            if (io_options.interruption_behavior == .global_cancelation) {
                setInterruptHandler(waker);
            }

            if (native_os == .linux) {
                return .{
                    .gpa = gpa,
                    .waker = waker,
                    .epollfd = @intCast(linux.epoll_create()),
                };
            } else return .{
                .gpa = gpa,
                .waker = waker,
            };
        }

        pub fn deinit(p: *ThisPoll) void {
            assert(p.active_fiber == null); // attempted to deinit inside of fiber

            if (p.idle_fiber) |idle_fiber| {
                p.gpa.destroy(idle_fiber);
            }

            p.stack_pool.deinit(p.gpa);
            p.subscribers.deinit(p.gpa);
        }

        fn obtainCurrentRestorePoint(p: *ThisPoll) RestorePoint {
            return .{
                .node = .{},
                .point = if (p.active_fiber) |active_fiber|
                    // The fiber that invoked the IO operation
                    .{ .fiber = active_fiber }
                else
                    // IO operation was called outside of fiber frame. No additional state should be saved.
                    .{ .raw = undefined },
            };
        }

        fn pushRestorePoint(p: *ThisPoll) Allocator.Error!*RestorePoint {
            const point = try p.gpa.create(RestorePoint);
            point.* = p.obtainCurrentRestorePoint();
            p.restore_points.prepend(&point.node);

            return point;
        }

        // Switches to `idle_fiber`, saving the execution context if destination is provided.
        // `ensureEventLoop` should've been called beforehand.
        fn yield(p: *ThisPoll, saved_context: ?*Context) void {
            var discarded_context: Context = undefined;

            switchContext(&.{
                .save = if (saved_context) |context| context else &discarded_context,
                .restore = &p.idle_fiber.?.context,
            });
        }

        fn resumeAwaiters(p: *ThisPoll, events: []const ResumeEvent) void {
            var polls_resumed = false;

            while (true) {
                var switched_once = false;

                while (p.restore_points.popFirst()) |node| {
                    const point: *RestorePoint = @fieldParentPtr("node", node);
                    p.active_fiber = point.fiber();
                    switched_once = true;

                    switchContext(&.{
                        .save = &p.idle_fiber.?.context,
                        .restore = point.context(),
                    });
                }

                while (p.wait_scheduler.removeNextAwake(p.gpa, p.interrupted)) |point| {
                    p.active_fiber = point.fiber();
                    switched_once = true;

                    switchContext(&.{
                        .save = &p.idle_fiber.?.context,
                        .restore = point.contextConst(),
                    });
                }

                while (p.canceled_fibers.popFirst()) |node| {
                    const fiber: *Fiber = @alignCast(@fieldParentPtr("cancelation_node", node));
                    fiber.cancelation = .acknowledged;

                    p.active_fiber = fiber;
                    switched_once = true;

                    switchContext(&.{
                        .save = &p.idle_fiber.?.context,
                        .restore = &fiber.context,
                    });
                }

                if (!polls_resumed) {
                    polls_resumed = true;
                    switched_once = (switch (native_os) {
                        .linux => p.resumePollsLinux(events),
                        .windows => p.resumePollsWindows(),
                        else => p.resumePollsPosix(),
                    } or switched_once);
                }

                if (!switched_once) break;
            }
        }

        fn resumePollsLinux(p: *ThisPoll, events: []const linux.epoll_event) bool {
            var switched_once = false;

            if (!p.interrupted) {
                for (events) |e| {
                    const fd = p.subscribers.list.items(.fd)[e.data.u64];
                    if (fd == -1) continue;

                    _ = linux.epoll_ctl(p.epollfd, linux.EPOLL.CTL_DEL, fd, null);

                    const action = &p.subscribers.list.items(.on_event)[e.data.u64];
                    p.subscribers.list.items(.fd)[e.data.u64] = -1;

                    switch (action.*) {
                        .interrupt => unreachable, // This implementation doesn't use waker socket.
                        .resume_execution => |*point| {
                            p.active_fiber = point.fiber();

                            switched_once = true;

                            switchContext(&.{
                                .save = &p.idle_fiber.?.context,
                                .restore = point.contextConst(),
                            });
                        },
                    }
                }
            } else {
                // Global cancelation. Wake up everyone.
                for (p.subscribers.list.items(.fd), p.subscribers.list.items(.on_event)) |*fd, *action| {
                    if (fd.* == -1) continue;
                    fd.* = -1;

                    switch (action.*) {
                        .interrupt => unreachable, // This implementation doesn't use waker socket.
                        .resume_execution => |*point| {
                            if (point.fiber()) |f| if (f.cancelation == .acknowledged)
                                continue;

                            p.active_fiber = point.fiber();

                            switched_once = true;
                            switchContext(&.{
                                .save = &p.idle_fiber.?.context,
                                .restore = point.contextConst(),
                            });
                        },
                    }
                }
            }

            return switched_once;
        }

        fn resumePollsPosix(p: *ThisPoll) bool {
            var switched_once = false;
            resumption: while (true) {
                p.subscribers.modified = false;

                for (p.subscribers.list.items(.pollfd), p.subscribers.list.items(.on_event)) |*pollfd, *action| {
                    if (PollSubscriber.ready(action, pollfd, p.interrupted)) switch (action.*) {
                        .interrupt => unreachable, // This implementation doesn't use waker socket.
                        .resume_execution => |*point| {
                            pollfd.revents = 0;
                            pollfd.events = 0; // unsubscribe

                            p.active_fiber = point.fiber();

                            switched_once = true;
                            switchContext(&.{
                                .save = &p.idle_fiber.?.context,
                                .restore = point.contextConst(),
                            });

                            if (p.subscribers.modified) continue :resumption;
                        },
                    };
                }

                if (!p.subscribers.modified) break;
            }

            return switched_once;
        }

        fn resumePollsWindows(p: *ThisPoll) bool {
            var switched_once = false;
            resumption: while (true) {
                p.subscribers.modified = false;

                for (p.subscribers.list.items(.pollfd), p.subscribers.list.items(.on_event)) |*pollfd, *action| {
                    if (PollSubscriber.ready(action, pollfd, p.interrupted)) switch (action.*) {
                        .interrupt => switch (io_options.interruption_behavior) {
                            .none => unreachable, // shouldn't get awakened
                            .global_cancelation => p.interrupted = true,
                        },
                        .resume_execution => |*point| {
                            pollfd.revents = 0;
                            pollfd.events = 0; // unsubscribe

                            p.active_fiber = point.fiber();

                            switched_once = true;
                            switchContext(&.{
                                .save = &p.idle_fiber.?.context,
                                .restore = point.contextConst(),
                            });

                            if (p.subscribers.modified) continue :resumption;
                        },
                    };
                }

                if (!p.subscribers.modified) break;
            }

            return switched_once;
        }

        fn eventLoopLinux(p: *ThisPoll) noreturn {
            const maxevents: u32 = 128;

            var sigint_mask = posix.sigfillset();
            posix.sigdelset(&sigint_mask, .INT);

            const sigmask = if (io_options.interruption_behavior != .none) &sigint_mask else null;

            while (true) {
                switch (io_options.interruption_behavior) {
                    .none => {},
                    .global_cancelation => if (InterruptHandler.sigint_received) {
                        p.interrupted = true;
                    },
                }

                p.resumeAwaiters(&.{});

                var next_wake = p.wait_scheduler.nextWakeupTime();
                const timeout = if (next_wake) |*ts| ts else null;

                var events: [maxevents]linux.epoll_event = undefined;
                const rc = epoll_pwait2(p.epollfd, &events, maxevents, timeout, sigmask);
                switch (posix.errno(rc)) {
                    .SUCCESS => p.resumeAwaiters(events[0..rc]),
                    .NOMEM => continue, // might also wait a bit
                    .INTR => switch (io_options.interruption_behavior) {
                        .none => unreachable, // shouldn't have passed sigmask in the first place
                        .global_cancelation => {
                            p.interrupted = true;
                            p.resumeAwaiters(&.{});
                        },
                    },
                    else => |err| std.debug.panic("epoll_pwait2: unexpected errno: {t}", .{err}),
                }
            }
        }

        fn eventLoopPosix(p: *ThisPoll) noreturn {
            var sigint_mask = posix.sigfillset();
            posix.sigdelset(&sigint_mask, .INT);

            const sigmask = if (io_options.interruption_behavior != .none) &sigint_mask else null;

            while (true) {
                switch (io_options.interruption_behavior) {
                    .none => {},
                    .global_cancelation => if (InterruptHandler.sigint_received) {
                        p.interrupted = true;
                    },
                }

                p.resumeAwaiters(&.{});

                var next_wake = p.wait_scheduler.nextWakeupTime();
                const timeout = if (next_wake) |*ts| ts else null;

                const pollfds = p.subscribers.list.items(.pollfd);

                const rc = posix.system.ppoll(pollfds.ptr, @truncate(pollfds.len), timeout, sigmask);
                switch (posix.errno(rc)) {
                    .SUCCESS => {},
                    .NOMEM => continue, // might also wait a bit
                    .INTR => switch (io_options.interruption_behavior) {
                        .none => unreachable, // shouldn't have passed sigmask in the first place
                        .global_cancelation => {
                            p.interrupted = true;
                            p.resumeAwaiters(&.{});
                        },
                    },
                    else => |err| std.debug.panic("ppoll: unexpected errno: {t}", .{err}),
                }
            }
        }

        fn eventLoopWindows(p: *ThisPoll) noreturn {
            // Workaround the lack of signals on windows.
            p.subscribers.list.append(p.gpa, .{
                .on_event = .interrupt,
                .pollfd = .{
                    .fd = p.waker.socket,
                    .events = ws2_32.POLL.IN,
                    .revents = 0,
                },
            }) catch @panic("Out of Memory");

            while (true) {
                p.resumeAwaiters(&.{});

                const next_wake = p.wait_scheduler.nextWakeupTime();
                const timeout = if (next_wake) |ts| timespecToMs(ts) else -1;

                const pollfds = p.subscribers.list.items(.pollfd);

                const rc = ws2_32.WSAPoll(pollfds.ptr, @intCast(pollfds.len), @intCast(timeout));
                if (rc == ws2_32.SOCKET_ERROR) switch (ws2_32.WSAGetLastError()) {
                    .NOTINITIALISED => unreachable,
                    .ENETDOWN, .ENOBUFS => continue, // retry later?
                    else => |err| {
                        std.debug.print("unexpected wsa error: {t}\n", .{err});
                        @panic("Unexpected WSA error.");
                    },
                };
            }
        }

        fn ensureEventLoop(p: *ThisPoll) Allocator.Error!void {
            if (p.idle_fiber != null) return;

            const stack = try p.stack_pool.allocate(p.gpa);
            errdefer p.stack_pool.recycle(stack);

            const fiber = try p.gpa.create(Fiber);
            fiber.* = .{ .stack = stack };

            FiberBootstrap(eventLoop).initFiber(fiber, .{p});
            p.idle_fiber = fiber;
        }

        fn blocking(p: *ThisPoll, fd: anytype, events: i16) Allocator.Error!void {
            try p.ensureEventLoop();

            const index = switch (native_os) {
                .linux => try p.subscribeEpoll(fd, events),
                else => try p.subscribePoll(fd, events),
            };

            const rp = &p.subscribers.list.items(.on_event)[index].resume_execution;
            p.yield(rp.context());
        }

        fn subscribeEpoll(p: *ThisPoll, fd: i32, events: i16) Allocator.Error!usize {
            const fds = p.subscribers.list.items(.fd);
            const index = blk: {
                if (std.mem.findScalar(i32, fds, -1)) |free_index| {
                    p.subscribers.list.items(.fd)[free_index] = fd;
                    p.subscribers.list.items(.on_event)[free_index] = .{
                        .resume_execution = p.obtainCurrentRestorePoint(),
                    };

                    break :blk free_index;
                } else {
                    try p.subscribers.list.append(p.gpa, .{
                        .fd = fd,
                        .on_event = .{ .resume_execution = p.obtainCurrentRestorePoint() },
                    });

                    break :blk p.subscribers.list.len - 1;
                }
            };

            var event_mask: u32 = @intCast(events);
            event_mask |= linux.EPOLL.ET;
            event_mask |= linux.EPOLL.ONESHOT;

            var ev: linux.epoll_event = .{
                .events = event_mask,
                .data = .{ .u64 = @intCast(index) },
            };

            _ = linux.epoll_ctl(p.epollfd, linux.EPOLL.CTL_ADD, fd, &ev);
            return index;
        }

        fn subscribePoll(p: *ThisPoll, fd: anytype, events: i16) Allocator.Error!usize {
            for (p.subscribers.list.items(.pollfd), p.subscribers.list.items(.on_event), 0..) |*pollfd, *action, i| {
                if (pollfd.fd == fd) {
                    action.* = .{ .resume_execution = p.obtainCurrentRestorePoint() };
                    pollfd.events |= events;
                    return i;
                } else if (pollfd.fd == PollSubscriber.dummy_fd) { // free slot
                    action.* = .{ .resume_execution = p.obtainCurrentRestorePoint() };
                    pollfd.fd = fd;
                    pollfd.events |= events;
                    pollfd.revents = 0;
                    return i;
                }
            } else {
                try p.subscribers.list.append(p.gpa, .{
                    .on_event = .{ .resume_execution = p.obtainCurrentRestorePoint() },
                    .pollfd = .{
                        .fd = fd,
                        .events = events,
                        .revents = 0,
                    },
                });

                p.subscribers.modified = true;
                return p.subscribers.list.len - 1;
            }
        }

        fn async(
            userdata: ?*anyopaque,
            result: []u8,
            result_alignment: Alignment,
            context: []const u8,
            context_alignment: Alignment,
            start: *const fn (context: *const anyopaque, result: *anyopaque) void,
        ) ?*Io.AnyFuture {
            return concurrent(userdata, result.len, result_alignment, context, context_alignment, start) catch {
                start(context.ptr, result.ptr);
                return null;
            };
        }

        fn concurrent(
            userdata: ?*anyopaque,
            result_len: usize,
            result_alignment: Alignment,
            context: []const u8,
            context_alignment: Alignment,
            start: *const fn (context: *const anyopaque, result: *anyopaque) void,
        ) Io.ConcurrentError!*Io.AnyFuture {
            _ = result_alignment;
            _ = context_alignment;

            const p: *ThisPoll = @ptrCast(@alignCast(userdata));

            // `idle_fiber` is required to proceed further.
            p.ensureEventLoop() catch return error.ConcurrencyUnavailable;

            const stack = p.stack_pool.allocate(p.gpa) catch return error.ConcurrencyUnavailable;
            errdefer p.stack_pool.recycle(stack);

            const closure = AsyncClosure.create(
                p.gpa,
                .{ .stack = stack },
                context,
                result_len,
            ) catch return error.ConcurrencyUnavailable;

            errdefer closure.destroy(p.gpa);

            const saved_point = p.pushRestorePoint() catch return error.ConcurrencyUnavailable;
            defer p.gpa.destroy(saved_point);

            FiberBootstrap(AsyncClosure.entryPoint).initFiber(&closure.fiber, .{ closure, p, start });

            // Start the execution immediately.

            p.active_fiber = &closure.fiber;
            switchContext(&.{
                .save = saved_point.context(),
                .restore = &closure.fiber.context,
            });

            return @ptrCast(closure); // Io.AnyFuture (AsyncClosure)
        }

        fn groupAsync(
            userdata: ?*anyopaque,
            group: *Io.Group,
            context: []const u8,
            context_alignment: Alignment,
            start: *const fn (context: *const anyopaque) Io.Cancelable!void,
        ) void {
            groupConcurrent(userdata, group, context, context_alignment, start) catch {
                start(context.ptr) catch {};
            };
        }

        fn groupConcurrent(
            userdata: ?*anyopaque,
            group: *Io.Group,
            context: []const u8,
            context_alignment: Alignment,
            start: *const fn (context: *const anyopaque) Io.Cancelable!void,
        ) Io.ConcurrentError!void {
            _ = context_alignment;
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));

            // `idle_fiber` is required to proceed further.
            p.ensureEventLoop() catch return error.ConcurrencyUnavailable;

            const stack = p.stack_pool.allocate(p.gpa) catch return error.ConcurrencyUnavailable;
            errdefer p.stack_pool.recycle(stack);

            const token: *GroupToken = if (group.token.raw) |gt| @ptrCast(@alignCast(gt)) else blk: {
                const gt = GroupToken.create(p.gpa) catch return error.ConcurrencyUnavailable;
                group.token.raw = gt; // we're single threaded anyway
                break :blk gt;
            };

            const closure = token.alloc(p.gpa, group, stack, context) catch return error.ConcurrencyUnavailable;
            errdefer token.recycle(closure);

            const saved_point = p.pushRestorePoint() catch return error.ConcurrencyUnavailable;
            defer p.gpa.destroy(saved_point);

            FiberBootstrap(GroupClosure.entryPoint).initFiber(&closure.fiber, .{ closure, p, start });

            p.active_fiber = &closure.fiber;
            switchContext(&.{
                .save = saved_point.context(),
                .restore = &closure.fiber.context,
            });
        }

        fn await(
            userdata: ?*anyopaque,
            any_future: *Io.AnyFuture,
            result: []u8,
            result_alignment: Alignment,
        ) void {
            _ = result_alignment;

            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            const closure: *AsyncClosure = @ptrCast(@alignCast(any_future));

            if (closure.state != .finished) {
                var restore_point = p.obtainCurrentRestorePoint();
                closure.fiber.awaiter = &restore_point;
                p.yield(restore_point.context());
            }

            @memcpy(result, closure.result);
            closure.destroy(p.gpa);
        }

        fn cancel(
            userdata: ?*anyopaque,
            any_future: *Io.AnyFuture,
            result: []u8,
            result_alignment: Alignment,
        ) void {
            _ = result_alignment;

            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            const closure: *AsyncClosure = @ptrCast(@alignCast(any_future));

            if (closure.state != .finished) {
                var restore_point = p.obtainCurrentRestorePoint();
                closure.fiber.awaiter = &restore_point;

                if (!closure.fiber.cancelationRequested()) {
                    closure.fiber.cancelation = .requested;
                    closure.fiber.cancelation_node = .{};
                    p.canceled_fibers.append(&closure.fiber.cancelation_node);
                }

                p.yield(restore_point.context());
            }

            @memcpy(result, closure.result);
            closure.destroy(p.gpa);
        }

        fn groupAwait(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            const gt: *GroupToken = @ptrCast(@alignCast(token));

            try gt.waitAll(p, .await);
            gt.destroy(p.gpa);

            group.token.raw = null;
        }

        fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            const gt: *GroupToken = @ptrCast(@alignCast(token));

            gt.waitAll(p, .cancel);
            gt.destroy(p.gpa);

            group.token.raw = null;
        }

        fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.SleepError!void {
            if (timeout == .none) return;
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));

            p.ensureEventLoop() catch return error.Canceled;

            const sleeper = WaitScheduler.Sleeper.create(
                p.gpa,
                p.obtainCurrentRestorePoint(),
                (try timeout.toDeadline(p.io())).?,
                null, // futexless wait
            ) catch return error.Canceled;

            p.wait_scheduler.sleepers.prepend(&sleeper.restore.node);
            p.yield(sleeper.restore.context());

            try checkCancel(p);
        }

        fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.Error!Io.Timestamp {
            _ = userdata;
            return currentTime(clock);
        }

        fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            if (p.interrupted) return error.Canceled;

            if (p.active_fiber) |fiber| if (fiber.cancelationRequested()) {
                return error.Canceled;
            };
        }

        fn select(userdata: ?*anyopaque, futures: []const *Io.AnyFuture) Io.Cancelable!usize {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            defer for (futures) |future| {
                const closure: *AsyncClosure = @ptrCast(@alignCast(future));
                closure.fiber.awaiter = null; // unsubscribe
            };

            var restore_point = p.obtainCurrentRestorePoint();

            for (futures, 0..) |future, i| {
                const closure: *AsyncClosure = @ptrCast(@alignCast(future));
                if (closure.state == .finished) return i;

                closure.fiber.awaiter = &restore_point;
            }

            p.yield(restore_point.context());
            try checkCancel(p);

            for (futures, 0..) |future, i| {
                const closure: *AsyncClosure = @ptrCast(@alignCast(future));
                if (closure.state == .finished) return i;
            } else unreachable; // well, we had to end up being here somehow, so one of them should be done
        }

        fn FiberBootstrap(comptime start: anytype) type {
            const Start = @TypeOf(start);

            comptime {
                if (@typeInfo(Start).@"fn".return_type.? != noreturn) @compileError("invalid fiber start function");
            }

            return struct {
                const Args = std.meta.ArgsTuple(Start);

                pub fn initFiber(fiber: *Fiber, args: Args) void {
                    const args_buf: []const u8 = @ptrCast(&args);
                    const stack = &fiber.stack.stack;

                    @memcpy(stack[stack.len - args_buf.len .. stack.len], args_buf);

                    std.mem.writeInt(
                        usize,
                        stack[stack.len - args_buf.len - 8 ..][0..8],
                        @intFromPtr(stack[stack.len - args_buf.len ..].ptr),
                        .little,
                    );

                    fiber.context = .{
                        .rip = @intFromPtr(&jump),
                        .rsp = @intFromPtr(stack[stack.len - args_buf.len - 8 ..].ptr),
                        .rbp = 0,
                    };
                }

                fn jump() callconv(.naked) noreturn {
                    switch (native_arch) {
                        .x86_64 => switch (native_os) {
                            .windows => asm volatile (
                            // of fucking course callconv(.c) is different on windows
                                \\ leaq 8(%%rsp), %%rcx
                                \\ jmp %[wrapped_start:P]
                                :
                                : [wrapped_start] "X" (&wrappedStart),
                            ),
                            else => asm volatile (
                                \\ leaq 8(%%rsp), %%rdi
                                \\ jmp %[wrapped_start:P]
                                :
                                : [wrapped_start] "X" (&wrappedStart),
                            ),
                        },
                        else => @compileError("architecture '" ++ @tagName(native_arch) ++ "' is not supported yet"),
                    }
                }

                fn wrappedStart(context: *const anyopaque) callconv(.c) noreturn {
                    const args: *const Args = @ptrCast(@alignCast(context));
                    @call(.auto, start, args.*);
                    unreachable;
                }
            };
        }

        fn netBindIp(
            userdata: ?*anyopaque,
            address: *const net.IpAddress,
            options: net.IpAddress.BindOptions,
        ) net.IpAddress.BindError!net.Socket {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));

            const socket = try switch (native_os) {
                .windows => wsaSocket(p, posix.AF.INET, options),
                else => posixSocket(p, posix.AF.INET, options),
            };

            errdefer socketClose(socket);

            try switch (native_os) {
                .windows => wsaBind(p, socket, address),
                else => posixBind(p, socket, address),
            };

            const bound_address: net.IpAddress = if (isRandomAddress(address))
                try getSocketAddress(socket)
            else
                address.*;

            return .{
                .handle = socket,
                .address = bound_address,
            };
        }

        fn netReceive(
            userdata: ?*anyopaque,
            socket: net.Socket.Handle,
            message_buffer: []net.IncomingMessage,
            data_buffer: []u8,
            flags: net.ReceiveFlags,
            timeout: Io.Timeout,
        ) struct { ?net.Socket.ReceiveTimeoutError, usize } {
            // TODO: a very primitive implementation.
            // Only supports receiving one message at a time, no timeouts either.
            // Should be the most portable, though.

            _ = flags;
            if (message_buffer.len == 0) return .{ null, 0 };
            if (timeout != .none) return .{ error.UnsupportedClock, 0 }; // timeouts are not supported for now.

            const p: *ThisPoll = @ptrCast(@alignCast(userdata));

            while (true) {
                checkCancel(p) catch return .{ error.Canceled, 0 };

                const from, const size = switch (native_os) {
                    .windows => wsaRecvfrom(p, socket, data_buffer),
                    else => posixRecvfrom(p, socket, data_buffer),
                } catch |err| switch (err) {
                    error.WouldBlock => {
                        p.blocking(socket, PollSubscriber.Events.IN) catch
                            return .{ error.SystemResources, 0 };

                        continue;
                    },
                    else => |e| return .{ e, 0 },
                };

                message_buffer[0].from = from;
                message_buffer[0].data = data_buffer[0..size];
                return .{ null, 1 };
            }
        }

        // Connectionless sends are allowed to be done even in task cancelation state until they become blocking.
        // Though this might be not always the desired behavior. Should look into `swapCancelProtection`.
        fn netSend(
            userdata: ?*anyopaque,
            handle: net.Socket.Handle,
            messages: []net.OutgoingMessage,
            flags: net.SendFlags,
        ) struct { ?net.Socket.SendError, usize } {
            _ = flags;
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));

            // TODO: use sendmmsg on posix.

            for (messages, 0..) |message, i| {
                _ = while (true) {
                    const data = message.data_ptr[0..message.data_len];

                    break switch (native_os) {
                        .windows => wsaSendto(p, handle, message.address, data),
                        else => posixSendMessage(p, handle, message.address, "", &.{data}, 1),
                    } catch |err| switch (err) {
                        error.WouldBlock => {
                            checkCancel(p) catch return .{ error.Canceled, i };

                            p.blocking(handle, PollSubscriber.Events.OUT) catch
                                return .{ error.SystemResources, i };

                            continue;
                        },
                        else => |e| return .{ e, i },
                    };
                };
            } else return .{ null, messages.len };
        }

        fn netListenIp(
            userdata: ?*anyopaque,
            address: net.IpAddress,
            options: net.IpAddress.ListenOptions,
        ) net.IpAddress.ListenError!net.Server {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));

            const socket = try switch (native_os) {
                .windows => wsaSocket(p, posix.AF.INET, options),
                else => posixSocket(p, posix.AF.INET, options),
            };

            errdefer socketClose(socket);

            try switch (native_os) {
                .windows => wsaBind(p, socket, &address),
                else => posixBind(p, socket, &address),
            };

            try switch (native_os) {
                .windows => wsaListen(p, socket, options.kernel_backlog),
                else => posixListen(p, socket, options.kernel_backlog),
            };

            const bound_address: net.IpAddress = if (isRandomAddress(&address))
                try getSocketAddress(socket)
            else
                address;

            return .{
                .socket = .{
                    .handle = socket,
                    .address = bound_address,
                },
            };
        }

        fn netClose(userdata: ?*anyopaque, handle: []const net.Socket.Handle) void {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));

            for (handle) |socket| {
                socketClose(socket);

                if (native_os != .linux) {
                    // TODO: O(n)
                    for (p.subscribers.list.items(.pollfd)) |*pollfd| {
                        if (pollfd.fd == socket) {
                            pollfd.fd = PollSubscriber.dummy_fd;
                            pollfd.events = 0;
                            break;
                        }
                    }
                }
            }
        }

        fn netAccept(userdata: ?*anyopaque, server: net.Socket.Handle) net.Server.AcceptError!net.Stream {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));

            while (true) {
                try checkCancel(p);

                const socket, const address = switch (native_os) {
                    .windows => wsaAccept(p, server),
                    else => posixAccept(p, server),
                } catch |err| switch (err) {
                    error.WouldBlock => {
                        p.blocking(server, PollSubscriber.Events.IN) catch
                            return error.SystemResources;

                        continue;
                    },
                    else => return err,
                };

                return .{ .socket = .{
                    .handle = socket,
                    .address = address,
                } };
            }
        }

        fn netRead(userdata: ?*anyopaque, src: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));

            while (true) {
                try checkCancel(p);

                return switch (native_os) {
                    .windows => wsaVectoredRead(p, src, data),
                    else => posixVectoredRead(p, src, data),
                } catch |err| switch (err) {
                    error.WouldBlock => {
                        p.blocking(src, PollSubscriber.Events.IN) catch
                            return error.SystemResources;

                        continue;
                    },
                    else => |e| return e,
                };
            }
        }

        fn netWrite(
            userdata: ?*anyopaque,
            dest: net.Socket.Handle,
            header: []const u8,
            data: []const []const u8,
            splat: usize,
        ) net.Stream.Writer.Error!usize {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));

            while (true) {
                try checkCancel(p);

                return switch (native_os) {
                    .windows => wsaWrite(p, dest, header, data, splat),
                    else => posixSendMessage(p, dest, null, header, data, splat),
                } catch |err| switch (err) {
                    error.WouldBlock => {
                        p.blocking(dest, PollSubscriber.Events.OUT) catch
                            return error.SystemResources;

                        continue;
                    },
                    else => |e| return e,
                };
            }
        }

        fn futexWait(
            userdata: ?*anyopaque,
            ptr: *const u32,
            expected: u32,
            timeout: Io.Timeout,
        ) Io.Cancelable!void {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            const wait_until = timeout.toDeadline(p.io()) catch null;

            const sleeper = WaitScheduler.Sleeper.create(
                p.gpa,
                p.obtainCurrentRestorePoint(),
                wait_until,
                .{ .ptr = ptr, .expected = expected },
            ) catch return error.Canceled;

            p.wait_scheduler.sleepers.prepend(&sleeper.restore.node);
            p.yield(sleeper.restore.context());

            try checkCancel(p);
        }

        fn futexWaitUncancelable(
            userdata: ?*anyopaque,
            ptr: *const u32,
            expected: u32,
        ) void {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));

            const sleeper = WaitScheduler.Sleeper.create(
                p.gpa,
                p.obtainCurrentRestorePoint(),
                null,
                .{ .ptr = ptr, .expected = expected },
            ) catch return;

            p.wait_scheduler.sleepers.prepend(&sleeper.restore.node);
            p.yield(sleeper.restore.context());
        }

        fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
            _ = userdata;
            _ = max_waiters;

            @constCast(ptr).* +%= 1;
        }

        fn random(userdata: ?*anyopaque, buffer: []u8) void {
            _ = userdata;

            var t: Io.Threaded = .init_single_threaded;
            const t_io = t.io();

            return t_io.vtable.random(t_io.userdata, buffer);
        }

        fn randomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
            _ = userdata;

            var t: Io.Threaded = .init_single_threaded;
            const t_io = t.io();

            return t_io.vtable.randomSecure(t_io.userdata, buffer);
        }

        // IMO there's no point in reimplementing file operations here, since they'll be blocking anyway.

        fn dirOpenDir(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            options: Io.Dir.OpenOptions,
        ) Io.Dir.OpenError!Io.Dir {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.dirOpenDir(tio.userdata, dir, sub_path, options);
        }

        fn dirRead(userdata: ?*anyopaque, dr: *Io.Dir.Reader, buffer: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.dirRead(tio.userdata, dr, buffer);
        }

        fn dirClose(userdata: ?*anyopaque, dirs: []const Io.Dir) void {
            _ = userdata;
            for (dirs) |dir| posix.close(dir.handle);
        }

        fn dirStat(userdata: ?*anyopaque, dir: Io.Dir) Io.Dir.StatError!Io.Dir.Stat {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.dirStat(tio.userdata, dir);
        }

        fn dirStatFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.dirStatFile(tio.userdata, dir, sub_path, options);
        }

        fn dirAccess(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.AccessOptions) Io.Dir.AccessError!void {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.dirAccess(tio.userdata, dir, sub_path, options);
        }

        fn dirCreateFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, flags: Io.File.CreateFlags) Io.File.OpenError!Io.File {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.dirCreateFile(tio.userdata, dir, sub_path, flags);
        }

        fn dirCreateDir(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, perm: Io.Dir.Permissions) Io.Dir.CreateDirError!void {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.dirCreateDir(tio.userdata, dir, sub_path, perm);
        }

        fn dirCreateDirPath(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, perm: Io.Dir.Permissions) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.dirCreateDirPath(tio.userdata, dir, sub_path, perm);
        }

        fn dirCreateDirPathOpen(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, perm: Io.Dir.Permissions, options: Io.Dir.OpenOptions) Io.Dir.CreateDirPathOpenError!Io.Dir {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.dirCreateDirPathOpen(tio.userdata, dir, sub_path, perm, options);
        }

        fn fileWriteStreaming(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize) Io.File.Writer.Error!usize {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.fileWriteStreaming(tio.userdata, file, header, data, splat);
        }

        fn fileWritePositional(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.fileWritePositional(tio.userdata, file, header, data, splat, offset);
        }

        fn fileClose(userdata: ?*anyopaque, files: []const Io.File) void {
            _ = userdata;
            for (files) |file| posix.close(file.handle);
        }

        fn dirOpenFile(
            userdata: ?*anyopaque,
            dir: Io.Dir,
            sub_path: []const u8,
            flags: Io.File.OpenFlags,
        ) Io.File.OpenError!Io.File {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.dirOpenFile(tio.userdata, dir, sub_path, flags);
        }

        fn fileLength(userdata: ?*anyopaque, file: Io.File) Io.File.LengthError!u64 {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.fileLength(tio.userdata, file);
        }

        fn fileStat(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.fileStat(tio.userdata, file);
        }

        fn fileReadPositional(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.fileReadPositional(tio.userdata, file, data, offset);
        }

        fn fileReadStreaming(userdata: ?*anyopaque, file: Io.File, data: []const []u8) Io.File.Reader.Error!usize {
            const p: *ThisPoll = @ptrCast(@alignCast(userdata));
            try checkCancel(p);

            var t: Io.Threaded = .init_single_threaded;
            const tio = t.io();

            return tio.vtable.fileReadStreaming(tio.userdata, file, data);
        }

        fn socketClose(socket: posix.socket_t) void {
            _ = switch (native_os) {
                .windows => ws2_32.closesocket(socket),
                else => posix.close(socket),
            };
        }

        fn getSocketAddress(socket: net.Socket.Handle) !net.IpAddress {
            switch (native_os) {
                .windows => {
                    var addrlen: i32 = @sizeOf(ws2_32.sockaddr.in);
                    var in: ws2_32.sockaddr.in = undefined;

                    if (ws2_32.getsockname(socket, @ptrCast(&in), &addrlen) == ws2_32.SOCKET_ERROR) {
                        return windows.unexpectedWSAError(ws2_32.WSAGetLastError());
                    }

                    return addressFromWsa(in);
                },
                else => {
                    var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
                    var in: posix.sockaddr.in = undefined;

                    const errno = posix.errno(posix.system.getsockname(socket, @ptrCast(&in), &addrlen));
                    if (errno != .SUCCESS) return posix.unexpectedErrno(errno);

                    return addressFromPosix(in);
                },
            }
        }

        fn posixSocket(p: *ThisPoll, family: posix.sa_family_t, options: anytype) error{
            AddressFamilyUnsupported,
            ProtocolUnsupportedBySystem,
            ProcessFdQuotaExceeded,
            SystemFdQuotaExceeded,
            SystemResources,
            ProtocolUnsupportedByAddressFamily,
            SocketModeUnsupported,
            Unexpected,
            Canceled,
        }!posix.socket_t {
            const Options = @TypeOf(options);
            try checkCancel(p);

            const mode = posixSocketMode(options.mode);
            const protocol = posixProtocol(options.protocol);
            const rc = posix.system.socket(family, mode | posix.SOCK.NONBLOCK, protocol);

            switch (posix.errno(rc)) {
                .SUCCESS => {
                    const socket: posix.socket_t = @intCast(rc);

                    errdefer posix.close(socket);
                    if (@hasField(Options, "reuse_address")) if (options.reuse_address) {
                        switch (posix.errno(posix.system.setsockopt(
                            socket,
                            posix.SOL.SOCKET,
                            posix.SO.REUSEADDR,
                            &std.mem.toBytes(@as(c_int, 1)),
                            4,
                        ))) {
                            .SUCCESS => return socket,
                            else => |err| return posix.unexpectedErrno(err),
                        }
                    };

                    return socket;
                },
                .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                .INVAL => return error.ProtocolUnsupportedBySystem,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
                .PROTOTYPE => return error.SocketModeUnsupported,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        fn wsaSocket(p: *ThisPoll, family: posix.sa_family_t, options: anytype) !ws2_32.SOCKET {
            try checkCancel(p);

            const mode: i32 = @bitCast(posixSocketMode(options.mode));
            const protocol: i32 = @bitCast(posixProtocol(options.protocol));

            const socket = ws2_32.socket(family, mode, protocol);
            if (socket == ws2_32.INVALID_SOCKET) switch (ws2_32.WSAGetLastError()) {
                .NOTINITIALISED => unreachable,
                .EAFNOSUPPORT => return error.AddressFamilyUnsupported,
                .EMFILE => return error.ProcessFdQuotaExceeded,
                .ENOBUFS => return error.SystemResources,
                .EPROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
                else => |err| return windows.unexpectedWSAError(err),
            } else {
                var argp: u32 = 1;
                if (ws2_32.ioctlsocket(socket, ws2_32.FIONBIO, &argp) == ws2_32.SOCKET_ERROR) {
                    return windows.unexpectedWSAError(ws2_32.WSAGetLastError());
                } else return socket;
            }
        }

        fn posixBind(p: *ThisPoll, socket: posix.socket_t, address: *const net.IpAddress) !void {
            _ = p;
            var addr, const len = try posixIpAddress(address);

            switch (posix.errno(posix.system.bind(socket, @ptrCast(&addr), len))) {
                .SUCCESS => {},
                .ADDRINUSE => return error.AddressInUse,
                .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                .ADDRNOTAVAIL => return error.AddressUnavailable,
                .NOMEM => return error.SystemResources,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        fn wsaBind(p: *ThisPoll, socket: ws2_32.SOCKET, address: *const net.IpAddress) !void {
            _ = p;
            var addr, const len = try wsaIpAddress(address);

            if (ws2_32.bind(
                socket,
                @ptrCast(&addr),
                len,
            ) == ws2_32.SOCKET_ERROR) switch (ws2_32.WSAGetLastError()) {
                .EADDRINUSE => return error.AddressInUse,
                .EADDRNOTAVAIL => return error.AddressUnavailable,
                .ENOBUFS => return error.SystemResources,
                .ENETDOWN => return error.NetworkDown,
                else => |err| return windows.unexpectedWSAError(err),
            };
        }

        fn posixListen(p: *ThisPoll, socket: posix.socket_t, backlog: u31) !void {
            _ = p;

            switch (posix.errno(posix.system.listen(socket, @intCast(backlog)))) {
                .SUCCESS => {},
                .ADDRINUSE => return error.AddressInUse,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        fn wsaListen(p: *ThisPoll, socket: ws2_32.SOCKET, backlog: u31) !void {
            _ = p;

            if (ws2_32.listen(socket, @intCast(backlog)) == ws2_32.SOCKET_ERROR) switch (ws2_32.WSAGetLastError()) {
                .ENETDOWN => return error.NetworkDown,
                .EADDRINUSE => return error.AddressInUse,
                .EMFILE, .ENOBUFS => return error.SystemResources,
                else => |err| return windows.unexpectedWSAError(err),
            };
        }

        fn posixAccept(p: *ThisPoll, socket: posix.socket_t) !struct { posix.socket_t, net.IpAddress } {
            _ = p;

            var in_addr: posix.sockaddr.in = undefined;
            var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr.in);

            const accept_rc = posix.system.accept4(
                socket,
                @ptrCast(&in_addr),
                &addrlen,
                posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            );

            switch (posix.errno(accept_rc)) {
                .SUCCESS => return .{ @intCast(accept_rc), addressFromPosix(in_addr) },
                .AGAIN => return error.WouldBlock,
                .CONNABORTED => return error.ConnectionAborted,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .PROTO => return error.ProtocolFailure,
                .PERM => return error.BlockedByFirewall,
                .NOMEM => return error.SystemResources,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        fn wsaAccept(p: *ThisPoll, socket: ws2_32.SOCKET) !struct { ws2_32.SOCKET, net.IpAddress } {
            _ = p;

            var in_addr: ws2_32.sockaddr.in = undefined;
            var addrlen: i32 = @sizeOf(posix.sockaddr.in);

            const accepted_socket = ws2_32.accept(socket, @ptrCast(&in_addr), &addrlen);

            if (accepted_socket == ws2_32.INVALID_SOCKET) switch (ws2_32.WSAGetLastError()) {
                .NOTINITIALISED => unreachable,
                .EWOULDBLOCK => return error.WouldBlock,
                .ECONNRESET => return error.ConnectionAborted,
                .EMFILE => return error.ProcessFdQuotaExceeded,
                .ENETDOWN => return error.NetworkDown,
                .ENOBUFS => return error.SystemResources,
                else => |err| return windows.unexpectedWSAError(err),
            } else {
                var argp: u32 = 1;
                if (ws2_32.ioctlsocket(accepted_socket, ws2_32.FIONBIO, &argp) == ws2_32.SOCKET_ERROR) {
                    _ = ws2_32.closesocket(accepted_socket);
                    return windows.unexpectedWSAError(ws2_32.WSAGetLastError());
                } else return .{ accepted_socket, addressFromWsa(in_addr) };
            }
        }

        fn posixRecvfrom(p: *ThisPoll, fd: posix.fd_t, buffer: []u8) !struct { net.IpAddress, usize } {
            _ = p;

            const flags: u32 = posix.MSG.DONTWAIT | posix.MSG.NOSIGNAL;

            // TODO: ipv4 only.
            var in_addr: posix.sockaddr.in = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

            const rc = posix.system.recvfrom(
                fd,
                buffer.ptr,
                buffer.len,
                flags,
                @ptrCast(&in_addr),
                &addr_len,
            );

            return switch (posix.errno(rc)) {
                .SUCCESS => return .{ addressFromPosix(in_addr), @intCast(rc) },
                .AGAIN => error.WouldBlock,
                .NOMEM => error.SystemResources,
                .NOTCONN => error.SocketUnconnected,
                else => |err| return posix.unexpectedErrno(err),
            };
        }

        fn wsaRecvfrom(p: *ThisPoll, socket: ws2_32.SOCKET, buffer: []u8) !struct { net.IpAddress, usize } {
            _ = p;

            // TODO: ipv4 only.
            var in_addr: ws2_32.sockaddr.in = undefined;
            var addr_len: i32 = @sizeOf(ws2_32.sockaddr.in);

            const rc = ws2_32.recvfrom(socket, buffer.ptr, @intCast(buffer.len), 0, @ptrCast(&in_addr), &addr_len);
            if (rc == ws2_32.SOCKET_ERROR) switch (ws2_32.WSAGetLastError()) {
                .NOTINITIALISED => unreachable,
                .EWOULDBLOCK => return error.WouldBlock,
                .ENETDOWN => return error.NetworkDown,
                .EMSGSIZE => return error.MessageOversize,
                else => |err| return windows.unexpectedWSAError(err),
            } else return .{ addressFromWsa(in_addr), @intCast(rc) };
        }

        fn posixVectoredRead(p: *ThisPoll, fd: posix.fd_t, data: [][]u8) !usize {
            _ = p;
            var iovecs_buffer: [io_options.max_iovecs_len]posix.iovec = undefined;
            var i: usize = 0;
            for (data) |buf| {
                if (iovecs_buffer.len - i == 0) break;
                if (buf.len != 0) {
                    iovecs_buffer[i] = .{ .base = buf.ptr, .len = buf.len };
                    i += 1;
                }
            }

            const dest = iovecs_buffer[0..i];
            assert(dest[0].len > 0);

            const rc = posix.system.readv(fd, dest.ptr, @intCast(dest.len));
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .AGAIN => return error.WouldBlock,
                .CANCELED => return error.Canceled,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .NOTCONN => return error.SocketUnconnected,
                .CONNRESET => return error.ConnectionResetByPeer,
                .TIMEDOUT => return error.Timeout,
                .PIPE => return error.SocketUnconnected,
                .NETDOWN => return error.NetworkDown,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        fn wsaVectoredRead(p: *ThisPoll, socket: ws2_32.SOCKET, data: [][]u8) !usize {
            _ = p;
            const bufs = b: {
                var iovec_buffer: [io_options.max_iovecs_len]ws2_32.WSABUF = undefined;
                var i: usize = 0;
                var n: usize = 0;
                for (data) |buf| {
                    if (iovec_buffer.len - i == 0) break;
                    if (buf.len == 0) continue;
                    if (std.math.cast(u32, buf.len)) |len| {
                        iovec_buffer[i] = .{ .buf = buf.ptr, .len = len };
                        i += 1;
                        n += len;
                        continue;
                    }
                    iovec_buffer[i] = .{ .buf = buf.ptr, .len = std.math.maxInt(u32) };
                    i += 1;
                    n += std.math.maxInt(u32);
                    break;
                }

                const bufs = iovec_buffer[0..i];
                assert(bufs[0].len != 0);

                break :b bufs;
            };

            var flags: u32 = 0;
            var n: u32 = undefined;
            const rc = ws2_32.WSARecv(socket, bufs.ptr, @intCast(bufs.len), &n, &flags, null, null);
            if (rc == ws2_32.SOCKET_ERROR) switch (ws2_32.WSAGetLastError()) {
                .NOTINITIALISED => unreachable,
                .EWOULDBLOCK => return error.WouldBlock,
                .ECONNRESET => return error.ConnectionResetByPeer,
                .ENETDOWN => return error.NetworkDown,
                .ENOTCONN => return error.SocketUnconnected,
                else => |err| return windows.unexpectedWSAError(err),
            } else return n;
        }

        fn posixSendMessage(
            p: *ThisPoll,
            socket: posix.socket_t,
            destination: ?*const net.IpAddress,
            header: []const u8,
            data: []const []const u8,
            splat: usize,
        ) !usize {
            _ = p;

            var iovecs: [io_options.max_iovecs_len]posix.iovec_const = undefined;
            var msg: posix.msghdr_const = .{
                .name = null,
                .namelen = 0,
                .iov = &iovecs,
                .iovlen = 0,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };

            var sockaddr: posix.sockaddr.in = undefined;
            if (destination) |dest| {
                sockaddr, msg.namelen = try posixIpAddress(dest);
                msg.name = @ptrCast(&sockaddr);
            }

            appendIoVec(&iovecs, &msg.iovlen, header);
            for (data[0 .. data.len - 1]) |bytes| appendIoVec(&iovecs, &msg.iovlen, bytes);
            const pattern = data[data.len - 1];
            if (iovecs.len - msg.iovlen != 0) switch (splat) {
                0 => {},
                1 => appendIoVec(&iovecs, &msg.iovlen, pattern),
                else => switch (pattern.len) {
                    0 => {},
                    1 => {
                        var backup_buffer: [io_options.splat_buffer_size]u8 = undefined;
                        const splat_buffer = &backup_buffer;
                        const memset_len = @min(splat_buffer.len, splat);
                        const buf = splat_buffer[0..memset_len];
                        @memset(buf, pattern[0]);
                        appendIoVec(&iovecs, &msg.iovlen, buf);
                        var remaining_splat = splat - buf.len;
                        while (remaining_splat > splat_buffer.len and iovecs.len - msg.iovlen != 0) {
                            assert(buf.len == splat_buffer.len);
                            appendIoVec(&iovecs, &msg.iovlen, splat_buffer);
                            remaining_splat -= splat_buffer.len;
                        }
                        appendIoVec(&iovecs, &msg.iovlen, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
                    },
                    else => for (0..@min(splat, iovecs.len - msg.iovlen)) |_| {
                        appendIoVec(&iovecs, &msg.iovlen, pattern);
                    },
                },
            };

            const rc = posix.system.sendmsg(socket, &msg, posix.MSG.NOSIGNAL);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .AGAIN => return error.WouldBlock,
                .ALREADY => return error.FastOpenAlreadyInProgress,
                .CONNRESET => return error.ConnectionResetByPeer,
                .NOBUFS, .NOMEM => return error.SystemResources,
                .PIPE, .NOTCONN => return error.SocketUnconnected,
                .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                .HOSTUNREACH => return error.HostUnreachable,
                .NETUNREACH => return error.NetworkUnreachable,
                .NETDOWN => return error.NetworkDown,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        // microslop has no unified API for both connected and unconnected sockets like sendmsg would be.
        fn wsaWrite(
            p: *ThisPoll,
            socket: ws2_32.SOCKET,
            header: []const u8,
            data: []const []const u8,
            splat: usize,
        ) !usize {
            _ = p;

            var iovecs: [io_options.max_iovecs_len]ws2_32.WSABUF = undefined;
            var len: u32 = 0;
            appendWsaBuf(&iovecs, &len, header);
            for (data[0 .. data.len - 1]) |bytes| appendWsaBuf(&iovecs, &len, bytes);
            const pattern = data[data.len - 1];
            if (iovecs.len - len != 0) switch (splat) {
                0 => {},
                1 => appendWsaBuf(&iovecs, &len, pattern),
                else => switch (pattern.len) {
                    0 => {},
                    1 => {
                        var backup_buffer: [64]u8 = undefined;
                        const splat_buffer = &backup_buffer;
                        const memset_len = @min(splat_buffer.len, splat);
                        const buf = splat_buffer[0..memset_len];
                        @memset(buf, pattern[0]);
                        appendWsaBuf(&iovecs, &len, buf);
                        var remaining_splat = splat - buf.len;
                        while (remaining_splat > splat_buffer.len and len < iovecs.len) {
                            appendWsaBuf(&iovecs, &len, splat_buffer);
                            remaining_splat -= splat_buffer.len;
                        }
                        appendWsaBuf(&iovecs, &len, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
                    },
                    else => for (0..@min(splat, iovecs.len - len)) |_| {
                        appendWsaBuf(&iovecs, &len, pattern);
                    },
                },
            };

            var n: u32 = undefined;
            const rc = ws2_32.WSASend(socket, &iovecs, len, &n, 0, null, null);
            if (rc == ws2_32.SOCKET_ERROR) switch (ws2_32.WSAGetLastError()) {
                .NOTINITIALISED => unreachable,
                .EWOULDBLOCK => return error.WouldBlock,
                .ECONNABORTED => return error.ConnectionResetByPeer,
                .ECONNRESET => return error.ConnectionResetByPeer,
                .EINVAL => return error.SocketUnconnected,
                .ENETDOWN => return error.NetworkDown,
                .ENETRESET => return error.ConnectionResetByPeer,
                .ENOBUFS => return error.SystemResources,
                .ENOTCONN => return error.SocketUnconnected,
                else => |err| return windows.unexpectedWSAError(err),
            } else return n;
        }

        fn wsaSendto(
            p: *ThisPoll,
            socket: ws2_32.SOCKET,
            destination: *const net.IpAddress,
            data: []const u8,
        ) !void {
            _ = p;
            const to, const addrlen = try wsaIpAddress(destination);

            var iovecs: [1]ws2_32.WSABUF = undefined;
            var len: u32 = 0;
            appendWsaBuf(&iovecs, &len, data);

            var n: u32 = undefined;
            const rc = ws2_32.WSASendTo(socket, &iovecs, 1, &n, 0, @ptrCast(&to), addrlen, null, null);
            if (rc == ws2_32.SOCKET_ERROR) switch (ws2_32.WSAGetLastError()) {
                .NOTINITIALISED => unreachable,
                .EWOULDBLOCK => return error.WouldBlock,
                .ECONNABORTED => return error.ConnectionResetByPeer,
                .ECONNRESET => return error.ConnectionResetByPeer,
                .EINVAL => return error.SocketUnconnected,
                .ENETDOWN => return error.NetworkDown,
                .ENETRESET => return error.ConnectionResetByPeer,
                .ENOBUFS => return error.SystemResources,
                .ENOTCONN => return error.SocketUnconnected,
                else => |err| return windows.unexpectedWSAError(err),
            };
        }

        fn setInterruptHandler(waker: Waker) void {
            if (native_os == .windows) {
                InterruptHandler.waker = waker;
                windows.SetConsoleCtrlHandler(InterruptHandler.onInterruptWindows, true) catch {};
            } else {
                posix.sigaction(posix.SIG.INT, &.{
                    .handler = .{ .handler = InterruptHandler.onInterruptPosix },
                    .mask = @splat(0),
                    .flags = 0,
                }, null);
            }
        }

        const InterruptHandler = struct {
            pub var waker: Waker = undefined;
            pub var sigint_received: bool = false;

            fn onInterruptPosix(_: posix.SIG) callconv(.c) void {
                InterruptHandler.sigint_received = true;
            }

            fn onInterruptWindows(ctrl_type: windows.DWORD) callconv(.c) windows.BOOL {
                if (ctrl_type == 0) {
                    InterruptHandler.sigint_received = true;
                    InterruptHandler.waker.trigger();
                    return 1;
                }

                return 0;
            }
        };

        const Waker = if (native_os == .windows) struct {
            socket: ws2_32.SOCKET,
            addr: ws2_32.sockaddr.in,

            pub fn init() Waker {
                // TODO: could be also a POSIX environment without ppoll.
                if (native_os != .windows) comptime unreachable;

                const socket = ws2_32.socket(ws2_32.AF.INET, ws2_32.SOCK.DGRAM, 0);
                if (socket == ws2_32.INVALID_SOCKET) @panic("unexpected WSA error.");

                var addrlen: i32 = @sizeOf(ws2_32.sockaddr.in);
                var loopback: ws2_32.sockaddr.in = .{
                    .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
                    .port = 0,
                };

                if (ws2_32.bind(socket, @ptrCast(&loopback), addrlen) != 0) {
                    @panic("unexpected WSA error.");
                }

                if (ws2_32.getsockname(socket, @ptrCast(&loopback), &addrlen) != 0) {
                    @panic("unexpected WSA error.");
                }

                return .{ .socket = socket, .addr = loopback };
            }

            pub fn trigger(waker: *Waker) void {
                _ = ws2_32.sendto(waker.socket, &.{1}, 1, 0, @ptrCast(&waker.addr), @sizeOf(ws2_32.sockaddr.in));
            }
        } else void;

        const vtable: Io.VTable = blk: {
            var result: Io.VTable = undefined;
            for (@typeInfo(Io.VTable).@"struct".fields) |entry| {
                if (@hasDecl(ThisPoll, entry.name)) {
                    @field(result, entry.name) = @field(ThisPoll, entry.name);
                } else {
                    const stub = struct {
                        fn panic() void {
                            @panic("Not implemented yet: " ++ entry.name);
                        }
                    };

                    @field(result, entry.name) = @ptrCast(&stub.panic);
                }
            }

            break :blk result;
        };

        pub fn io(p: *ThisPoll) Io {
            return .{ .userdata = p, .vtable = &vtable };
        }
    };
}

fn clockToPosix(clock: Io.Clock) Io.Clock.Error!posix.clockid_t {
    return switch (clock) {
        .real => posix.CLOCK.REALTIME,
        .awake => switch (native_os) {
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => posix.CLOCK.UPTIME_RAW,
            else => posix.CLOCK.MONOTONIC,
        },
        .boot => switch (native_os) {
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => posix.CLOCK.MONOTONIC_RAW,
            .freebsd, .dragonfly => posix.CLOCK.MONOTONIC_FAST,
            .linux => posix.CLOCK.BOOTTIME,
            else => posix.CLOCK.MONOTONIC,
        },
        .cpu_thread, .cpu_process => return error.UnsupportedClock,
    };
}

fn currentTime(clock: Io.Clock) Io.Clock.Error!Io.Timestamp {
    if (native_os == .windows) {
        switch (clock) {
            .real => {
                const epoch_ns = std.time.epoch.windows * std.time.ns_per_s;
                return .{ .nanoseconds = @as(i96, windows.ntdll.RtlGetSystemTimePrecise()) * 100 + epoch_ns };
            },
            .awake, .boot => {
                const qpc = windows.QueryPerformanceCounter();
                const qpf = windows.QueryPerformanceFrequency();
                const common_qpf = 10_000_000;
                if (qpf == common_qpf) return .{ .nanoseconds = qpc * (std.time.ns_per_s / common_qpf) };

                const scale = @as(u64, std.time.ns_per_s << 32) / @as(u32, @intCast(qpf));
                const result = (@as(u96, qpc) * scale) >> 32;
                return .{ .nanoseconds = @intCast(result) };
            },
            else => return error.UnsupportedClock,
        }
    } else { // POSIX
        const clock_id: posix.clockid_t = try clockToPosix(clock);
        var tp: posix.timespec = undefined;

        switch (posix.errno(posix.system.clock_gettime(clock_id, &tp))) {
            .SUCCESS => return .{ .nanoseconds = @intCast(@as(i128, tp.sec) * std.time.ns_per_s + tp.nsec) },
            .INVAL => return error.UnsupportedClock,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn posixSocketMode(mode: net.Socket.Mode) u32 {
    return switch (mode) {
        .stream => posix.SOCK.STREAM,
        .dgram => posix.SOCK.DGRAM,
        .seqpacket => posix.SOCK.SEQPACKET,
        .raw => posix.SOCK.RAW,
        .rdm => posix.SOCK.RDM,
    };
}

fn posixProtocol(protocol: ?net.Protocol) u32 {
    return @intFromEnum(protocol orelse return 0);
}

pub fn addressFromPosix(in: posix.sockaddr.in) net.IpAddress {
    return .{ .ip4 = .{
        .port = std.mem.bigToNative(u16, in.port),
        .bytes = @bitCast(in.addr),
    } };
}

pub fn addressFromWsa(in: ws2_32.sockaddr.in) net.IpAddress {
    return .{ .ip4 = .{
        .port = std.mem.bigToNative(u16, in.port),
        .bytes = @bitCast(in.addr),
    } };
}

fn posixIpAddress(
    address: *const net.IpAddress,
) error{AddressFamilyUnsupported}!struct { posix.sockaddr.in, posix.socklen_t } {
    return switch (address.*) {
        .ip4 => |a| .{ .{
            .addr = @bitCast(a.bytes),
            .port = std.mem.nativeToBig(u16, a.port),
        }, @sizeOf(posix.sockaddr.in) },
        .ip6 => return error.AddressFamilyUnsupported, // TODO
    };
}

fn wsaIpAddress(
    address: *const net.IpAddress,
) error{AddressFamilyUnsupported}!struct { ws2_32.sockaddr.in, i32 } {
    return switch (address.*) {
        .ip4 => |a| .{ .{
            .addr = @bitCast(a.bytes),
            .port = std.mem.nativeToBig(u16, a.port),
        }, @sizeOf(ws2_32.sockaddr.in) },
        .ip6 => return error.AddressFamilyUnsupported, // TODO
    };
}

fn isRandomAddress(address: *const net.IpAddress) bool {
    return switch (address.*) {
        inline else => |a| a.port == 0,
    };
}

fn appendIoVec(v: []posix.iovec_const, i: *iovlen_t, bytes: []const u8) void {
    if (bytes.len == 0) return;
    if (v.len - i.* == 0) return;

    v[i.*] = .{ .base = bytes.ptr, .len = bytes.len };
    i.* += 1;
}

fn appendWsaBuf(v: []ws2_32.WSABUF, i: *u32, bytes: []const u8) void {
    const cap = std.math.maxInt(u32);
    var remaining = bytes;
    while (remaining.len > cap) {
        if (v.len - i.* == 0) return;
        v[i.*] = .{ .buf = @constCast(remaining.ptr), .len = cap };
        i.* += 1;
        remaining = remaining[cap..];
    } else {
        @branchHint(.likely);
        if (v.len - i.* == 0) return;
        v[i.*] = .{ .buf = @constCast(remaining.ptr), .len = @intCast(remaining.len) };
        i.* += 1;
    }
}

fn timespecToMs(timespec: posix.timespec) i64 {
    return @intCast((timespec.sec * 1000) + @divFloor(timespec.nsec, std.time.ns_per_ms));
}

fn initWSA() void {
    const wsa_version: u16 = 0x0202;
    var data: ws2_32.WSADATA = undefined;

    _ = ws2_32.WSAStartup(wsa_version, &data);
}

fn epoll_pwait2(epoll_fd: i32, events: [*]linux.epoll_event, maxevents: u32, timeout: ?*linux.timespec, sigmask: ?*const linux.sigset_t) usize {
    return linux.syscall6(
        .epoll_pwait2,
        @as(usize, @bitCast(@as(isize, epoll_fd))),
        @intFromPtr(events),
        @as(usize, @intCast(maxevents)),
        @intFromPtr(timeout),
        @intFromPtr(sigmask),
        linux.NSIG / 8,
    );
}

fn switchContext(pair: *const ContextPair) void {
    switch (native_arch) {
        .x86_64 => asm volatile (
            \\ movq 0(%%rsi), %%rax
            \\ movq 8(%%rsi), %%rcx
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ jmpq *16(%%rcx)
            \\0:
            :
            : [pair] "{rsi}" (pair),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .rbx = true,
              .rsi = true,
              .rdi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .r12 = true,
              .r13 = true,
              .r14 = true,
              .r15 = true,
              .mm0 = true,
              .mm1 = true,
              .mm2 = true,
              .mm3 = true,
              .mm4 = true,
              .mm5 = true,
              .mm6 = true,
              .mm7 = true,
              .zmm0 = true,
              .zmm1 = true,
              .zmm2 = true,
              .zmm3 = true,
              .zmm4 = true,
              .zmm5 = true,
              .zmm6 = true,
              .zmm7 = true,
              .zmm8 = true,
              .zmm9 = true,
              .zmm10 = true,
              .zmm11 = true,
              .zmm12 = true,
              .zmm13 = true,
              .zmm14 = true,
              .zmm15 = true,
              .zmm16 = true,
              .zmm17 = true,
              .zmm18 = true,
              .zmm19 = true,
              .zmm20 = true,
              .zmm21 = true,
              .zmm22 = true,
              .zmm23 = true,
              .zmm24 = true,
              .zmm25 = true,
              .zmm26 = true,
              .zmm27 = true,
              .zmm28 = true,
              .zmm29 = true,
              .zmm30 = true,
              .zmm31 = true,
              .fpsr = true,
              .fpcr = true,
              .mxcsr = true,
              .rflags = true,
              .dirflag = true,
              .memory = true,
            }),
        else => @compileError("architecture '" ++ @tagName(native_arch) ++ "' is not supported yet"),
    }
}
