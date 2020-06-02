const std = @import("std");
const assert = std.debug.assert;
const utils = @import("utils.zig");

const Handles = @import("handles.zig").Handles;
const SparseSet = @import("sparse_set.zig").SparseSet;
const TypeMap = @import("type_map.zig").TypeMap;
const ComponentStorage = @import("component_storage.zig").ComponentStorage;

// allow overriding EntityTraits by setting in root via: EntityTraits = EntityTraitsType(.medium);
const root = @import("root");
const entity_traits = if (@hasDecl(root, "EntityTraits")) root.EntityTraits.init() else @import("entity.zig").EntityTraits.init();

// setup the Handles type based on the type set in EntityTraits
const EntityHandles = Handles(entity_traits.entity_type, entity_traits.index_type, entity_traits.version_type);
pub const Entity = entity_traits.entity_type;

pub const BasicView = @import("view.zig").BasicView;
pub const BasicMultiView = @import("view.zig").BasicMultiView;

/// Stores an ArrayList of components. The max amount that can be stored is based on the type below
pub fn Storage(comptime CompT: type) type {
    return ComponentStorage(CompT, Entity, u16); // 65,535 components
}

/// the registry is the main gateway to all ecs functionality. It assumes all internal allocations will succeed and returns
/// no errors to keep the API clean and because if a component array cant be allocated you've got bigger problems.
/// Stores a maximum of u8 (256) component Storage(T).
pub const Registry = struct {
    typemap: TypeMap,
    handles: EntityHandles,
    components: std.AutoHashMap(u8, usize),
    contexts: std.AutoHashMap(u8, usize),
    allocator: *std.mem.Allocator,

    pub fn init(allocator: *std.mem.Allocator) Registry {
        return Registry{
            .typemap = TypeMap.init(allocator),
            .handles = EntityHandles.init(allocator),
            .components = std.AutoHashMap(u8, usize).init(allocator),
            .contexts = std.AutoHashMap(u8, usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.components.iterator();
        while (it.next()) |ptr| {
            // HACK: we dont know the Type here but we need to call deinit
            var storage = @intToPtr(*Storage(u1), ptr.value);
            storage.deinit();
        }

        self.components.deinit();
        self.contexts.deinit();
        self.typemap.deinit();
        self.handles.deinit();
    }

    pub fn assure(self: *Registry, comptime T: type) *Storage(T) {
        var type_id: u8 = undefined;
        if (!self.typemap.getOrPut(T, &type_id)) {
            var comp_set = Storage(T).initPtr(self.allocator);
            var comp_set_ptr = @ptrToInt(comp_set);
            _ = self.components.put(type_id, comp_set_ptr) catch unreachable;
            return comp_set;
        }

        const ptr = self.components.getValue(type_id).?;
        return @intToPtr(*Storage(T), ptr);
    }

    /// Prepares a pool for the given type if required
    pub fn prepare(self: *Registry, comptime T: type) void {
        _ = self.assure(T);
    }

    /// Returns the number of existing components of the given type
    pub fn len(self: *Registry, comptime T: type) usize {
        self.assure(T).len();
    }

    /// Increases the capacity of the registry or of the pools for the given component
    pub fn reserve(self: *Self, comptime T: type, cap: usize) void {
        self.assure(T).reserve(cap);
    }

    /// Direct access to the list of components of a given pool
    pub fn raw(self: Registry, comptime T: type) []T {
        return self.assure(T).raw();
    }

    /// Direct access to the list of entities of a given pool
    pub fn data(self: Registry, comptime T: type) []Entity {
        return self.assure(T).data();
    }

    pub fn valid(self: *Registry, entity: Entity) bool {
        return self.handles.isAlive(entity);
    }

    /// Returns the entity identifier without the version
    pub fn entityId(self: Registry, entity: Entity) Entity {
        return entity & entity_traits.entity_mask;
    }

    /// Returns the version stored along with an entity identifier
    pub fn version(self: *Registry, entity: Entity) entity_traits.version_type {
        return @truncate(entity_traits.version_type, entity >> @bitSizeOf(entity_traits.index_type));
    }

    /// Creates a new entity and returns it
    pub fn create(self: *Registry) Entity {
        return self.handles.create();
    }

    /// Destroys an entity
    pub fn destroy(self: *Registry, entity: Entity) void {
        assert(self.valid(entity));
        self.removeAll(entity);
        self.handles.remove(entity) catch unreachable;
    }

    pub fn add(self: *Registry, entity: Entity, value: var) void {
        assert(self.valid(entity));
        self.assure(@TypeOf(value)).add(entity, value);
    }

    /// shortcut for adding raw comptime_int/float without having to @as cast
    pub fn addTyped(self: *Registry, comptime T: type, entity: Entity, value: T) void {
        self.add(entity, value);
    }

    /// Replaces the given component for an entity
    pub fn replace(self: *Registry, entity: Entity, value: var) void {
        assert(self.valid(entity));
        self.assure(@TypeOf(value)).replace(entity, value);
    }

    /// shortcut for replacing raw comptime_int/float without having to @as cast
    pub fn replaceTyped(self: *Registry, comptime T: type, entity: Entity, value: T) void {
        self.replace(entity, value);
    }

    pub fn addOrReplace(self: *Registry, entity: Entity, value: var) void {
        assert(self.valid(entity));

        const store = self.assure(@TypeOf(value));
        if (store.tryGet(entity)) |found| {
            found.* = value;
        } else {
            store.add(entity, value);
        }
    }

    /// shortcut for add-or-replace raw comptime_int/float without having to @as cast
    pub fn addOrReplaceTyped(self: *Registry, T: type, entity: Entity, value: T) void {
        self.addOrReplace(entity, value);
    }

    /// Removes the given component from an entity
    pub fn remove(self: *Registry, comptime T: type, entity: Entity) void {
        assert(self.valid(entity));
        self.assure(T).remove(entity);
    }

    pub fn removeIfExists(self: *Registry, comptime T: type, entity: Entity) void {
        assert(self.valid(entity));
        var store = self.assure(T);
        if (store.contains(entity))
            store.remove(entity);
    }

    /// Removes all the components from an entity and makes it orphaned
    pub fn removeAll(self: *Registry, entity: Entity) void {
        assert(self.valid(entity));

        var it = self.components.iterator();
        while (it.next()) |ptr| {
            // HACK: we dont know the Type here but we need to be able to call methods on the Storage(T)
            var store = @intToPtr(*Storage(u128), ptr.value);
            if (store.contains(entity)) store.remove(entity);
        }
    }

    pub fn has(self: *Registry, comptime T: type, entity: Entity) bool {
        assert(self.valid(entity));
        return self.assure(T).set.contains(entity);
    }

    pub fn get(self: *Registry, comptime T: type, entity: Entity) *T {
        assert(self.valid(entity));
        return self.assure(T).get(entity);
    }

    pub fn getConst(self: *Registry, comptime T: type, entity: Entity) T {
        assert(self.valid(entity));
        return self.assure(T).getConst(entity);
    }

    /// Returns a reference to the given component for an entity
    pub fn getOrAdd(self: *Registry, comptime T: type, entity: Entity) *T {
        if (self.has(T, entity)) return self.get(T, entity);
        self.add(T, entity, std.mem.zeros(T));
        return self.get(T, type);
    }

    pub fn tryGet(self: *Registry, comptime T: type, entity: Entity) ?*T {
        return self.assure(T).tryGet(entity);
    }

    /// Returns a Sink object for the given component to add/remove listeners with
    pub fn onConstruct(self: *Self, comptime T: type) Sink(Entity) {
        return self.assure(T).onConstruct();
    }

    /// Returns a Sink object for the given component to add/remove listeners with
    pub fn onUpdate(self: *Self, comptime T: type) Sink(Entity) {
        return self.assure(T).onUpdate();
    }

    /// Returns a Sink object for the given component to add/remove listeners with
    pub fn onDestruct(self: *Self, comptime T: type) Sink(Entity) {
        return self.assure(T).onDestruct();
    }

    /// Binds an object to the context of the registry
    pub fn setContext(self: *Registry, context: var) void {
        std.debug.assert(@typeInfo(@TypeOf(context)) == .Pointer);

        var type_id: u8 = undefined;
        _ = self.typemap.getOrPut(@typeInfo(@TypeOf(context)).Pointer.child, &type_id);
        _ = self.contexts.put(type_id, @ptrToInt(context)) catch unreachable;
    }

    /// Unsets a context variable if it exists
    pub fn unsetContext(self: *Registry, comptime T: type) void {
        std.debug.assert(@typeInfo(T) != .Pointer);

        var type_id: u8 = undefined;
        _ = self.typemap.getOrPut(T, &type_id);
        _ = self.contexts.put(type_id, 0) catch unreachable;
    }

    /// Returns a pointer to an object in the context of the registry
    pub fn getContext(self: *Registry, comptime T: type) ?*T {
        std.debug.assert(@typeInfo(T) != .Pointer);

        var type_id: u8 = undefined;
        _ = self.typemap.getOrPut(T, &type_id);
        return if (self.contexts.get(type_id)) |ptr|
            return if (ptr.value > 0) @intToPtr(*T, ptr.value) else null
        else
            null;
    }

    pub fn view(self: *Registry, comptime includes: var) ViewType(includes) {
        std.debug.assert(includes.len > 0);

        if (includes.len == 1)
            return BasicView(includes[0]).init(self.assure(includes[0]));

        var arr: [includes.len]u32 = undefined;
        inline for (includes) |t, i| {
            _ = self.assure(t);
            arr[i] = @as(u32, self.typemap.get(t));
        }

        return BasicMultiView(includes.len).init(arr, self);
    }

    fn ViewType(comptime includes: var) type {
        if (includes.len == 1) return BasicView(includes[0]);
        return BasicMultiView(includes.len);
    }
};

const Position = struct { x: f32, y: f32 };

test "context get/set/unset" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var ctx = reg.getContext(Position);
    std.testing.expectEqual(ctx, null);

    var pos = Position{ .x = 5, .y = 5 };
    reg.setContext(&pos);
    ctx = reg.getContext(Position);
    std.testing.expectEqual(ctx.?, &pos);

    reg.unsetContext(Position);
    ctx = reg.getContext(Position);
    std.testing.expectEqual(ctx, null);
}

// this test should fail
test "context not pointer" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var pos = Position{ .x = 5, .y = 5 };
    // reg.setContext(pos);
}

test "component context get/set/unset" {
    const SomeType = struct { dummy: u1 };

    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var ctx = reg.getContext(SomeType);
    std.testing.expectEqual(ctx, null);

    var pos = SomeType{ .dummy = 0 };
    reg.setContext(&pos);
    ctx = reg.getContext(SomeType);
    std.testing.expectEqual(ctx.?, &pos);

    reg.unsetContext(SomeType);
    ctx = reg.getContext(SomeType);
    std.testing.expectEqual(ctx, null);
}

test "destroy" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var i = @as(u8, 0);
    while (i < 255) : (i += 1) {
        const e = reg.create();
        reg.add(e, Position{ .x = @intToFloat(f32, i), .y = @intToFloat(f32, i) });
    }

    reg.destroy(3);
    reg.destroy(4);

    i = 0;
    while (i < 6) : (i += 1) {
        if (i != 3 and i != 4)
            std.testing.expectEqual(Position{ .x = @intToFloat(f32, i), .y = @intToFloat(f32, i)}, reg.getConst(Position, i));
    }
}

test "remove all" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    var e = reg.create();
    reg.add(e, Position{.x = 1, .y = 1});
    reg.addTyped(u32, e, 666);

    std.testing.expect(reg.has(Position, e));
    std.testing.expect(reg.has(u32, e));

    reg.removeAll(e);

    std.testing.expect(!reg.has(Position, e));
    std.testing.expect(!reg.has(u32, e));
}