const std = @import("std");
const Sink = @import("sink.zig").Sink;
const Signal = @import("signal.zig").Signal;
const Tuple = @import("delegate.zig").Tuple;
const utils = @import("../ecs/utils.zig");

pub const Dispatcher = struct {
    signals: std.AutoHashMap(u32, *anyopaque),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return Dispatcher{
            .signals = .init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        var iter = self.signals.iterator();
        while (iter.next()) |ptr| {
            // HACK: we dont know the Type here but we need to call deinit
            var signal: *Signal(.{}) = @alignCast(@ptrCast(ptr.value_ptr.*));
            signal.destroy();
        }

        self.signals.deinit();
    }

    fn assure(self: *Dispatcher, comptime Params: anytype) *Signal(Params) {
        const type_id = utils.typeId(Tuple(Params));
        if (self.signals.get(type_id)) |value| {
            return @as(*Signal(Params), @alignCast(@ptrCast(value)));
        }

        const signal = Signal(Params).create(self.allocator);
        _ = self.signals.put(type_id, @ptrCast(signal)) catch unreachable;
        return signal;
    }

    pub fn sink(self: *Dispatcher, comptime Params: anytype) Sink(Params) {
        return self.assure(Params).sink();
    }

    pub fn trigger(self: *Dispatcher, comptime Params: anytype, value: Tuple(Params)) void {
        self.assure(Params).publish(value);
    }
};
