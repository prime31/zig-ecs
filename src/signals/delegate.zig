const std = @import("std");

/// wraps either a free function or a bound function that takes an Event as a parameter
pub fn Delegate(comptime Event: type) type {
    return struct {
        const Self = @This();

        ctx_ptr_address: usize = 0,
        callback: union(enum) {
            free: fn (Event) void,
            bound: fn (usize, Event) void,
        },

        /// sets a bound function as the Delegate callback
        pub fn initBound(ctx: var, comptime fn_name: []const u8) Self {
            std.debug.assert(@typeInfo(@TypeOf(ctx)) == .Pointer);
            std.debug.assert(@ptrToInt(ctx) != 0);

            const T = @TypeOf(ctx);
            return Self{
                .ctx_ptr_address = @ptrToInt(ctx),
                .callback = .{
                    .bound = struct {
                        fn cb(self: usize, param: Event) void {
                            return @call(.{ .modifier = .always_inline }, @field(@intToPtr(T, self), fn_name), .{param});
                        }
                    }.cb,
                },
            };
        }

        /// sets a free function as the Delegate callback
        pub fn initFree(func: fn (Event) void) Self {
            return Self{
                .callback = .{ .free = func },
            };
        }

        pub fn trigger(self: Self, param: Event) void {
            switch (self.callback) {
                .free => |func| @call(.{}, func, .{param}),
                .bound => |func| @call(.{}, func, .{ self.ctx_ptr_address, param }),
            }
        }

        pub fn containsFree(self: Self, callback: fn (Event) void) bool {
            return switch (self.callback) {
                .free => |func| func == callback,
                else => false,
            };
        }

        pub fn containsBound(self: Self, ctx: var) bool {
            std.debug.assert(@ptrToInt(ctx) != 0);
            std.debug.assert(@typeInfo(@TypeOf(ctx)) == .Pointer);

            return switch (self.callback) {
                .bound => @ptrToInt(ctx) == self.ctx_ptr_address,
                else => false,
            };
        }
    };
}

fn tester(param: u32) void {
    std.testing.expectEqual(@as(u32, 666), param);
}

const Thing = struct {
    field: f32 = 0,

    pub fn tester(self: *Thing, param: u32) void {
        std.testing.expectEqual(@as(u32, 777), param);
    }
};

test "free Delegate" {
    var d = Delegate(u32).initFree(tester);
    d.trigger(666);
}

test "bound Delegate" {
    var thing = Thing{};

    var d = Delegate(u32).initBound(&thing, "tester");
    d.trigger(777);
}
