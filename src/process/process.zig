const std = @import("std");

/// Processes are run by the Scheduler. They use a similar pattern to Allocators in that they are created and
/// added as fields in a parent struct, your actual process that will be run.
pub const Process = struct {
    const State = enum(u8) { uninitialized, running, paused, succeeded, failed, aborted, finished };

    updateFn: *const fn (self: *Process) void,
    startFn: ?*const fn (self: *Process) void = null,
    abortedFn: ?*const fn (self: *Process) void = null,
    failedFn: ?*const fn (self: *Process) void = null,
    succeededFn: ?*const fn (self: *Process) void = null,
    deinit: *const fn (self: *Process, allocator: std.mem.Allocator) void = undefined,

    state: State = .uninitialized,
    stopped: bool = false,
    next: ?*Process = null,

    pub fn getParent(self: *Process, comptime T: type) *T {
        return @fieldParentPtr("process", self);
    }

    /// Terminates a process with success if it's still alive
    pub fn succeed(self: *Process) void {
        if (self.alive()) self.state = .succeeded;
    }

    /// Terminates a process with errors if it's still alive
    pub fn fail(self: *Process) void {
        if (self.alive()) self.state = .failed;
    }

    /// Stops a process if it's in a running state
    pub fn pause(self: *Process) void {
        if (self.state == .running) self.state = .paused;
    }

    /// Restarts a process if it's paused
    pub fn unpause(self: *Process) void {
        if (self.state == .paused) self.state = .running;
    }

    /// Aborts a process if it's still alive
    pub fn abort(self: *Process, immediately: bool) void {
        if (self.alive()) {
            self.state = .aborted;

            if (immediately) {
                self.tick();
            }
        }
    }

    /// Returns true if a process is either running or paused
    pub fn alive(self: Process) bool {
        return self.state == .running or self.state == .paused;
    }

    /// Returns true if a process is already terminated
    pub fn dead(self: Process) bool {
        return self.state == .finished;
    }

    pub fn rejected(self: Process) bool {
        return self.stopped;
    }

    /// Updates a process and its internal state
    pub fn tick(self: *Process) void {
        switch (self.state) {
            .uninitialized => {
                if (self.startFn) |func| func(self);
                self.state = .running;
            },
            .running => {
                self.updateFn(self);
            },
            else => {},
        }

        // if it's dead, it must be notified and removed immediately
        switch (self.state) {
            .succeeded => {
                if (self.succeededFn) |func| func(self);
                self.state = .finished;
            },
            .failed => {
                if (self.failedFn) |func| func(self);
                self.state = .finished;
                self.stopped = true;
            },
            .aborted => {
                if (self.abortedFn) |func| func(self);
                self.state = .finished;
                self.stopped = true;
            },
            else => {},
        }
    }
};
