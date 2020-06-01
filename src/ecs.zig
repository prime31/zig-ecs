// ecs
pub const EntityTraitsType = @import("ecs/entity.zig").EntityTraitsType;

pub const Entity = @import("ecs/registry.zig").Entity;
pub const Registry = @import("ecs/registry.zig").Registry;
pub const BasicView = @import("ecs/view.zig").BasicView;
pub const BasicMultiView = @import("ecs/view.zig").BasicMultiView;

// signals
pub const Signal = @import("signals/signal.zig").Signal;
pub const Dispatcher = @import("signals/dispatcher.zig").Dispatcher;