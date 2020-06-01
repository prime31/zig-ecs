const std = @import("std");
const Sink = @import("sink.zig").Sink;
const Signal = @import("signal.zig").Signal;
const TypeMap = @import("../ecs/type_map.zig").TypeMap;

pub const Dispatcher = struct {
    typemap: TypeMap,
    signals: std.AutoHashMap(u8, usize),
    allocator: *std.mem.Allocator,

    pub fn init(allocator: *std.mem.Allocator) Dispatcher {
        return Dispatcher {
            .typemap = TypeMap.init(allocator),
            .signals = std.AutoHashMap(u8, usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Dispatcher) void {
        var it = self.signals.iterator();
        while (it.next()) |ptr| {
            // HACK: we dont know the Type here but we need to call deinit
            var signal = @intToPtr(*Signal(void), ptr.value);
            signal.deinit();
        }

        self.typemap.deinit();
        self.signals.deinit();
    }

    fn assure(self: *Dispatcher, comptime T: type) *Signal(T) {
        var type_id: u8 = undefined;
        if (!self.typemap.getOrPut(T, &type_id)) {
            var signal = Signal(T).create(self.allocator);
            var signal_ptr = @ptrToInt(signal);
            _ = self.signals.put(type_id, signal_ptr) catch unreachable;
            return signal;
        }

        const ptr = self.signals.getValue(type_id).?;
        return @intToPtr(*Signal(T), ptr);
    }

    pub fn sink(self: *Dispatcher, comptime T: type) Sink(T) {
        return self.assure(T).sink();
    }

    pub fn trigger(self: *Dispatcher, comptime T: type, value: T) void {
        self.assure(T).publish(value);
    }
};
