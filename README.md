# Zig ECS
Zig ECS is a zig port of the fantasic [Entt](https://github.com/skypjack/entt). Entt is _highly_ templated C++ code which depending on your opinion is either a good thing or satan itself in code form. Zig doesn't have the same concept as C++ templates so the templated code was changed over to use Zig's generics and compile time metaprogramming.

## What does a zigified Entt look like?
Below are examples of a View and a Group, the two main ways to work with entities in the ecs along with the scaffolding code.

Declare some structs to work with:
```zig
pub const Velocity = struct { x: f32, y: f32 };
pub const Position = struct { x: f32, y: f32 };
```

Setup the Registry, which holds the entity data and is where we run our queries:
```zig
var reg = ecs.Registry.init(std.testing.allocator);
```

Create a couple entities and add some components to them
```zig
const entity = reg.create();
reg.add(entity, Position{ .x = 0, .y = 0 });
reg.add(entity, Velocity{ .x = 5, .y = 7 });
...
```

Create and iterate a View that matches all entities with a `Velocity` and `Position` component:
```zig
var view = reg.view(.{ Velocity, Position }, .{});

var iter = view.entityIterator();
while (iter.next()) |entity| {
    const pos = view.getConst(Position, entity); // readonly copy
    var vel = view.get(Velocity, entity); // mutable
}
```

The same example using an owning Group and iterating with `each`:
```zig
var group = reg.group(.{ Velocity, Position }, .{}, .{});
group.each(each);

fn each(e: struct { vel: *Velocity, pos: *Position }) void {
    e.pos.*.x += e.vel.x;
    e.pos.*.y += e.vel.y;
}
```

## Component Storage Overview
- **View**: stores no data in the ECS. Iterates on the fly with no cache to speed up iteration. Start with a `View` for most things and you can always upgrade to a `Group`/`OwningGroup` if you need more speed.
- **Group**: stores and maintains an accurate list of all the entities matching the query. This query cache speeds up iteration since it already knows exactly which entities match the query. The downside is that it requires memory and cpu cycles to keep the cache up-to-date.
- **OwningGroup**: for any components in an `OwningGroup` the actual component storage containers are constantly reordered as entities are added/removed from the `Registry`. This allows direct iteration with no gaps of the component data. An `OwningGroup` does not require much extra memory but it is more cpu intensive if there is a lot of component churn (adding/removing of the owned components).
