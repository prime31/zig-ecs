const std = @import("std");

pub const ErasedPtr = struct {
    ptr: usize,

    pub fn init(ptr: var) ErasedPtr {
        if (@sizeOf(@TypeOf(ptr)) == 0) {
            return .{ .ptr = undefined };
        }
        return .{ .ptr = @ptrToInt(ptr) };
    }

    pub fn as(self: ErasedPtr, comptime T: type) *T {
        if (@sizeOf(T) == 0)
            return @as(T, undefined);
        return self.asPtr(*T);
    }

    pub fn asPtr(self: ErasedPtr, comptime PtrT: type) PtrT {
        if (@sizeOf(PtrT) == 0)
            return @as(PtrT, undefined);
        return @intToPtr(PtrT, self.ptr);
    }
};

/// sorts items using lessThan and keeps sub_items with the same sort
pub fn sortSub(comptime T1: type, comptime T2: type, items: []T1, sub_items: []T2, lessThan: fn (lhs: T1, rhs: T1) bool) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const x = items[i];
        const y = sub_items[i];
        var j: usize = i;
        while (j > 0 and lessThan(x, items[j - 1])) : (j -= 1) {
            items[j] = items[j - 1];
            sub_items[j] = sub_items[j - 1];
        }
        items[j] = x;
        sub_items[j] = y;
    }
}

/// comptime string hashing for the type names
pub fn typeId(comptime T: type) u32 {
    comptime return hashStringFnv(u32, @typeName(T));
}

/// comptime string hashing for the type names
pub fn typeId64(comptime T: type) u64 {
    comptime return hashStringFnv(u64, @typeName(T));
}

/// u32 Fowler-Noll-Vo string hash
pub fn hashString(comptime str: []const u8) u32 {
    return hashStringFnv(u32, str);
}

/// Fowler–Noll–Vo string hash. ReturnType should be u32/u64
pub fn hashStringFnv(comptime ReturnType: type, comptime str: []const u8) ReturnType {
    std.debug.assert(ReturnType == u32 or ReturnType == u64);

    const prime = if (ReturnType == u32) @as(u32, 16777619) else @as(u64, 1099511628211);
    var value = if (ReturnType == u32) @as(u32, 2166136261) else @as(u64, 14695981039346656037);
    for (str) |c| {
        value = (value ^ @intCast(u32, c)) *% prime;
    }
    return value;
}

/// comptime string hashing, djb2 by Dan Bernstein. Fails on large strings.
pub fn hashStringDjb2(comptime str: []const u8) comptime_int {
    var hash: comptime_int = 5381;
    for (str) |c| {
        hash = ((hash << 5) + hash) + @intCast(comptime_int, c);
    }
    return hash;
}

pub fn isComptime(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .ComptimeInt, .ComptimeFloat => true,
        else => false,
    };
}