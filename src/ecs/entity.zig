const std = @import("std");

/// default EntityTraitsDefinition with reasonable sizes suitable for most situations
pub const EntityTraits = EntityTraitsType(.medium);

pub const EntityTraitsSize = enum { small, medium, large };

pub fn EntityTraitsType(comptime size: EntityTraitsSize) type {
    return switch (size) {
        .small => EntityTraitsDefinition(u16, u12, u4),
        .medium => EntityTraitsDefinition(u32, u20, u12),
        .large => EntityTraitsDefinition(u64, u32, u32),
    };
}

fn EntityTraitsDefinition(comptime EntityType: type, comptime IndexType: type, comptime VersionType: type) type {
    std.debug.assert(std.meta.Int(.unsigned, @bitSizeOf(EntityType)) == EntityType);
    std.debug.assert(std.meta.Int(.unsigned, @bitSizeOf(IndexType)) == IndexType);
    std.debug.assert(std.meta.Int(.unsigned, @bitSizeOf(VersionType)) == VersionType);

    const sizeOfIndexType = @bitSizeOf(IndexType);
    const sizeOfVersionType = @bitSizeOf(VersionType);
    const entityShift = sizeOfIndexType;

    if (sizeOfIndexType + sizeOfVersionType != @bitSizeOf(EntityType))
        @compileError("IndexType and VersionType must sum to EntityType's bit count");

    const entityMask = std.math.maxInt(IndexType);
    const versionMask = std.math.maxInt(VersionType);

    return struct {
        entity_type: type = EntityType,
        index_type: type = IndexType,
        version_type: type = VersionType,
        /// Mask to use to get the entity index number out of an identifier
        entity_mask: EntityType = entityMask,
        /// Mask to use to get the version out of an identifier
        version_mask: EntityType = versionMask,
        /// Bit size of entity in entity_type
        entity_shift: EntityType = entityShift,

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
