const std = @import("std");

pub fn Delegate(comptime Params: anytype) type {
    return DelegateFromTuple(Tuple(Params));
}

/// wraps either a free function or a bind function that takes an Event as a parameter
pub fn DelegateFromTuple(comptime Params: type) type {
    return struct {
        const Self = @This();

        pub const FreeFn = Fn(Params);
        pub fn BindFn(comptime T: type) type {
            const fields = std.meta.fields(Params);
            comptime var params: [1 + fields.len]std.builtin.Type.Fn.Param = undefined;
            params[0] = .{
                .is_generic = false,
                .is_noalias = false,
                .type = T,
            };
            for (fields, 1..) |field, i| {
                params[i] = .{
                    .is_generic = false,
                    .is_noalias = false,
                    .type = field.type,
                };
            }
            return *const @Type(.{ .@"fn" = .{
                .calling_convention = .Unspecified,
                .is_generic = false,
                .is_var_args = false,
                .return_type = void,
                .params = &params,
            } });
        }

        ctx_ptr: usize = 0,
        bind_ptr: usize = 0,
        free_ptr: usize = 0,

        /// sets a bind function as the Delegate callback
        pub fn initBind(ctx_ptr: anytype, bind_fn: BindFn(@TypeOf(ctx_ptr))) Self {
            const T = @TypeOf(ctx_ptr);
            const Temp = struct {
                fn cb(self: Self, params: Params) void {
                    @call(.auto, @as(BindFn(T), @ptrFromInt(self.bind_ptr)), .{@as(T, @ptrFromInt(self.ctx_ptr))} ++ params);
                }
            };
            return Self{
                .ctx_ptr = @intFromPtr(ctx_ptr),
                .free_ptr = @intFromPtr(&Temp.cb),
                .bind_ptr = @intFromPtr(bind_fn),
            };
        }

        /// sets a free function as the Delegate callback
        pub fn initFree(free_fn: FreeFn) Self {
            return Self{
                .free_ptr = @intFromPtr(free_fn),
            };
        }

        pub fn trigger(self: Self, params: Params) void {
            if (self.ctx_ptr == 0) {
                @call(.auto, @as(FreeFn, @ptrFromInt(self.free_ptr)), params);
            } else {
                @as(*const fn (Self, Params) void, @ptrFromInt(self.free_ptr))(self, params);
            }
        }

        pub fn containsFree(self: Self, free_fn: FreeFn) bool {
            return self.ctx_ptr == 0 and self.free_ptr == @intFromPtr(free_fn);
        }

        pub fn containsBound(self: Self, ctx: anytype) bool {
            return self.ctx_ptr == @intFromPtr(ctx);
        }
    };
}

fn Fn(comptime Params: type) type {
    const fields = std.meta.fields(Params);
    comptime var params: [fields.len]std.builtin.Type.Fn.Param = undefined;
    for (fields, 0..) |field, i| {
        params[i] = .{
            .is_generic = false,
            .is_noalias = false,
            .type = field.type,
        };
    }
    return *const @Type(.{ .@"fn" = .{
        .calling_convention = .Unspecified,
        .is_generic = false,
        .is_var_args = false,
        .return_type = void,
        .params = &params,
    } });
}

pub fn Tuple(comptime Params: anytype) type {
    comptime var params: [Params.len]type = undefined;
    for (Params, 0..) |Param, i| {
        params[i] = Param;
    }
    return std.meta.Tuple(&params);
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
