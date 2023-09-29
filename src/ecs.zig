// ecs
pub const EntityTraitsType = @import("ecs/entity.zig").EntityTraitsType;

// TODO: remove me. this is just for testing
pub const ComponentStorage = @import("ecs/component_storage.zig").ComponentStorage;

pub const Entity = @import("ecs/registry.zig").Entity;
pub const Registry = @import("ecs/registry.zig").Registry;
pub const EntityHandles = @import("ecs/registry.zig").EntityHandles;
pub const BasicView = @import("ecs/views.zig").BasicView;
pub const MultiView = @import("ecs/views.zig").MultiView;
pub const BasicGroup = @import("ecs/groups.zig").BasicGroup;
pub const OwningGroup = @import("ecs/groups.zig").OwningGroup;
pub const SparseSet = @import("ecs/sparse_set.zig").SparseSet;
pub const utils = @import("ecs/utils.zig");

// signals
pub const Signal = @import("signals/signal.zig").Signal;
pub const Dispatcher = @import("signals/dispatcher.zig").Dispatcher;
