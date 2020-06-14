// include all files with tests
comptime {
    // ecs
    _ = @import("ecs/actor.zig");
    _ = @import("ecs/component_storage.zig");
    _ = @import("ecs/entity.zig");
    _ = @import("ecs/handles.zig");
    _ = @import("ecs/sparse_set.zig");
    _ = @import("ecs/views.zig");
    _ = @import("ecs/groups.zig");
    _ = @import("ecs/type_store.zig");

    // signals
    _ = @import("signals/delegate.zig");
    _ = @import("signals/signal.zig");

    // resources
    _ = @import("resources/cache.zig");
    _ = @import("resources/assets.zig");

    // process
    _ = @import("process/scheduler.zig");
}
