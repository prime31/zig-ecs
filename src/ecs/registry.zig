const std = @import("std");
const assert = std.debug.assert;
const utils = @import("utils.zig");

const Handles = @import("handles.zig").Handles;
const SparseSet = @import("sparse_set.zig").SparseSet;
const ComponentStorage = @import("component_storage.zig").ComponentStorage;
const Sink = @import("../signals/sink.zig").Sink;
const TypeStore = @import("type_store.zig").TypeStore;

// allow overriding EntityTraits by setting in root via: EntityTraits = EntityTraitsType(.medium);
const root = @import("root");
const entity_traits = if (@hasDecl(root, "EntityTraits")) root.EntityTraits.init() else @import("entity.zig").EntityTraits.init();

// setup the Handles type based on the type set in EntityTraits
const EntityHandles = Handles(entity_traits.entity_type, entity_traits.index_type, entity_traits.version_type);
pub const Entity = entity_traits.entity_type;

const BasicView = @import("views.zig").BasicView;
const MultiView = @import("views.zig").MultiView;
const BasicGroup = @import("groups.zig").BasicGroup;
const OwningGroup = @import("groups.zig").OwningGroup;

/// Stores an ArrayList of components. The max amount that can be stored is based on the type below
pub fn Storage(comptime CompT: type) type {
    return ComponentStorage(CompT, Entity);
}

/// the registry is the main gateway to all ecs functionality. It assumes all internal allocations will succeed and returns
/// no errors to keep the API clean and because if a component array cant be allocated you've got bigger problems.
pub const Registry = struct {
    handles: EntityHandles,
    components: std.AutoHashMap(u32, usize),
    contexts: std.AutoHashMap(u32, usize),
    groups: std.ArrayList(*GroupData),
    singletons: TypeStore,
    allocator: *std.mem.Allocator,

    /// internal, persistant data structure to manage the entities in a group
    const GroupData = struct {
        hash: u64,
        size: u8,
        /// optional. there will be an entity_set for non-owning groups and current for owning
        entity_set: SparseSet(Entity) = undefined,
        owned: []u32,
        include: []u32,
        exclude: []u32,
        registry: *Registry,
        current: usize,

        pub fn initPtr(allocator: *std.mem.Allocator, registry: *Registry, hash: u64, owned: []u32, include: []u32, exclude: []u32) *GroupData {
            // std.debug.assert(std.mem.indexOfAny(u32, owned, include) == null);
            // std.debug.assert(std.mem.indexOfAny(u32, owned, exclude) == null);
            // std.debug.assert(std.mem.indexOfAny(u32, include, exclude) == null);
            var group_data = allocator.create(GroupData) catch unreachable;
            group_data.hash = hash;
            group_data.size = @intCast(u8, owned.len + include.len + exclude.len);
            if (owned.len == 0) {
                group_data.entity_set = SparseSet(Entity).init(allocator);
            }
            group_data.owned = std.mem.dupe(allocator, u32, owned) catch unreachable;
            group_data.include = std.mem.dupe(allocator, u32, include) catch unreachable;
            group_data.exclude = std.mem.dupe(allocator, u32, exclude) catch unreachable;
            group_data.registry = registry;
            group_data.current = 0;

            return group_data;
        }

        pub fn deinit(self: *GroupData, allocator: *std.mem.Allocator) void {
            // only deinit th SparseSet for non-owning groups
            if (self.owned.len == 0) {
                self.entity_set.deinit();
            }
            allocator.free(self.owned);
            allocator.free(self.include);
            allocator.free(self.exclude);
            allocator.destroy(self);
        }

        fn maybeValidIf(self: *GroupData, entity: Entity) void {
            const isValid: bool = blk: {
                for (self.owned) |tid| {
                    const ptr = self.registry.components.getValue(tid).?;
                    if (!@intToPtr(*Storage(u1), ptr).contains(entity))
                        break :blk false;
                }

                for (self.include) |tid| {
                    const ptr = self.registry.components.getValue(tid).?;
                    if (!@intToPtr(*Storage(u1), ptr).contains(entity))
                        break :blk false;
                }

                for (self.exclude) |tid| {
                    const ptr = self.registry.components.getValue(tid).?;
                    if (@intToPtr(*Storage(u1), ptr).contains(entity))
                        break :blk false;
                }
                break :blk true;
            };

            if (self.owned.len == 0) {
                if (isValid and !self.entity_set.contains(entity))
                    self.entity_set.add(entity);
            } else {
                if (isValid) {
                    const ptr = self.registry.components.getValue(self.owned[0]).?;
                    if (!(@intToPtr(*Storage(u1), ptr).set.index(entity) < self.current)) {
                        for (self.owned) |tid| {
                            // store.swap hides a safe version that types it correctly
                            const store_ptr = self.registry.components.getValue(tid).?;
                            var store = @intToPtr(*Storage(u1), store_ptr);
                            store.swap(store.data().*[self.current], entity);
                        }
                        self.current += 1;
                    }
                }
                std.debug.assert(self.owned.len >= 0);
            }
        }

        fn discardIf(self: *GroupData, entity: Entity) void {
            if (self.owned.len == 0) {
                if (self.entity_set.contains(entity))
                    self.entity_set.remove(entity);
            } else {
                const ptr = self.registry.components.getValue(self.owned[0]).?;
                var store = @intToPtr(*Storage(u1), ptr);
                if (store.contains(entity) and store.set.index(entity) < self.current) {
                    self.current -= 1;
                    for (self.owned) |tid| {
                        const store_ptr = self.registry.components.getValue(tid).?;
                        store = @intToPtr(*Storage(u1), store_ptr);
                        store.swap(store.data().*[self.current], entity);
                    }
                }
            }
        }

        /// finds the insertion point for this group by finding anything in the group family (overlapping owned)
        /// and finds the least specialized (based on size). This allows the least specialized to update first
        /// which ensures more specialized (ie less matches) will always be swapping inside the bounds of
        /// the less specialized groups.
        fn findInsertionIndex(self: GroupData, groups: []*GroupData) ?usize {
            for (groups) |grp, i| {
                var overlapping: u8 = 0;
                for (grp.owned) |grp_owned| {
                    if (std.mem.indexOfScalar(u32, self.owned, grp_owned)) |_| overlapping += 1;
                }

                if (overlapping > 0 and self.size <= grp.size) return i;
            }

            return null;
        }

        // TODO: is this the right logic? Should this return just the previous item in the family or be more specific about
        // the group size for the index it returns?
        /// for discards, the most specialized group in the family needs to do its discard and swap first. This will ensure
        /// as each more specialized group does their discards the entity will always remain outside of the "current" index
        /// for all groups in the family.
        fn findPreviousIndex(self: GroupData, groups: []*GroupData, index: ?usize) ?usize {
            if (groups.len == 0) return null;

            // we iterate backwards and either index or groups.len is one tick passed where we want to start
            var i = if (index) |ind| ind else groups.len;
            if (i > 0) i -= 1;

            while (i >= 0) : (i -= 1) {
                var overlapping: u8 = 0;
                for (groups[i].owned) |grp_owned| {
                    if (std.mem.indexOfScalar(u32, self.owned, grp_owned)) |_| overlapping += 1;
                }

                if (overlapping > 0) return i;
            }

            return null;
        }
    };

    pub fn init(allocator: *std.mem.Allocator) Registry {
        return Registry{
            .handles = EntityHandles.init(allocator),
            .components = std.AutoHashMap(u32, usize).init(allocator),
            .contexts = std.AutoHashMap(u32, usize).init(allocator),
            .groups = std.ArrayList(*GroupData).init(allocator),
            .singletons = TypeStore.init(allocator),
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
        self.singletons.deinit();
        self.handles.deinit();
    }

    pub fn assure(self: *Registry, comptime T: type) *Storage(T) {
        var type_id = utils.typeId(T);
        if (self.components.get(type_id)) |kv| {
            return @intToPtr(*Storage(T), kv.value);
        }

        var comp_set = Storage(T).initPtr(self.allocator);
        var comp_set_ptr = @ptrToInt(comp_set);
        _ = self.components.put(type_id, comp_set_ptr) catch unreachable;
        return comp_set;
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
        return self.assure(T).data().*;
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

    /// adds all the component types passed in as zero-initialized values
    pub fn addTypes(self: *Registry, entity: Entity, comptime types: var) void {
        inline for (types) |t| {
            self.assure(t).add(entity, std.mem.zeroes(t));
        }
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

    /// Returns a reference to the given component for an entity creating it if necessary
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

        var type_id = utils.typeId(@typeInfo(@TypeOf(context)).Pointer.child);
        _ = self.contexts.put(type_id, @ptrToInt(context)) catch unreachable;
    }

    /// Unsets a context variable if it exists
    pub fn unsetContext(self: *Registry, comptime T: type) void {
        std.debug.assert(@typeInfo(T) != .Pointer);
        _ = self.contexts.put(utils.typeId(T), 0) catch unreachable;
    }

    /// Returns a pointer to an object in the context of the registry
    pub fn getContext(self: *Registry, comptime T: type) ?*T {
        std.debug.assert(@typeInfo(T) != .Pointer);

        return if (self.contexts.get(utils.typeId(T))) |ptr|
            return if (ptr.value > 0) @intToPtr(*T, ptr.value) else null
        else
            null;
    }

    /// provides access to a TypeStore letting you add singleton components to the registry
    pub fn singletons(self: Registry) TypeStore {
        return self.singletons;
    }

    pub fn sort(self: *Registry, comptime T: type) void {
        const comp = self.assure(T);
        std.debug.assert(comp.super == 0);
        unreachable;
    }

    /// Checks whether the given component belongs to any group. If so, it is not sortable directly.
    pub fn sortable(self: *Registry, comptime T: type) bool {
        return self.assure(T).super == 0;
    }

    pub fn view(self: *Registry, comptime includes: var, comptime excludes: var) ViewType(includes, excludes) {
        std.debug.assert(@typeInfo(@TypeOf(includes)) == .Struct);
        std.debug.assert(@typeInfo(@TypeOf(excludes)) == .Struct);
        std.debug.assert(includes.len > 0);

        // just one include so use the optimized BasicView
        if (includes.len == 1 and excludes.len == 0)
            return BasicView(includes[0]).init(self.assure(includes[0]));

        var includes_arr: [includes.len]u32 = undefined;
        inline for (includes) |t, i| {
            _ = self.assure(t);
            includes_arr[i] = utils.typeId(t);
        }

        var excludes_arr: [excludes.len]u32 = undefined;
        inline for (excludes) |t, i| {
            _ = self.assure(t);
            excludes_arr[i] = utils.typeId(t);
        }

        return MultiView(includes.len, excludes.len).init(self, includes_arr, excludes_arr);
    }

    /// returns the Type that a view will be based on the includes and excludes
    fn ViewType(comptime includes: var, comptime excludes: var) type {
        if (includes.len == 1 and excludes.len == 0) return BasicView(includes[0]);
        return MultiView(includes.len, excludes.len);
    }

    /// creates an optimized group for iterating components. Note that types are ORDER DEPENDENDANT for now, so always pass component
    /// types in the same order.
    pub fn group(self: *Registry, comptime owned: var, comptime includes: var, comptime excludes: var) GroupType(owned, includes, excludes) {
        std.debug.assert(@typeInfo(@TypeOf(owned)) == .Struct);
        std.debug.assert(@typeInfo(@TypeOf(includes)) == .Struct);
        std.debug.assert(@typeInfo(@TypeOf(excludes)) == .Struct);
        std.debug.assert(owned.len + includes.len > 0);
        std.debug.assert(owned.len + includes.len + excludes.len > 1);

        var owned_arr: [owned.len]u32 = undefined;
        inline for (owned) |t, i| {
            _ = self.assure(t);
            owned_arr[i] = utils.typeId(t);
        }

        var includes_arr: [includes.len]u32 = undefined;
        inline for (includes) |t, i| {
            _ = self.assure(t);
            includes_arr[i] = utils.typeId(t);
        }

        var excludes_arr: [excludes.len]u32 = undefined;
        inline for (excludes) |t, i| {
            _ = self.assure(t);
            excludes_arr[i] = utils.typeId(t);
        }

        // create a unique hash to identify the group
        var maybe_group_data: ?*GroupData = null;
        comptime const hash = comptime hashGroupTypes(owned, includes, excludes);

        for (self.groups.items) |grp| {
            // TODO: these checks rely on owned/include/exclude to all be in the same order. fix that.
            // TODO: prolly dont need the mem.eql since hash is the same damn thing
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
                var first_owned = self.assure(owned[0]);
                return OwningGroup(owned.len, includes.len, excludes.len).init(&first_owned.super, &group_data.current, self, owned_arr, includes_arr, excludes_arr);
            }
        }

        const size = owned.len + includes.len + excludes.len;

        // before adding the group we need to do some checks to make sure there arent other owning groups with the same types
        if (std.builtin.mode == .Debug and owned.len > 0) {
            std.debug.warn("\n", .{});
            for (self.groups.items) |grp| {
                if (grp.owned.len == 0) continue;

                var overlapping: u8 = 0;
                for (grp.owned) |grp_owned| {
                    if (std.mem.indexOfScalar(u32, &owned_arr, grp_owned)) |_| overlapping += 1;
                }

                var sz: u8 = overlapping;
                for (grp.include) |grp_include| {
                    if (std.mem.indexOfScalar(u32, &includes_arr, grp_include)) |_| sz += 1;
                }
                for (grp.exclude) |grp_exclude| {
                    if (std.mem.indexOfScalar(u32, &excludes_arr, grp_exclude)) |_| sz += 1;
                }

                const check = overlapping == 0 or ((sz == size) or (sz == grp.size));
                std.debug.assert(check);
            }
        }

        // we need to create a new GroupData
        var new_group_data = GroupData.initPtr(self.allocator, self, hash, owned_arr[0..], includes_arr[0..], excludes_arr[0..]);

        var maybe_valid_if: ?*GroupData = null;
        var discard_if: ?*GroupData = null;

        if (owned.len == 0) {
            self.groups.append(new_group_data) catch unreachable;
        } else {
            // if this is a group in a family, we may need to do an insert so get the insertion index first
            const maybe_index = new_group_data.findInsertionIndex(self.groups.items);

            // if there is a previous group in this family, we use it for inserting our discardIf calls
            if (new_group_data.findPreviousIndex(self.groups.items, maybe_index)) |prev| {
                discard_if = self.groups.items[prev];
            }

            if (maybe_index) |index| {
                maybe_valid_if = self.groups.items[index];
                self.groups.insert(index, new_group_data) catch unreachable;
            } else {
                self.groups.append(new_group_data) catch unreachable;
            }

            // update super on all owned Storages to be the max of size and their current super value
            inline for (owned) |t| {
                var storage = self.assure(t);
                storage.super = std.math.max(storage.super, size);
            }
        }

        // wire up our listeners
        inline for (owned) |t| self.onConstruct(t).beforeBound(maybe_valid_if).connectBound(new_group_data, "maybeValidIf");
        inline for (includes) |t| self.onConstruct(t).beforeBound(maybe_valid_if).connectBound(new_group_data, "maybeValidIf");
        inline for (excludes) |t| self.onDestruct(t).beforeBound(maybe_valid_if).connectBound(new_group_data, "maybeValidIf");

        inline for (owned) |t| self.onDestruct(t).beforeBound(discard_if).connectBound(new_group_data, "discardIf");
        inline for (includes) |t| self.onDestruct(t).beforeBound(discard_if).connectBound(new_group_data, "discardIf");
        inline for (excludes) |t| self.onConstruct(t).beforeBound(discard_if).connectBound(new_group_data, "discardIf");

        // pre-fill the GroupData with any existing entitites that match
        if (owned.len == 0) {
            var view_iter = self.view(owned ++ includes, excludes).iterator();
            while (view_iter.next()) |entity| {
                new_group_data.entity_set.add(entity);
            }
        } else {
            // ??we cannot iterate backwards because we want to leave behind valid entities in case of owned types
            var first_owned_storage = self.assure(owned[0]);
            for (first_owned_storage.data().*) |entity| {
                new_group_data.maybeValidIf(entity);
            }
            // for(auto *first = std::get<0>(cpools).data(), *last = first + std::get<0>(cpools).size(); first != last; ++first) {
            //     handler->template maybe_valid_if<std::tuple_element_t<0, std::tuple<std::decay_t<Owned>...>>>(*this, *first);
            // }
        }

        if (owned.len == 0) {
            return BasicGroup(includes.len, excludes.len).init(&new_group_data.entity_set, self, includes_arr, excludes_arr);
        } else {
            var first_owned_storage = self.assure(owned[0]);
            return OwningGroup(owned.len, includes.len, excludes.len).init(&first_owned_storage.super, &new_group_data.current, self, owned_arr, includes_arr, excludes_arr);
        }
    }

    /// returns the Type that a view will be based on the includes and excludes
    fn GroupType(comptime owned: var, comptime includes: var, comptime excludes: var) type {
        if (owned.len == 0) return BasicGroup(includes.len, excludes.len);
        return OwningGroup(owned.len, includes.len, excludes.len);
    }

    /// given the 3 group Types arrays, generates a (mostly) unique u64 hash. Simultaneously ensures there are no duped types.
    inline fn hashGroupTypes(comptime owned: var, comptime includes: var, comptime excludes: var) u64 {
        comptime {
            for (owned) |t1| {
                for (includes) |t2| {
                    std.debug.assert(t1 != t2);

                    for (excludes) |t3| {
                        std.debug.assert(t1 != t3);
                        std.debug.assert(t2 != t3);
                    }
                }
            }

            const owned_str = comptime concatTypes(owned);
            const includes_str = comptime concatTypes(includes);
            const excludes_str = comptime concatTypes(excludes);

            return utils.hashStringFnv(u64, owned_str ++ includes_str ++ excludes_str);
        }
    }

    inline fn concatTypes(comptime types: var) []const u8 {
        comptime {
            comptime var res: []const u8 = "";
            inline for (types) |t| res = res ++ @typeName(t);
            return res;
        }
    }
};
