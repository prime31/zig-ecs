const std = @import("std");

/// default Entity with reasonable sizes suitable for most situations
pub const DefaultEntity = EntityClass(.medium);

pub const EntityParameters = struct {
    index_bits: usize,
    version_bits: usize,
    pub const small: @This() = .{ .index_bits = 12, .version_bits = 4 };
    pub const medium: @This() = .{ .index_bits = 20, .version_bits = 12 };
    pub const large: @This() = .{ .index_bits = 32, .version_bits = 32 };
};

pub fn EntityClass(comptime entity_parameters: EntityParameters) type {
    const total_bits = entity_parameters.index_bits + entity_parameters.version_bits;
    const EntityBackingInt = std.meta.Int(.unsigned, total_bits);

    return packed struct(EntityBackingInt) {
        pub const Index = std.meta.Int(.unsigned, entity_parameters.index_bits);
        pub const Version = std.meta.Int(.unsigned, entity_parameters.version_bits);

        index: Index,
        version: Version,
    };
}

test EntityClass {
    const Small = EntityClass(.small);
    const Medium = EntityClass(.medium);
    const Large = EntityClass(.large);

    try std.testing.expectEqual(Small.Index, u12);
    try std.testing.expectEqual(Medium.Index, u20);
    try std.testing.expectEqual(Large.Index, u32);
}
