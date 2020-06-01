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
    std.debug.assert(@typeInfo(EntityType) == .Int and !EntityType.is_signed);
    std.debug.assert(@typeInfo(IndexType) == .Int and !IndexType.is_signed);
    std.debug.assert(@typeInfo(VersionType) == .Int and !VersionType.is_signed);

    if (@bitSizeOf(IndexType) + @bitSizeOf(VersionType) != @bitSizeOf(EntityType))
        @compileError("IndexType and VersionType must sum to EntityType's bit count");

    return struct {
        entity_type: type = EntityType,
        index_type: type = IndexType,
        version_type: type = VersionType,
        /// Mask to use to get the entity index number out of an identifier
        entity_mask: EntityType = std.math.maxInt(IndexType),
        /// Mask to use to get the version out of an identifier
        version_mask: EntityType = std.math.maxInt(VersionType),

        pub fn init() @This() {
            return @This(){};
        }
    };
}

test "entity traits" {
    const sm = EntityTraitsType(.small).init();
    const m = EntityTraitsType(.medium).init();
    const l = EntityTraitsType(.large).init();

    std.testing.expectEqual(sm.entity_mask, std.math.maxInt(sm.index_type));
    std.testing.expectEqual(m.entity_mask, std.math.maxInt(m.index_type));
    std.testing.expectEqual(l.entity_mask, std.math.maxInt(l.index_type));
}
