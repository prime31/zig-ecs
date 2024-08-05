const std = @import("std");
const Process = @import("process.zig").Process;

/// Cooperative scheduler for processes. Each process is invoked once per tick. If a process terminates, it's
/// removed automatically from the scheduler and it's never invoked again. A process can also have a child. In
/// this case, the process is replaced with its child when it terminates if it returns with success. In case of errors,
/// both the process and its child are discarded. In order to invoke all scheduled processes, call the `update` member function
/// Processes add themselves by calling `attach` and must satisfy the following conditions:
/// - have a field `process: Process`
/// - have a method `initialize(self: *@This(), data: var) void` that initializes all fields and takes in a the data passed to `attach`
/// - when initializing the `process` field it ust be given an `updateFn`. All other callbacks are optional.
/// - in any callback you can get your oiginal struct back via `process.getParent(@This())`
pub const Scheduler = struct {
    processes: std.ArrayList(*Process),
    allocator: std.mem.Allocator,

    /// helper to create and prepare a process
    fn createProcessHandler(comptime T: type, data: anytype, allocator: std.mem.Allocator) *Process {
        var proc = allocator.create(T) catch unreachable;
        proc.initialize(data);

        // get a closure so that we can safely deinit this later
        proc.process.deinit = struct {
            fn deinit(process: *Process, alloc: std.mem.Allocator) void {
                if (process.next) |next_process| {
                    next_process.deinit(next_process, alloc);
                }
                alloc.destroy(@as(*T, @fieldParentPtr("process", process)));
            }
        }.deinit;

        return &proc.process;
    }

    /// returned when appending a process so that sub-processes can be added to the process
    const Continuation = struct {
        process: *Process,
        allocator: std.mem.Allocator,

        pub fn init(process: *Process, allocator: std.mem.Allocator) Continuation {
            return .{ .process = process, .allocator = allocator };
        }

        pub fn next(self: *@This(), comptime T: type, data: anytype) *@This() {
            self.process.next = createProcessHandler(T, data, self.allocator);
            self.process = self.process.next.?;
            return self;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{
            .processes = std.ArrayList(*Process).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.clear();
        self.processes.deinit();
    }

    /// Schedules a process for the next tick
    pub fn attach(self: *Scheduler, comptime T: type, data: anytype) Continuation {
        std.debug.assert(@hasDecl(T, "initialize"));
        std.debug.assert(@hasField(T, "process"));

        var process = createProcessHandler(T, data, self.allocator);
        process.tick();

        self.processes.append(process) catch unreachable;
        return Continuation.init(process, self.allocator);
    }

    fn updateProcess(process: **Process, allocator: std.mem.Allocator) bool {
        const current_process = process.*;
        current_process.tick();

        if (current_process.dead()) {
            if (!current_process.rejected() and current_process.next != null) {
                // grab the next process and null it out so we dont double-free it later
                const next_process = current_process.next.?;
                current_process.next = null;
                process.* = next_process;

                // kill the old Process parent
                current_process.deinit(current_process, allocator);
                return updateProcess(process, allocator);
            } else {
                return true;
            }
        }

        return false;
    }

    /// Updates all scheduled processes
    pub fn update(self: *Scheduler) void {
        if (self.processes.items.len == 0) return;

        var i: usize = self.processes.items.len - 1;
        while (true) : (i -= 1) {
            if (updateProcess(&self.processes.items[i], self.allocator)) {
                var dead_process = self.processes.swapRemove(i);
                dead_process.deinit(dead_process, self.allocator);
            }

            if (i == 0) break;
        }
    }

    /// gets the number of processes still running
    pub fn len(self: Scheduler) usize {
        return self.processes.items.len;
    }

    /// resets the scheduler to its initial state and discards all the processes
    pub fn clear(self: *Scheduler) void {
        for (self.processes.items) |process| {
            process.deinit(process, self.allocator);
        }
        self.processes.items.len = 0;
    }

    /// Aborts all scheduled processes. Unless an immediate operation is requested, the abort is scheduled for the next tick
    pub fn abort(self: *Scheduler, immediately: bool) void {
        for (self.processes.items) |handler| {
            handler.process.abort(immediately);
        }
    }
};

test "scheduler.update" {
    std.debug.print("\n", .{});

    const Tester = struct {
        process: Process,
        fart: usize,

        pub fn initialize(self: *@This(), data: anytype) void {
            self.process = .{
                .startFn = start,
                .updateFn = update,
                .abortedFn = aborted,
                .failedFn = failed,
                .succeededFn = succeeded,
            };
            self.fart = data;
        }

        fn start(process: *Process) void {
            _ = process.getParent(@This());
            // std.debug.print("start {}\n", .{self.fart});
        }

        fn aborted(process: *Process) void {
            _ = process.getParent(@This());
            // std.debug.print("aborted {}\n", .{self.fart});
        }

        fn failed(process: *Process) void {
            _ = process.getParent(@This());
            // std.debug.print("failed {}\n", .{self.fart});
        }

        fn succeeded(process: *Process) void {
            _ = process.getParent(@This());
            // std.debug.print("succeeded {}\n", .{self.fart});
        }

        fn update(process: *Process) void {
            _ = process.getParent(@This());
            // std.debug.print("update {}\n", .{self.fart});
            process.succeed();
        }
    };

    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var continuation = scheduler.attach(Tester, 33);
    _ = continuation.next(Tester, 66).next(Tester, 88).next(Tester, 99);
    scheduler.update();
    scheduler.update();
    scheduler.update();
    scheduler.update();
    scheduler.update();
}

test "scheduler.clear" {
    const Tester = struct {
        process: Process,

        pub fn initialize(self: *@This(), _: anytype) void {
            self.process = .{ .updateFn = update };
        }

        fn update(_: *Process) void {
            std.debug.assert(false);
        }
    };

    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var continuation = scheduler.attach(Tester, {});
    _ = continuation.next(Tester, {});
    scheduler.clear();
    scheduler.update();
}

test "scheduler.attach.next" {
    const Tester = struct {
        process: Process,
        counter: *usize,

        pub fn initialize(self: *@This(), data: anytype) void {
            self.process = .{ .updateFn = update };
            self.counter = data;
        }

        fn update(process: *Process) void {
            const self = process.getParent(@This());
            self.counter.* += 1;
            process.succeed();
        }
    };

    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var counter: usize = 0;
    var continuation = scheduler.attach(Tester, &counter);
    _ = continuation.next(Tester, &counter);
    scheduler.update();
    scheduler.update();
    try std.testing.expectEqual(counter, 2);
}
