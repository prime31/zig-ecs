test "ecs test suite" {
    _ = @import("dispatcher_test.zig");
    _ = @import("registry_test.zig");
    _ = @import("groups_test.zig");
}
