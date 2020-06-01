const std = @import("std");
const Signal = @import("signal.zig").Signal;
const Delegate = @import("delegate.zig").Delegate;

/// helper used to connect and disconnect listeners on the fly from a Signal. Listeners are wrapped in Delegates
/// and can be either free functions or functions bound to a struct.
pub fn Sink(comptime Event: type) type {
    return struct {
        const Self = @This();

        /// the Signal this Sink is temporarily wrapping
        var owning_signal: *Signal(Event) = undefined;

        pub fn init(signal: *Signal(Event)) Self {
            owning_signal = signal;
            return Self{};
        }

        pub fn connect(self: Self, callback: fn (Event) void) void {
            self.disconnect(callback);
            _ = owning_signal.calls.append(Delegate(Event).initFree(callback)) catch unreachable;
        }

        pub fn connectBound(self: Self, ctx: var, comptime fn_name: []const u8) void {
            self.disconnectBound(ctx);
            _ = owning_signal.calls.append(Delegate(Event).initBound(ctx, fn_name)) catch unreachable;
        }

        pub fn disconnect(self: Self, callback: fn (Event) void) void {
            for (owning_signal.calls.items) |call, i| {
                if (call.containsFree(callback)) {
                    _ = owning_signal.calls.swapRemove(i);
                    break;
                }
            }
        }

        pub fn disconnectBound(self: Self, ctx: var) void {
            for (owning_signal.calls.items) |call, i| {
                if (call.containsBound(ctx)) {
                    _ = owning_signal.calls.swapRemove(i);
                    break;
                }
            }
        }
    };
}
