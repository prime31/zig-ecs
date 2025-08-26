test "handles stress test" {
    const Entity = ecs.EntityClass(.{ .index_bits = 8, .version_bits = 4 });
    const Handles = ecs.Handles(Entity);

    var handles: Handles = .init(std.testing.allocator);

    var entity: Entity = undefined;
    // create 15 entities
    for (0..Handles.max_active_entities) |_| {
        entity = try handles.create();
        try handles.remove(entity);

        entity = try handles.create();
    }
    // last one cannot be created because the index would coincide with our tombstone/invalid slot
    try std.testing.expectError(error.OutOfActiveHandles, handles.create());
    handles.deinit();

    handles = .init(std.testing.allocator);
    var entities: std.ArrayListUnmanaged(Entity) = try .initCapacity(std.testing.allocator, Handles.max_active_entities);
    defer entities.deinit(std.testing.allocator);
    defer handles.deinit();

    var xoro: std.Random.Xoshiro256 = .init(78425829754);
    const rand = xoro.random();
    var tested_scenarios: [4]bool = @splat(false);
    const iters = 10_000;
    for (0..iters) |i| {
        // vary this to cover all cases
        const remove_probability: f32 = if (i < iters / 2)
            2 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(iters))
        else
            -2 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(iters)) + 2;

        // remove entity from list
        if (rand.float(f32) < remove_probability) {
            if (entities.items.len > 0) {
                // choose random entity to remove
                const to_remove: Entity = entities.swapRemove(rand.uintLessThan(usize, entities.items.len));
                try handles.remove(to_remove);
                tested_scenarios[0] = true;
            } else {
                // remove random id and expect failure
                try std.testing.expectError(error.RemovedInvalidHandle, handles.remove(.{ .index = rand.uintLessThan(u4, 15), .version = rand.int(u4) }));
                tested_scenarios[1] = true;
            }
        }
        // create entity
        else {
            if (entities.items.len < Handles.max_active_entities) {
                // create new entity
                entities.appendAssumeCapacity(try handles.create());
                tested_scenarios[2] = true;
            } else {
                // out of entities, create new entity and expect failure
                try std.testing.expectError(error.OutOfActiveHandles, handles.create());
                tested_scenarios[3] = true;
            }
        }
    }
    try std.testing.expectEqualSlices(
        bool,
        &@as([4]bool, @splat(true)),
        &tested_scenarios,
    );
}

const ecs = @import("ecs");
const std = @import("std");
