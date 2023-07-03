const std = @import("std");
const Sink = @import("sink.zig").Sink;
const Signal = @import("signal.zig").Signal;
const utils = @import("../ecs/utils.zig");

pub const Dispatcher = struct {
    signals: std.AutoHashMap(u32, usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return Dispatcher{
            .signals = std.AutoHashMap(u32, usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        var iter = self.signals.iterator();
        while (iter.next()) |ptr| {
            // HACK: we dont know the Type here but we need to call deinit
            var signal = @as(*Signal(void), @ptrFromInt(ptr.value_ptr.*));
            signal.deinit();
        }

        self.signals.deinit();
    }

    fn assure(self: *Dispatcher, comptime T: type) *Signal(T) {
        var type_id = utils.typeId(T);
        if (self.signals.get(type_id)) |value| {
            return @as(*Signal(T), @ptrFromInt(value));
        }

        var signal = Signal(T).create(self.allocator);
        var signal_ptr = @intFromPtr(signal);
        _ = self.signals.put(type_id, signal_ptr) catch unreachable;
        return signal;
    }

    pub fn sink(self: *Dispatcher, comptime T: type) Sink(T) {
        return self.assure(T).sink();
    }

    pub fn trigger(self: *Dispatcher, comptime T: type, value: T) void {
        self.assure(T).publish(value);
    }
};
