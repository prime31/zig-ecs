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
    handlers: std.ArrayList(ProcessHandler),
    allocator: *std.mem.Allocator,

    /// helper to create and prepare a process and wrap it in a ProcessHandler
    fn createProcessHandler(comptime T: type, data: var) ProcessHandler {
        var proc = std.testing.allocator.create(T) catch unreachable;
        proc.initialize(data);

        // get a closure so that we can safely deinit this later
        var handlerDeinitFn = struct {
            fn deinit(process: *Process, allocator: *std.mem.Allocator) void {
                allocator.destroy(@fieldParentPtr(T, "process", process));
            }
        }.deinit;

        return .{
            .process = &proc.process,
            .deinitChild = handlerDeinitFn,
        };
    }

    const Continuation = struct {
        handler: *ProcessHandler,

        pub fn init(handler: *ProcessHandler) Continuation {
            return .{ .handler = handler };
        }

        // TODO: fix and return this when ProcessHandler can have next be a ProcessHandler
        pub fn next(self: *@This(), comptime T: type, data: var) void { // *@This()
            var next_handler = createProcessHandler(T, data);
            self.handler.next = .{ .deinitChild = next_handler.deinitChild, .process = next_handler.process };
        }
    };

    // TODO: remove this when ProcessHandler can have next be a ProcessHandler
    const NextProcessHandler = struct {
        deinitChild: fn (process: *Process, allocator: *std.mem.Allocator) void,
        process: *Process,

        pub fn asProcessHandler(self: @This()) ProcessHandler {
            return .{ .deinitChild = self.deinitChild, .process = self.process };
        }
    };

    const ProcessHandler = struct {
        deinitChild: fn (process: *Process, allocator: *std.mem.Allocator) void,
        process: *Process,
        next: ?NextProcessHandler = null,

        pub fn update(self: *ProcessHandler, allocator: *std.mem.Allocator) bool {
            self.process.tick();

            if (self.process.dead()) {
                if (!self.process.rejected() and self.next != null) {
                    // kill the old Process parent
                    self.deinitChild(self.process, allocator);

                    // overwrite our fields and kick off the next process
                    self.deinitChild = self.next.?.deinitChild;
                    self.process = self.next.?.process;
                    self.next = null; // TODO: when ProcessHandler can have next be a ProcessHandler
                    return self.update(allocator);
                } else {
                    return true;
                }
            }

            return false;
        }

        pub fn deinit(self: @This(), allocator: *std.mem.Allocator) void {
            if (self.next) |next_handler| {
                next_handler.asProcessHandler().deinit(allocator);
            }
            self.deinitChild(self.process, allocator);
        }
    };

    pub fn init(allocator: *std.mem.Allocator) Scheduler {
        return .{
            .handlers = std.ArrayList(ProcessHandler).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.clear();
        self.handlers.deinit();
    }

    /// Schedules a process for the next tick
    pub fn attach(self: *Scheduler, comptime T: type, data: var) Continuation {
        std.debug.assert(@hasDecl(T, "initialize"));
        std.debug.assert(@hasField(T, "process"));

        var handler = createProcessHandler(T, data);
        handler.process.tick();

        self.handlers.append(handler) catch unreachable;
        return Continuation.init(&self.handlers.items[self.handlers.items.len - 1]);
    }

    /// Updates all scheduled processes
    pub fn update(self: *Scheduler) void {
        if (self.handlers.items.len == 0) return;

        var i: usize = self.handlers.items.len - 1;
        while (true) : (i -= 1) {
            if (self.handlers.items[i].update(self.allocator)) {
                var dead_handler = self.handlers.swapRemove(i);
                dead_handler.deinit(self.allocator);
            }

            if (i == 0) break;
        }
    }

    /// gets the number of processes still running
    pub fn len(self: Scheduler) usize {
        return self.handlers.items.len;
    }

    /// resets the scheduler to its initial state and discards all the processes
    pub fn clear(self: *Scheduler) void {
        for (self.handlers.items) |handler| {
            handler.deinit(self.allocator);
        }
        self.handlers.items.len = 0;
    }

    /// Aborts all scheduled processes. Unless an immediate operation is requested, the abort is scheduled for the next tick
    pub fn abort(self: *Scheduler, immediately: bool) void {
        for (self.handlers.items) |handler| {
            handler.process.abort(immediately);
        }
    }
};

test "" {
    std.debug.warn("\n", .{});

    const Tester = struct {
        process: Process,
        fart: usize,

        pub fn initialize(self: *@This(), data: var) void {
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
            const self = @fieldParentPtr(@This(), "process", process);
            // std.debug.warn("start {}\n", .{self.fart});
        }

        fn aborted(process: *Process) void {
            const self = @fieldParentPtr(@This(), "process", process);
            // std.debug.warn("aborted {}\n", .{self.fart});
        }

        fn failed(process: *Process) void {
            const self = @fieldParentPtr(@This(), "process", process);
            // std.debug.warn("failed {}\n", .{self.fart});
        }

        fn succeeded(process: *Process) void {
            const self = @fieldParentPtr(@This(), "process", process);
            // std.debug.warn("succeeded {}\n", .{self.fart});
        }

        fn update(process: *Process) void {
            const self = @fieldParentPtr(@This(), "process", process);
            // std.debug.warn("update {}\n", .{self.fart});
            process.succeed();
        }
    };

    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    _ = scheduler.attach(Tester, 33).next(Tester, 66);
    scheduler.update();
    scheduler.update();
    scheduler.update();
}

test "scheduler.clear" {
    const Tester = struct {
        process: Process,

        pub fn initialize(self: *@This(), data: var) void {
            self.process = .{ .updateFn = update };
        }

        fn update(process: *Process) void {
            std.debug.assert(false);
        }
    };

    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    _ = scheduler.attach(Tester, {}).next(Tester, {});
    scheduler.clear();
    scheduler.update();
}

test "scheduler.attach.next" {
    const Tester = struct {
        process: Process,
        counter: *usize,

        pub fn initialize(self: *@This(), data: var) void {
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
    _ = scheduler.attach(Tester, &counter).next(Tester, &counter);
    scheduler.update();
    scheduler.update();
    std.testing.expectEqual(counter, 2);
}
