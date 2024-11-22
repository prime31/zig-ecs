const std = @import("std");
const Signal = @import("signal.zig").Signal;
const SignalFromTuple = @import("signal.zig").SignalFromTuple;
const Delegate = @import("delegate.zig").DelegateFromTuple;
const Tuple = @import("delegate.zig").Tuple;

/// helper used to connect and disconnect listeners on the fly from a Signal. Listeners are wrapped in Delegates
/// and can be either free functions or functions bound to a struct.
pub fn Sink(comptime Params: anytype) type {
    return SinkFromTuple(Tuple(Params));
}

/// helper used to connect and disconnect listeners on the fly from a Signal. Listeners are wrapped in Delegates
/// and can be either free functions or functions bound to a struct.
pub fn SinkFromTuple(comptime Params: type) type {
    return struct {
        const Self = @This();

        insert_index: usize,

        /// the Signal this Sink is temporarily wrapping
        var owning_signal: *SignalFromTuple(Params) = undefined;

        pub fn init(signal: *SignalFromTuple(Params)) Self {
            owning_signal = signal;
            return Self{ .insert_index = owning_signal.calls.items.len };
        }

        pub fn before(self: Self, free_fn: ?Delegate(Params).FreeFn) Self {
            if (free_fn) |cb| {
                if (self.indexOf(cb)) |index| {
                    return Self{ .insert_index = index };
                }
            }
            return self;
        }

        pub fn beforeBound(self: Self, ctx_ptr: anytype) Self {
            if (@typeInfo(@TypeOf(ctx_ptr)) == .pointer) {
                if (self.indexOfBound(ctx_ptr)) |index| {
                    return Self{ .insert_index = index };
                }
            }
            return self;
        }

        /// connects a callback `Delegate(Params).FreeFn` to this sink
        /// NOTE: each free_fn can only be connected ONCE to the same sink
        pub fn connect(self: Self, free_fn: Delegate(Params).FreeFn) void {
            std.debug.assert(self.indexOf(free_fn) == null);
            _ = owning_signal.calls.insert(self.insert_index, Delegate(Params).initFree(free_fn)) catch unreachable;
        }

        /// connects a context `Delegate(Params).BindFn(@TypeOf(ctx_ptr))` to this sink
        /// NOTE: each ctx_ptr can only be connected ONCE to the same sink
        pub fn connectBound(self: Self, ctx_ptr: anytype, bind_fn: Delegate(Params).BindFn(@TypeOf(ctx_ptr))) void {
            std.debug.assert(self.indexOfBound(ctx_ptr) == null);
            _ = owning_signal.calls.insert(self.insert_index, Delegate(Params).initBind(ctx_ptr, bind_fn)) catch unreachable;
        }

        pub fn disconnect(self: Self, free_fn: Delegate(Params).FreeFn) void {
            if (self.indexOf(free_fn)) |index| {
                _ = owning_signal.calls.swapRemove(index);
            }
        }

        pub fn disconnectBound(self: Self, ctx_ptr: anytype) void {
            if (self.indexOfBound(ctx_ptr)) |index| {
                _ = owning_signal.calls.swapRemove(index);
            }
        }

        fn indexOf(_: Self, free_fn: Delegate(Params).FreeFn) ?usize {
            for (owning_signal.calls.items, 0..) |call, i| {
                if (call.containsFree(free_fn)) {
                    return i;
                }
            }
            return null;
        }

        fn indexOfBound(_: Self, ctx_ptr: anytype) ?usize {
            for (owning_signal.calls.items, 0..) |call, i| {
                if (call.containsBound(ctx_ptr)) {
                    return i;
                }
            }
            return null;
        }
    };
}

fn tester(param: u32) void {
    std.testing.expectEqual(@as(u32, 666), param) catch unreachable;
}

const Thing = struct {
    field: f32 = 0,

    pub fn tester(_: *Thing, param: u32) void {
        std.testing.expectEqual(@as(u32, 666), param) catch unreachable;
    }
};

test "Sink Before free" {
    var signal = Signal(.{u32}).init(std.testing.allocator);
    defer signal.deinit();

    signal.sink().connect(tester);
    try std.testing.expectEqual(signal.sink().indexOf(tester).?, 0);

    var thing = Thing{};
    signal.sink().before(tester).connectBound(&thing, &Thing.tester);
    try std.testing.expectEqual(signal.sink().indexOfBound(&thing).?, 0);
}

test "Sink Before bound" {
    var signal = Signal(.{u32}).init(std.testing.allocator);
    defer signal.deinit();

    var thing = Thing{};
    signal.sink().connectBound(&thing, &Thing.tester);
    try std.testing.expectEqual(signal.sink().indexOfBound(&thing).?, 0);

    signal.sink().beforeBound(&thing).connect(tester);
    try std.testing.expectEqual(signal.sink().indexOf(tester).?, 0);
}
