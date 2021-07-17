const std = @import("std");

/// default EntityTraitsDefinition with reasonable sizes suitable for most situations
pub const EntityTraits = EntityTraitsType(.medium);

pub const EntityTraitsSize = enum { small, medium, large };

pub fn EntityTraitsType(comptime size: EntityTraitsSize) type {
    return switch (size) {
        .small => EntityTraitsDefinition(u16, u12, u4, 0xFFFF, 0xFFF, 10),
        .medium => EntityTraitsDefinition(u32, u20, u12, 0xFFFFF, 0xFFF, 20),
        .large => EntityTraitsDefinition(u64, u32, u32, 0xFFFFFFFF, 0xFFFFFFFF, 32),
    };
}

fn EntityTraitsDefinition(comptime EntityType: type, comptime IndexType: type, comptime VersionType: type, comptime EntityMask: EntityType, comptime VersionMask: EntityType, comptime EntityShift: EntityType) type {
    std.debug.assert(@typeInfo(EntityType) == .Int and std.meta.Int(.unsigned, @bitSizeOf(EntityType)) == EntityType);
    std.debug.assert(@typeInfo(IndexType) == .Int and std.meta.Int(.unsigned, @bitSizeOf(IndexType)) == IndexType);
    std.debug.assert(@typeInfo(VersionType) == .Int and std.meta.Int(.unsigned, @bitSizeOf(VersionType)) == VersionType);

    if (@bitSizeOf(IndexType) + @bitSizeOf(VersionType) != @bitSizeOf(EntityType))
        @compileError("IndexType and VersionType must sum to EntityType's bit count");

    return struct {
        entity_type: type = EntityType,
        index_type: type = IndexType,
        version_type: type = VersionType,
        /// Mask to use to get the entity index number out of an identifier
        entity_mask: EntityType = EntityMask,
        /// Mask to use to get the version out of an identifier
        version_mask: EntityType = VersionMask,
        entity_shift: EntityType = EntityShift,

        pub fn init() @This() {
            return @This(){};
        }
    };
}

test "entity traits" {
    const sm = EntityTraitsType(.small).init();
    const m = EntityTraitsType(.medium).init();
    const l = EntityTraitsType(.large).init();

    try std.testing.expectEqual(sm.entity_mask, std.math.maxInt(sm.index_type));
    try std.testing.expectEqual(m.entity_mask, std.math.maxInt(m.index_type));
    try std.testing.expectEqual(l.entity_mask, std.math.maxInt(l.index_type));
}
