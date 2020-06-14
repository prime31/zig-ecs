const std = @import("std");
const Process = @import("process.zig").Process;

pub const Scheduler = struct {
    handlers: std.ArrayList(ProcessHandler),
    allocator: *std.mem.Allocator,

    fn createProcessHandler(comptime T: type) ProcessHandler {
        var proc = std.testing.allocator.create(T) catch unreachable;
        proc.initialize();

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
            return .{.handler = handler};
        }

        // TODO: fix and return when ProcessHandler can have next be a ProcessHandler
        pub fn next(self: *@This(), comptime T: type) void { // *@This()
            var next_handler = createProcessHandler(T);
            self.handler.next = .{.deinitChild = next_handler.deinitChild, .process = next_handler.process};
        }
    };

    // TODO: remove this when ProcessHandler can have next be a ProcessHandler
    const NextProcessHandler = struct {
        deinitChild: fn (process: *Process, allocator: *std.mem.Allocator) void,
        process: *Process,

        pub fn asProcessHandler(self: @This()) ProcessHandler {
            return .{.deinitChild = self.deinitChild, .process = self.process};
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

    pub fn deinit(self: Scheduler) void {
        for (self.handlers.items) |handler| {
            handler.deinit(self.allocator);
        }
        self.handlers.deinit();
    }

    /// Schedules a process for the next tick
    pub fn attach(self: *Scheduler, comptime T: type) Continuation {
        std.debug.assert(@hasDecl(T, "initialize"));
        std.debug.assert(@hasField(T, "process"));

        var handler = createProcessHandler(T);
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
            handler.deinit(handler.process, self.allocator);
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

var fart: usize = 666;

test "" {
    std.debug.warn("\n", .{});

    const Tester = struct {
        process: Process,
        fart: usize,

        pub fn initialize(self: *@This()) void {
            self.process = .{
                .initFn = init,
                .updateFn = update,
                .abortedFn = aborted,
                .failedFn = failed,
                .succeededFn = succeeded,
            };
            self.fart = fart;
            fart += 111;
        }

        fn init(process: *Process) void {
            const self = @fieldParentPtr(@This(), "process", process);
            std.debug.warn("init {}\n", .{self.fart});
        }

        fn aborted(process: *Process) void {
            const self = @fieldParentPtr(@This(), "process", process);
            std.debug.warn("aborted {}\n", .{self.fart});
        }

        fn failed(process: *Process) void {
            const self = @fieldParentPtr(@This(), "process", process);
            std.debug.warn("failed {}\n", .{self.fart});
        }

        fn succeeded(process: *Process) void {
            const self = @fieldParentPtr(@This(), "process", process);
            std.debug.warn("succeeded {}\n", .{self.fart});
        }

        fn update(process: *Process) void {
            const self = @fieldParentPtr(@This(), "process", process);
            std.debug.warn("update {}\n", .{self.fart});
            process.succeed();
        }
    };

    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    _ = scheduler.attach(Tester).next(Tester);
    scheduler.update();
    scheduler.update();
    scheduler.update();
}
