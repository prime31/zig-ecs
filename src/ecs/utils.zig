const std = @import("std");

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
    return hashString(@typeName(T));
}

pub fn hashString(comptime str: []const u8) u32 {
    return @truncate(u32, std.hash.Wyhash.hash(0, str));
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