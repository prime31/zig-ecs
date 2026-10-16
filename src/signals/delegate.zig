const std = @import("std");

pub fn Delegate(comptime Params: anytype) type {
    return DelegateFromTuple(Tuple(Params));
}

/// wraps either a free function or a bind function that takes an Event as a parameter
pub fn DelegateFromTuple(comptime Params: type) type {
    return struct {
        const Self = @This();

        /// A function pointer type that accepts the tuple params individually.
        /// We use *const anyopaque for storage and cast at call sites.
        pub const FreeFn = FreeFnType(Params);
        pub fn BindFn(comptime T: type) type {
            return BindFnType(T, Params);
        }

        ctx_ptr: ?*anyopaque = null,
        bind_ptr: ?*const anyopaque = null,
        free_ptr: ?*const anyopaque = null,

        /// sets a bind function as the Delegate callback
        pub fn initBind(ctx_ptr: anytype, bind_fn: BindFn(@TypeOf(ctx_ptr))) Self {
            const T = @TypeOf(ctx_ptr);
            const Temp = struct {
                fn cb(self: Self, params: Params) void {
                    @call(
                        .auto,
                        @as(BindFn(T), @ptrCast(@alignCast(self.bind_ptr))),
                        .{@as(T, @ptrCast(@alignCast(self.ctx_ptr)))} ++ params,
                    );
                }
            };
            return Self{
                .ctx_ptr = @ptrCast(ctx_ptr),
                .free_ptr = @ptrCast(&Temp.cb),
                .bind_ptr = @ptrCast(bind_fn),
            };
        }

        /// sets a free function as the Delegate callback
        pub fn initFree(free_fn: FreeFn) Self {
            return Self{
                .free_ptr = @ptrCast(free_fn),
            };
        }

        pub fn trigger(self: Self, params: Params) void {
            if (self.ctx_ptr == null) {
                @call(.auto, @as(FreeFn, @ptrCast(@alignCast(self.free_ptr))), params);
            } else {
                @as(*const fn (Self, Params) void, @ptrCast(@alignCast(self.free_ptr)))(self, params);
            }
        }

        pub fn containsFree(self: Self, free_fn: FreeFn) bool {
            return self.ctx_ptr == null and @intFromPtr(self.free_ptr) == @intFromPtr(free_fn);
        }

        pub fn containsBound(self: Self, ctx: anytype) bool {
            return @intFromPtr(self.ctx_ptr) == @intFromPtr(ctx);
        }
    };
}

/// Generate a free function pointer type from a tuple type, without @Type.
/// Supports up to 8 parameters.
fn FreeFnType(comptime Params: type) type {
    const types = @typeInfo(Params).@"struct".field_types;
    return switch (types.len) {
        0 => *const fn () void,
        1 => *const fn (types[0]) void,
        2 => *const fn (types[0], types[1]) void,
        3 => *const fn (types[0], types[1], types[2]) void,
        4 => *const fn (types[0], types[1], types[2], types[3]) void,
        5 => *const fn (types[0], types[1], types[2], types[3], types[4]) void,
        6 => *const fn (types[0], types[1], types[2], types[3], types[4], types[5]) void,
        7 => *const fn (types[0], types[1], types[2], types[3], types[4], types[5], types[6]) void,
        8 => *const fn (types[0], types[1], types[2], types[3], types[4], types[5], types[6], types[7]) void,
        else => @compileError("Delegate: too many parameters (max 8)"),
    };
}

/// Generate a bound function pointer type (with context as first param) from a tuple type.
/// Supports up to 8 additional parameters.
fn BindFnType(comptime T: type, comptime Params: type) type {
    const types = @typeInfo(Params).@"struct".field_types;
    return switch (types.len) {
        0 => *const fn (T) void,
        1 => *const fn (T, types[0]) void,
        2 => *const fn (T, types[0], types[1]) void,
        3 => *const fn (T, types[0], types[1], types[2]) void,
        4 => *const fn (T, types[0], types[1], types[2], types[3]) void,
        5 => *const fn (T, types[0], types[1], types[2], types[3], types[4]) void,
        6 => *const fn (T, types[0], types[1], types[2], types[3], types[4], types[5]) void,
        7 => *const fn (T, types[0], types[1], types[2], types[3], types[4], types[5], types[6]) void,
        8 => *const fn (T, types[0], types[1], types[2], types[3], types[4], types[5], types[6], types[7]) void,
        else => @compileError("Delegate: too many parameters (max 8)"),
    };
}

pub fn Tuple(comptime Params: anytype) type {
    comptime var params: [Params.len]type = undefined;
    for (Params, 0..) |Param, i| {
        params[i] = Param;
    }
    return @Tuple(&params);
}

fn tester(param: u32) void {
    std.testing.expectEqual(@as(u32, 666), param) catch unreachable;
}

const Thing = struct {
    field: f32 = 0,

    pub fn tester(_: *Thing, param: u32) void {
        std.testing.expectEqual(@as(u32, 777), param) catch unreachable;
    }
};

test "free Delegate" {
    var d = Delegate(.{u32}).initFree(tester);
    d.trigger(.{666});
}

test "bound Delegate" {
    var thing = Thing{};

    var d = Delegate(.{u32}).initBind(&thing, Thing.tester);
    d.trigger(.{777});
}
