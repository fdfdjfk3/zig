const std = @import("std.zig");
const builtin = @import("builtin");
const testing = std.testing;
const SpinLock = std.SpinLock;
const assert = std.debug.assert;
const c = std.c;
const os = std.os;
const time = std.time;
const linux = os.linux;
const windows = os.windows;

/// A resource object which supports blocking until signaled.
/// Once finished, the `deinit()` method should be called for correctness.
pub const ResetEvent = struct {
    os_event: OsEvent,

    pub const OsEvent = if (builtin.single_threaded) DebugEvent else switch (builtin.os) {
        .windows => AtomicEvent,
        else => if (builtin.link_libc) PosixEvent else AtomicEvent,
    };

    pub fn init() ResetEvent {
        return ResetEvent{ .os_event = OsEvent.init() };
    }

    pub fn deinit(self: *ResetEvent) void {
        self.os_event.deinit();
    }

    /// Returns whether or not the event is currenetly set
    pub fn isSet(self: *ResetEvent) bool {
        return self.os_event.isSet();
    }

    /// Sets the event if not already set and
    /// wakes up at least one thread waiting the event.
    pub fn set(self: *ResetEvent) void {
        return self.os_event.set();
    }

    /// Resets the event to its original, unset state.
    pub fn reset(self: *ResetEvent) void {
        return self.os_event.reset();
    }

    /// Wait for the event to be set by blocking the current thread.
    pub fn wait(self: *ResetEvent) void {
        return self.os_event.wait(null) catch unreachable;
    }

    /// Wait for the event to be set by blocking the current thread.
    /// A timeout in nanoseconds can be provided as a hint for how
    /// long the thread should block on the unset event before throwind error.TimedOut.
    pub fn timedWait(self: *ResetEvent, timeout_ns: u64) !void {
        return self.os_event.wait(timeout_ns);
    }
};

const DebugEvent = struct {
    is_set: bool,

    fn init() DebugEvent {
        return DebugEvent{ .is_set = false };
    }

    fn deinit(self: *DebugEvent) void {
        self.* = undefined;
    }

    fn isSet(self: *DebugEvent) bool {
        return self.is_set;
    }

    fn reset(self: *DebugEvent) void {
        self.is_set = false;
    }

    fn set(self: *DebugEvent) void {
        self.is_set = true;
    }

    fn wait(self: *DebugEvent, timeout: ?u64) !void {
        if (self.is_set)
            return;
        if (timeout != null)
            return error.TimedOut;
        @panic("deadlock detected");
    }
};

const PosixEvent = struct {
    is_set: bool,
    cond: c.pthread_cond_t,
    mutex: c.pthread_mutex_t,

    fn init() PosixEvent {
        return PosixEvent{
            .is_set = false,
            .cond = c.PTHREAD_COND_INITIALIZER,
            .mutex = c.PTHREAD_MUTEX_INITIALIZER,
        };
    }

    fn deinit(self: *PosixEvent) void {
        // on dragonfly, *destroy() functions can return EINVAL 
        // for statically initialized pthread structures
        const err = if (builtin.os == .dragonfly) os.EINVAL else 0;

        const retm = c.pthread_mutex_destroy(&self.mutex);
        assert(retm == 0 or retm == err);
        const retc = c.pthread_cond_destroy(&self.cond);
        assert(retc == 0 or retc == err);
    }

    fn isSet(self: *PosixEvent) bool {
        assert(c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(c.pthread_mutex_unlock(&self.mutex) == 0);

        return self.is_set;
    }

    fn reset(self: *PosixEvent) void {
        assert(c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(c.pthread_mutex_unlock(&self.mutex) == 0);

        self.is_set = false;
    }

    fn set(self: *PosixEvent) void {
        assert(c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(c.pthread_mutex_unlock(&self.mutex) == 0);

        if (!self.is_set) {
            self.is_set = true;
            assert(c.pthread_cond_signal(&self.cond) == 0);
        }
    }

    fn wait(self: *PosixEvent, timeout: ?u64) !void {
        assert(c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(c.pthread_mutex_unlock(&self.mutex) == 0);

        // quick guard before possibly calling time syscalls below
        if (self.is_set)
            return;

        var ts: os.timespec = undefined;
        if (timeout) |timeout_ns| {
            var timeout_abs = timeout_ns;
            if (comptime std.Target.current.isDarwin()) {
                var tv: os.darwin.timeval = undefined;
                assert(os.darwin.gettimeofday(&tv, null) == 0);
                timeout_abs += @intCast(u64, tv.tv_sec) * time.second;
                timeout_abs += @intCast(u64, tv.tv_usec) * time.microsecond;
            } else {
                os.clock_gettime(os.CLOCK_REALTIME, &ts) catch unreachable;
                timeout_abs += @intCast(u64, ts.tv_sec) * time.second;
                timeout_abs += @intCast(u64, ts.tv_nsec);
            }
            ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), @divFloor(timeout_abs, time.second));
            ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), @mod(timeout_abs, time.second));
        }

        while (!self.is_set) {
            const rc = switch (timeout == null) {
                true => c.pthread_cond_wait(&self.cond, &self.mutex),
                else => c.pthread_cond_timedwait(&self.cond, &self.mutex, &ts),
            };
            switch (rc) {
                0 => {},
                os.ETIMEDOUT => return error.TimedOut,
                os.EINVAL => unreachable,
                os.EPERM => unreachable,
                else => unreachable,
            }
        }
    }
};

const AtomicEvent = struct {
    state: State,

    const State = enum(i32) {
        Empty,
        Waiting,
        Signaled,
    };

    fn init() AtomicEvent {
        return AtomicEvent{ .state = .Empty };
    }

    fn deinit(self: *AtomicEvent) void {
        self.* = undefined;
    }

    fn isSet(self: *AtomicEvent) bool {
        return @atomicLoad(State, &self.state, .Acquire) == .Signaled;
    }

    fn reset(self: *AtomicEvent) void {
        @atomicStore(State, &self.state, .Empty, .Monotonic);
    }

    fn set(self: *AtomicEvent) void {
        if (@atomicRmw(State, &self.state, .Xchg, .Signaled, .Release) == .Waiting)
            Futex.wake(@ptrCast(*i32, &self.state));
    }

    fn wait(self: *AtomicEvent, timeout: ?u64) !void {
        var state = @atomicLoad(State, &self.state, .Monotonic);
        while (state == .Empty) {
            state = @cmpxchgWeak(State, &self.state, .Empty, .Waiting, .Acquire, .Monotonic) orelse 
                return Futex.wait(@ptrCast(*i32, &self.state), @enumToInt(State.Waiting), timeout);
        }
    }

    pub const Futex = switch (builtin.os) {
        .windows => WindowsFutex,
        .linux => LinuxFutex,
        else => SpinFutex,
    };

    const SpinFutex = struct {
        fn wake(ptr: *i32) void {}

        fn wait(ptr: *i32, expected: i32, timeout: ?u64) !void {
            // TODO: handle platforms where a monotonic timer isnt available
            var timer: time.Timer = undefined;
            if (timeout != null)
                timer = time.Timer.start() catch unreachable;

            while (@atomicLoad(i32, ptr, .Acquire) == expected) {
                switch (builtin.os) {
                    .windows => SpinLock.yield(400),
                    else => os.sched_yield() catch SpinLock.yield(1),
                }
                if (timeout) |timeout_ns| {
                    if (timer.read() >= timeout_ns)
                        return error.TimedOut;
                }
            }
        }
    };

    const LinuxFutex = struct {
        fn wake(ptr: *i32) void {
            const rc = linux.futex_wake(ptr, linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG, 1);
            assert(linux.getErrno(rc) == 0);
        }

        fn wait(ptr: *i32, expected: i32, timeout: ?u64) !void {
            var ts: linux.timespec = undefined;
            var ts_ptr: ?*linux.timespec = null;
            if (timeout) |timeout_ns| {
                ts_ptr = &ts;
                ts.tv_sec = @intCast(isize, timeout_ns / time.ns_per_s);
                ts.tv_nsec = @intCast(isize, timeout_ns % time.ns_per_s);
            }

            while (@atomicLoad(i32, ptr, .Acquire) == expected) {
                const rc = linux.futex_wait(ptr, linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG, expected, ts_ptr);
                switch (linux.getErrno(rc)) {
                    0 => continue,
                    os.ETIMEDOUT => return error.TimedOut,
                    os.EINTR => continue,
                    os.EAGAIN => return,
                    else => unreachable,
                }
            }
        }
    };

    const WindowsFutex = struct {
        pub fn wake(ptr: *i32) void {
            const handle = getEventHandle() orelse return SpinFutex.wake(ptr);
            const key = @ptrCast(*const c_void, ptr);
            const rc = windows.ntdll.NtReleaseKeyedEvent(handle, key, windows.FALSE, null);
            assert(rc == 0);
        }

        pub fn wait(ptr: *i32, expected: i32, timeout: ?u64) !void {
            const handle = getEventHandle() orelse return SpinFutex.wait(ptr, expected, timeout);

            // NT uses timeouts in units of 100ns with negative value being relative
            var timeout_ptr: ?*windows.LARGE_INTEGER = null;
            var timeout_value: windows.LARGE_INTEGER = undefined;
            if (timeout) |timeout_ns| {
                timeout_ptr = &timeout_value;
                timeout_value = -@intCast(windows.LARGE_INTEGER, timeout_ns / 100);
            }

            // NtWaitForKeyedEvent doesnt have spurious wake-ups
            const key = @ptrCast(*const c_void, ptr);
            const rc = windows.ntdll.NtWaitForKeyedEvent(handle, key, windows.FALSE, timeout_ptr);
            switch (rc) {
                windows.WAIT_TIMEOUT => return error.TimedOut,
                windows.WAIT_OBJECT_0 => {},
                else => unreachable,
            }
        }

        var event_handle: usize = EMPTY;
        const EMPTY = ~@as(usize, 0);
        const LOADING = EMPTY - 1;

        pub fn getEventHandle() ?windows.HANDLE {
            var handle = @atomicLoad(usize, &event_handle, .Monotonic);
            while (true) {
                switch (handle) {
                    EMPTY => handle = @cmpxchgWeak(usize, &event_handle, EMPTY, LOADING, .Acquire, .Monotonic) orelse {
                        const handle_ptr = @ptrCast(*windows.HANDLE, &handle);
                        const access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE;
                        if (windows.ntdll.NtCreateKeyedEvent(handle_ptr, access_mask, null, 0) != 0)
                            handle = 0;
                        @atomicStore(usize, &event_handle, handle, .Monotonic);
                        return @intToPtr(?windows.HANDLE, handle);
                    },
                    LOADING => {
                        SpinLock.yield(1000);
                        handle = @atomicLoad(usize, &event_handle, .Monotonic);
                    },
                    else => {
                        return @intToPtr(?windows.HANDLE, handle);
                    },
                }
            }
        }
    };
};

test "std.ResetEvent" {
    var event = ResetEvent.init();
    defer event.deinit();

    // test event setting
    testing.expect(event.isSet() == false);
    event.set();
    testing.expect(event.isSet() == true);

    // test event resetting
    event.reset();
    testing.expect(event.isSet() == false);

    // test event waiting (non-blocking)
    event.set();
    event.wait();
    try event.timedWait(1);

    // test cross-thread signaling
    if (builtin.single_threaded)
        return;

    const Context = struct {
        const Self = @This();

        value: u128,
        in: ResetEvent,
        out: ResetEvent,

        fn init() Self {
            return Self{
                .value = 0,
                .in = ResetEvent.init(),
                .out = ResetEvent.init(),
            };
        }

        fn deinit(self: *Self) void {
            self.in.deinit();
            self.out.deinit();
            self.* = undefined;
        }

        fn sender(self: *Self) void {
            // update value and signal input
            testing.expect(self.value == 0);
            self.value = 1;
            self.in.set();

            // wait for receiver to update value and signal output
            self.out.wait();
            testing.expect(self.value == 2);
            
            // update value and signal final input
            self.value = 3;
            self.in.set();
        }

        fn receiver(self: *Self) void {
            // wait for sender to update value and signal input
            self.in.wait();
            assert(self.value == 1);
            
            // update value and signal output
            self.in.reset();
            self.value = 2;
            self.out.set();
            
            // wait for sender to update value and signal final input
            self.in.wait();
            assert(self.value == 3);
        }
    };

    var context = Context.init();
    defer context.deinit();
    const receiver = try std.Thread.spawn(&context, Context.receiver);
    defer receiver.wait();
    context.sender();
}
