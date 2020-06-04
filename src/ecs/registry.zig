const std = @import("std");
const assert = std.debug.assert;
const utils = @import("utils.zig");

const Handles = @import("handles.zig").Handles;
const SparseSet = @import("sparse_set.zig").SparseSet;
const TypeMap = @import("type_map.zig").TypeMap;
const ComponentStorage = @import("component_storage.zig").ComponentStorage;
const Sink = @import("../signals/sink.zig").Sink;

// allow overriding EntityTraits by setting in root via: EntityTraits = EntityTraitsType(.medium);
const root = @import("root");
const entity_traits = if (@hasDecl(root, "EntityTraits")) root.EntityTraits.init() else @import("entity.zig").EntityTraits.init();

// setup the Handles type based on the type set in EntityTraits
const EntityHandles = Handles(entity_traits.entity_type, entity_traits.index_type, entity_traits.version_type);
pub const Entity = entity_traits.entity_type;

pub const BasicView = @import("views.zig").BasicView;
pub const MultiView = @import("views.zig").MultiView;
pub const BasicGroup = @import("groups.zig").BasicGroup;

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
    groups: std.ArrayList(*GroupData),
    allocator: *std.mem.Allocator,

    /// internal, persistant data structure to manage the entities in a group
    const GroupData = struct {
        hash: u32,
        entity_set: SparseSet(Entity, u16), // TODO: dont hardcode this. put it in EntityTraits maybe. All SparseSets would need to use the value.
        owned: []u32,
        include: []u32,
        exclude: []u32,
        registry: *Registry,

        pub fn initPtr(allocator: *std.mem.Allocator, registry: *Registry, hash: u32, owned: []u32, include: []u32, exclude: []u32) *GroupData {
            std.debug.assert(std.mem.indexOfAny(u32, owned, include) == null);
            std.debug.assert(std.mem.indexOfAny(u32, owned, exclude) == null);
            std.debug.assert(std.mem.indexOfAny(u32, include, exclude) == null);

            var group_data = allocator.create(GroupData) catch unreachable;
            group_data.hash = hash;
            group_data.entity_set = SparseSet(Entity, u16).init(allocator);
            group_data.owned = std.mem.dupe(allocator, u32, owned) catch unreachable;
            group_data.include = std.mem.dupe(allocator, u32, include) catch unreachable;
            group_data.exclude = std.mem.dupe(allocator, u32, exclude) catch unreachable;
            group_data.registry = registry;

            return group_data;
        }

        pub fn deinit(self: *GroupData, allocator: *std.mem.Allocator) void {
            self.entity_set.deinit();
            allocator.free(self.owned);
            allocator.free(self.include);
            allocator.free(self.exclude);
            allocator.destroy(self);
        }

        fn maybeValidIf(self: *GroupData, entity: Entity) void {
            const isValid: bool = blk: {
                for (self.owned) |tid| {
                    const ptr = self.registry.components.getValue(@intCast(u8, tid)).?;
                    if (!@intToPtr(*Storage(u1), ptr).contains(entity))
                        break :blk false;
                }

                for (self.include) |tid| {
                    const ptr = self.registry.components.getValue(@intCast(u8, tid)).?;
                    if (!@intToPtr(*Storage(u1), ptr).contains(entity))
                        break :blk false;
                }

                for (self.exclude) |tid| {
                    const ptr = self.registry.components.getValue(@intCast(u8, tid)).?;
                    if (@intToPtr(*Storage(u1), ptr).contains(entity))
                        break :blk false;
                }
                break :blk true;
            };

            if (self.owned.len == 0) {
                if (isValid and !self.entity_set.contains(entity))
                    self.entity_set.add(entity);
            } else {
                std.debug.assert(self.owned.len >= 0);
            }
        }

        fn discardIf(self: *GroupData, entity: Entity) void {
            if (self.owned.len == 0) {
                if (self.entity_set.contains(entity))
                    self.entity_set.remove(entity);
            } else {
                std.debug.assert(self.owned.len == 0);
            }
        }
    };

    pub fn init(allocator: *std.mem.Allocator) Registry {
        return Registry{
            .typemap = TypeMap.init(allocator),
            .handles = EntityHandles.init(allocator),
            .components = std.AutoHashMap(u8, usize).init(allocator),
            .contexts = std.AutoHashMap(u8, usize).init(allocator),
            .groups = std.ArrayList(*GroupData).init(allocator),
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

        for (self.groups.items) |grp| {
            grp.deinit(self.allocator);
        }

        self.components.deinit();
        self.contexts.deinit();
        self.groups.deinit();
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
    pub fn onConstruct(self: *Registry, comptime T: type) Sink(Entity) {
        return self.assure(T).onConstruct();
    }

    /// Returns a Sink object for the given component to add/remove listeners with
    pub fn onUpdate(self: *Registry, comptime T: type) Sink(Entity) {
        return self.assure(T).onUpdate();
    }

    /// Returns a Sink object for the given component to add/remove listeners with
    pub fn onDestruct(self: *Registry, comptime T: type) Sink(Entity) {
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

    pub fn view(self: *Registry, comptime includes: var, comptime excludes: var) ViewType(includes, excludes) {
        if (@typeInfo(@TypeOf(includes)) != .Struct)
            @compileError("Expected tuple or struct argument, found " ++ @typeName(@TypeOf(args)));
        if (@typeInfo(@TypeOf(excludes)) != .Struct)
            @compileError("Expected tuple or struct argument, found " ++ @typeName(@TypeOf(excludes)));
        std.debug.assert(includes.len > 0);

        if (includes.len == 1 and excludes.len == 0)
            return BasicView(includes[0]).init(self.assure(includes[0]));

        var includes_arr: [includes.len]u32 = undefined;
        inline for (includes) |t, i| {
            _ = self.assure(t);
            includes_arr[i] = @as(u32, self.typemap.get(t));
        }

        var excludes_arr: [excludes.len]u32 = undefined;
        inline for (excludes) |t, i| {
            _ = self.assure(t);
            excludes_arr[i] = @as(u32, self.typemap.get(t));
        }

        return MultiView(includes.len, excludes.len).init(self, includes_arr, excludes_arr);
    }

    /// returns the Type that a view will be based on the includes and excludes
    fn ViewType(comptime includes: var, comptime excludes: var) type {
        if (includes.len == 1 and excludes.len == 0) return BasicView(includes[0]);
        return MultiView(includes.len, excludes.len);
    }

    pub fn group(self: *Registry, comptime owned: var, comptime includes: var, comptime excludes: var) GroupType(owned, includes, excludes) {
        if (@typeInfo(@TypeOf(owned)) != .Struct)
            @compileError("Expected tuple or struct argument, found " ++ @typeName(@TypeOf(owned)));
        if (@typeInfo(@TypeOf(includes)) != .Struct)
            @compileError("Expected tuple or struct argument, found " ++ @typeName(@TypeOf(includes)));
        if (@typeInfo(@TypeOf(excludes)) != .Struct)
            @compileError("Expected tuple or struct argument, found " ++ @typeName(@TypeOf(excludes)));
        std.debug.assert(owned.len + includes.len > 0);
        std.debug.assert(owned.len + includes.len + excludes.len > 1);

        var owned_arr: [owned.len]u32 = undefined;
        inline for (owned) |t, i| {
            _ = self.assure(t);
            owned_arr[i] = @as(u32, self.typemap.get(t));
        }

        var includes_arr: [includes.len]u32 = undefined;
        inline for (includes) |t, i| {
            _ = self.assure(t);
            includes_arr[i] = @as(u32, self.typemap.get(t));
        }

        var excludes_arr: [excludes.len]u32 = undefined;
        inline for (excludes) |t, i| {
            _ = self.assure(t);
            excludes_arr[i] = @as(u32, self.typemap.get(t));
        }

        // create a unique hash to identify the group
        var maybe_group_data: ?*GroupData = null;
        comptime const hash = owned.len + (31 * includes.len) + (31 * 31 * excludes.len);

        for (self.groups.items) |grp| {
            if (grp.hash == hash and std.mem.eql(u32, grp.owned, owned_arr[0..]) and std.mem.eql(u32, grp.include, includes_arr[0..]) and std.mem.eql(u32, grp.exclude, excludes_arr[0..])) {
                maybe_group_data = grp;
                break;
            }
        }

        // do we already have the GroupData?
        if (maybe_group_data) |group_data| {
            // non-owning groups
            if (owned.len == 0) {
                return BasicGroup(includes.len, excludes.len).init(&group_data.entity_set, self, includes_arr, excludes_arr);
            } else {
                @compileLog("owned groups not implemented");
            }
        }

        // we need to create a new GroupData
        var new_group_data = GroupData.initPtr(self.allocator, self, hash, &[_]u32{}, includes_arr[0..], excludes_arr[0..]);
        self.groups.append(new_group_data) catch unreachable;

        // wire up our listeners
        inline for (owned) |t| self.onConstruct(t).connectBound(new_group_data, "maybeValidIf");
        inline for (includes) |t| self.onConstruct(t).connectBound(new_group_data, "maybeValidIf");
        inline for (excludes) |t| self.onDestruct(t).connectBound(new_group_data, "maybeValidIf");

        inline for (owned) |t| self.onDestruct(t).connectBound(new_group_data, "discardIf");
        inline for (includes) |t| self.onDestruct(t).connectBound(new_group_data, "discardIf");
        inline for (excludes) |t| self.onConstruct(t).connectBound(new_group_data, "discardIf");

        // pre-fill the GroupData with any existing entitites that match
        if (owned.len == 0) {
            var tmp_view = self.view(owned ++ includes, excludes);
            var view_iter = tmp_view.iterator();
            while (view_iter.next()) |entity| {
                new_group_data.entity_set.add(entity);
            }
        } else {
            unreachable;
        }

        return BasicGroup(includes.len, excludes.len).init(&new_group_data.entity_set, self, includes_arr, excludes_arr);
    }

    /// returns the Type that a view will be based on the includes and excludes
    fn GroupType(comptime owned: var, comptime includes: var, comptime excludes: var) type {
        if (owned.len == 0) return BasicGroup(includes.len, excludes.len);
        unreachable;
    }
};
