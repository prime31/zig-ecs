# Zig ECS
Zig ECS is a zig port of the fantasic [Entt](https://github.com/skypjack/entt). Entt is _highly_ templated C++ code which depending on your opinion is either a good thing or satan itself in code form. Zig doesn't have the same concept as C++ templates (thank goodness!) so the templated code was changed over to use Zig's generics and compile time metaprogramming.

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

The same example using an owning Group:
```zig
var group = reg.group(.{ Velocity, Position }, .{}, .{});
group.each(each);

fn each(e: struct { vel: *Velocity, pos: *Position }) void {
    e.pos.*.x += e.vel.x;
    e.pos.*.y += e.vel.y;
}
```
