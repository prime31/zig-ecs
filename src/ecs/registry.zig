const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const utils = @import("utils.zig");

const Handles = @import("handles.zig").Handles;
const SparseSet = @import("sparse_set.zig").SparseSet;
const ComponentStorage = @import("component_storage.zig").ComponentStorage;
const Sink = @import("../signals/sink.zig").Sink;
const TypeStore = @import("type_store.zig").TypeStore;

// allow overriding EntityTraits by setting in root via: EntityTraits = EntityTraitsType(.medium);
const root = @import("root");
pub const Entity = if (@hasDecl(root, "Entity")) root.Entity else @import("entity.zig").DefaultEntity;

// setup the Handles type based on the type set in EntityTraits
pub const EntityHandles = Handles(Entity);

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
    components: std.AutoHashMapUnmanaged(u32, *anyopaque),
    contexts: std.AutoHashMapUnmanaged(u32, *anyopaque),
    groups: std.ArrayListUnmanaged(*GroupData),
    type_store: TypeStore,
    allocator: std.mem.Allocator,

    /// internal, persistant data structure to manage the entities in a group
    pub const GroupData = struct {
        hash: u64,
        size: u8,
        /// optional. there will be an entity_set for non-owning groups and current for owning
        entity_set: SparseSet(Entity) = undefined,
        owned: []u32,
        include: []u32,
        exclude: []u32,
        current: usize,

        pub fn create(allocator: std.mem.Allocator, hash: u64, owned: []u32, include: []u32, exclude: []u32) *GroupData {
            // std.debug.assert(std.mem.indexOfAny(u32, owned, include) == null);
            // std.debug.assert(std.mem.indexOfAny(u32, owned, exclude) == null);
            // std.debug.assert(std.mem.indexOfAny(u32, include, exclude) == null);
            var group_data = allocator.create(GroupData) catch unreachable;
            group_data.hash = hash;
            group_data.size = @intCast(owned.len + include.len + exclude.len);
            if (owned.len == 0) {
                group_data.entity_set = SparseSet(Entity).init(allocator);
            }
            group_data.owned = allocator.dupe(u32, owned) catch unreachable;
            group_data.include = allocator.dupe(u32, include) catch unreachable;
            group_data.exclude = allocator.dupe(u32, exclude) catch unreachable;
            group_data.current = 0;

            return group_data;
        }

        pub fn destroy(self: *GroupData, allocator: std.mem.Allocator) void {
            // only deinit th SparseSet for non-owning groups
            if (self.owned.len == 0) {
                self.entity_set.deinit();
            }
            allocator.free(self.owned);
            allocator.free(self.include);
            allocator.free(self.exclude);
            allocator.destroy(self);
        }

        /// On entity component update, adds the entity to our lists if it is valid
        pub fn maybeValidIf(self: *GroupData, registry: *Registry, entity: Entity) void {
            const isValid: bool = blk: {
                for (self.owned) |tid| {
                    const storage_ptr = registry.components.get(tid).?;
                    const storage: *Storage(u1) = @alignCast(@ptrCast(storage_ptr));
                    if (!storage.contains(entity))
                        break :blk false;
                }

                for (self.include) |tid| {
                    const storage_ptr = registry.components.get(tid).?;
                    const storage: *Storage(u1) = @alignCast(@ptrCast(storage_ptr));
                    if (!storage.contains(entity))
                        break :blk false;
                }

                for (self.exclude) |tid| {
                    const ptr = registry.components.get(tid).?;
                    const storage: *Storage(u1) = @alignCast(@ptrCast(ptr));
                    if (storage.contains(entity))
                        break :blk false;
                }
                break :blk true;
            };

            if (!isValid) return;

            // If this is not an owning group, just add the entity to our set of tracked entities
            if (self.owned.len == 0) {
                if (!self.entity_set.contains(entity)) self.entity_set.add(entity);
                return;
            }

            const first_owned_ptr = registry.components.get(self.owned[0]).?;
            const first_owned: *Storage(u1) = @alignCast(@ptrCast(first_owned_ptr));
            if (first_owned.set.index(entity) < self.current) return;

            for (self.owned) |owned_type| {
                // store.swap hides a safe version that types it correctly
                const storage_ptr = registry.components.get(owned_type).?;
                var storage: *Storage(u1) = @alignCast(@ptrCast(storage_ptr));
                storage.swap(storage.data()[self.current], entity);
            }
            std.debug.assert(self.owned.len >= 0);
            self.current += 1;
        }

        pub fn discardIf(self: *GroupData, registry: *Registry, entity: Entity) void {
            if (self.owned.len == 0) {
                if (self.entity_set.contains(entity)) self.entity_set.remove(entity);
                return;
            }

            const ptr = registry.components.get(self.owned[0]).?;
            var storage: *Storage(u1) = @alignCast(@ptrCast(ptr));
            if (storage.contains(entity) and storage.set.index(entity) < self.current) {
                self.current -= 1;
                for (self.owned) |tid| {
                    const store_ptr = registry.components.get(tid).?;
                    storage = @alignCast(@ptrCast(store_ptr));
                    storage.swap(storage.data()[self.current], entity);
                }
            }
        }

        /// finds the insertion point for this group by finding anything in the group family (overlapping owned)
        /// and finds the least specialized (based on size). This allows the least specialized to update first
        /// which ensures more specialized (ie less matches) will always be swapping inside the bounds of
        /// the less specialized groups.
        fn findInsertionIndex(self: GroupData, groups: []*GroupData) ?usize {
            for (groups, 0..) |grp, i| {
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
                if (i == 0) return null;
            }

            return null;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Registry {
        return Registry{
            .handles = EntityHandles.init(allocator),
            .components = .empty,
            .contexts = .empty,
            .groups = std.ArrayListUnmanaged(*GroupData){},
            .type_store = TypeStore.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Registry) void {
        var iter = self.components.valueIterator();
        while (iter.next()) |ptr| {
            // HACK: we dont know the Type here but we need to call deinit
            var storage: *Storage(u1) = @alignCast(@ptrCast(ptr.*));
            storage.destroy();
        }

        for (self.groups.items) |grp| {
            grp.destroy(self.allocator);
        }

        self.components.deinit(self.allocator);
        self.contexts.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.type_store.deinit();
        self.handles.deinit();
    }

    pub fn assure(self: *Registry, comptime T: type) *Storage(T) {
        if (@typeInfo(@TypeOf(T)) == .pointer) {
            @compileError("assure must receive a value, not a pointer. Received: " ++ @typeName(T));
        }

        const type_id = comptime utils.typeId(T);
        if (self.components.getEntry(type_id)) |kv| {
            return @alignCast(@ptrCast(kv.value_ptr.*));
        }

        const comp_set = Storage(T).create(self.allocator);
        comp_set.registry = self;
        _ = self.components.put(self.allocator, type_id, @ptrCast(comp_set)) catch unreachable;
        return comp_set;
    }

    /// Prepares a pool for the given type if required
    pub fn prepare(self: *Registry, comptime T: type) void {
        _ = self.assure(T);
    }

    /// Returns the number of existing components of the given type
    pub fn len(self: *Registry, comptime T: type) usize {
        return self.assure(T).len();
    }

    /// Increases the capacity of the registry or of the pools for the given component
    pub fn reserve(self: *Registry, comptime T: type, cap: usize) void {
        self.assure(T).reserve(cap);
    }

    /// Direct access to the list of components of a given pool
    pub fn raw(self: *Registry, comptime T: type) []T {
        return self.assure(T).raw();
    }

    /// Direct access to the list of entities of a given pool
    pub fn data(self: *Registry, comptime T: type) []Entity {
        return self.assure(T).dataPtr().*;
    }

    pub fn valid(self: *Registry, entity: Entity) bool {
        return self.handles.alive(entity);
    }

    /// Creates a new entity and returns it
    pub fn create(self: *Registry) Entity {
        return self.handles.create() catch unreachable;
    }

    /// Destroys an entity
    pub fn destroy(self: *Registry, entity: Entity) void {
        assert(self.valid(entity));
        self.removeAll(entity);
        self.handles.remove(entity) catch unreachable;
    }

    /// returns an interator that iterates all live entities
    pub fn entities(self: Registry) EntityHandles.Iterator {
        return self.handles.iterator();
    }

    pub fn add(self: *Registry, entity: Entity, value: anytype) void {
        assert(self.valid(entity));
        self.assure(@TypeOf(value)).add(entity, value);
    }

    /// shortcut for adding raw comptime_int/float without having to @as cast
    pub fn addTyped(self: *Registry, comptime T: type, entity: Entity, value: T) void {
        self.add(entity, value);
    }

    /// adds all the component types passed in as zero-initialized values
    pub fn addTypes(self: *Registry, entity: Entity, comptime types: anytype) void {
        inline for (types) |t| {
            self.assure(t).add(entity, std.mem.zeroes(t));
        }
    }

    /// Replaces the given component for an entity
    pub fn replace(self: *Registry, entity: Entity, value: anytype) void {
        assert(self.valid(entity));

        self.assure(@TypeOf(value)).replace(entity, value);
    }

    /// shortcut for replacing raw comptime_int/float without having to @as cast
    pub fn replaceTyped(self: *Registry, comptime T: type, entity: Entity, value: T) void {
        if (@typeInfo(@TypeOf(value)) == .pointer) {
            @compileError("replaceTyped must receive a value, not a pointer. Received: " ++ @typeName(@TypeOf(value)));
        }
        self.replace(entity, value);
    }

    pub fn addOrReplace(self: *Registry, entity: Entity, value: anytype) void {
        assert(self.valid(entity));
        if (@typeInfo(@TypeOf(value)) == .pointer) {
            @compileError("addOrReplace must receive a value, not a pointer. Received: " ++ @typeName(@TypeOf(value)));
        }

        const store = self.assure(@TypeOf(value));

        const is_empty_struct = @sizeOf(@TypeOf(value)) == 0;
        if (is_empty_struct) {
            if (!self.assure(@TypeOf(value)).contains(entity)) {
                store.add(entity, value);
                store.update.publish(.{ self, entity });
            }
            return;
        }

        if (store.tryGet(entity)) |found| {
            found.* = value;
            store.update.publish(.{ self, entity });
        } else {
            store.add(entity, value);
        }
    }

    /// emits a signal for the onUpdate sink
    pub fn notifyUpdated(self: *Registry, comptime T: type, entity: Entity) void {
        assert(self.valid(entity));

        const store = self.assure(T);
        if (store.contains(entity)) {
            store.update.publish(.{ self, entity });
        }
    }

    /// same as addOrReplace but it returns the previous value (if any)
    pub fn fetchReplace(self: *Registry, entity: Entity, value: anytype) ?@TypeOf(value) {
        assert(self.valid(entity));

        const store = self.assure(@TypeOf(value));

        const is_empty_struct = @sizeOf(@TypeOf(value)) == 0;
        if (is_empty_struct) {
            if (!self.assure(@TypeOf(value)).contains(entity)) {
                store.add(entity, value);
                store.update.publish(.{ self, entity });
                return null;
            }
            return value;
        }

        if (store.tryGet(entity)) |found| {
            const old = found.*;
            found.* = value;
            store.update.publish(.{ self, entity });
            return old;
        } else {
            store.add(entity, value);
            return null;
        }
    }

    /// same as remove but it returns the previous value (if any)
    pub fn fetchRemove(self: *Registry, comptime T: type, entity: Entity) ?T {
        assert(self.valid(entity));

        const store = self.assure(T);

        const is_empty_struct = @sizeOf(T) == 0;
        if (is_empty_struct) {
            if (self.assure(T).contains(entity)) {
                store.remove(entity);
                store.update.publish(.{ self, entity });
                return T{};
            }
            return null;
        }
        if (store.tryGet(entity)) |found| {
            const old = found.*;
            store.remove(entity);
            return old;
        } else {
            return null;
        }
    }

    /// shortcut for add-or-replace raw comptime_int/float without having to @as cast
    pub fn addOrReplaceTyped(self: *Registry, comptime T: type, entity: Entity, value: T) void {
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
        if (store.contains(entity)) {
            store.remove(entity);
        }
    }

    /// Removes all the components from an entity and makes it orphaned
    pub fn removeAll(self: *Registry, entity: Entity) void {
        assert(self.valid(entity));

        var iter = self.components.valueIterator();
        while (iter.next()) |value| {
            // HACK: we dont know the Type here but we need to be able to call methods on the Storage(T)
            var storage: *Storage(u1) = @alignCast(@ptrCast(value.*));
            storage.removeIfContains(entity);
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
        if (!self.has(T, entity)) {
            self.addTyped(T, entity, .{});
        }
        return self.get(T, entity);
    }

    pub fn tryGet(self: *Registry, comptime T: type, entity: Entity) ?*T {
        return self.assure(T).tryGet(entity);
    }

    /// same as tryGet but it stores the result on the stack, this option tends to be preferrable when dealing
    /// with complex logic that may create CPU cache misses
    pub fn tryGetConst(self: *Registry, comptime T: type, entity: Entity) ?T {
        if (self.assure(T).tryGet(entity)) |ptr| {
            const ret: T = ptr.*;
            return ret;
        }
        return null;
    }

    /// Returns a Sink object for the given component to add/remove listeners with
    pub fn onConstruct(self: *Registry, comptime T: type) Sink(.{ *Registry, Entity }) {
        return self.assure(T).onConstruct();
    }

    /// Returns a Sink object for the given component to add/remove listeners with
    pub fn onUpdate(self: *Registry, comptime T: type) Sink(.{ *Registry, Entity }) {
        return self.assure(T).onUpdate();
    }

    /// Returns a Sink object for the given component to add/remove listeners with
    pub fn onDestruct(self: *Registry, comptime T: type) Sink(.{ *Registry, Entity }) {
        return self.assure(T).onDestruct();
    }

    /// Binds an object to the context of the registry
    pub fn setContext(self: *Registry, context: anytype) void {
        std.debug.assert(@typeInfo(@TypeOf(context)) == .pointer);

        const type_id = utils.typeId(@typeInfo(@TypeOf(context)).pointer.child);
        _ = self.contexts.put(self.allocator, type_id, @ptrCast(context)) catch unreachable;
    }

    /// Unsets a context variable if it exists
    pub fn unsetContext(self: *Registry, comptime T: type) void {
        std.debug.assert(@typeInfo(T) != .pointer);
        _ = self.contexts.remove(utils.typeId(T));
    }

    /// Returns a pointer to an object in the context of the registry
    pub fn getContext(self: *Registry, comptime T: type) ?*T {
        std.debug.assert(@typeInfo(T) != .pointer);

        return @alignCast(@ptrCast(self.contexts.get(utils.typeId(T))));
    }

    /// provides access to a TypeStore letting you add singleton components to the registry
    pub fn singletons(self: *Registry) *TypeStore {
        return &self.type_store;
    }

    pub fn sort(self: *Registry, comptime T: type, comptime lessThan: *const fn (void, T, T) bool) void {
        const comp = self.assure(T);
        std.debug.assert(comp.super == 0);
        comp.sort(T, comp.len(), {}, lessThan);
    }

    /// Checks whether the given component belongs to any group. If so, it is not sortable directly.
    pub fn sortable(self: *Registry, comptime T: type) bool {
        return self.assure(T).super == 0;
    }

    pub fn view(self: *Registry, comptime includes: anytype, comptime excludes: anytype) ViewType(includes, excludes) {
        if (comptime @typeInfo(@TypeOf(includes)) != .@"struct") @compileError("'includes' argument must be a tuple");
        if (comptime @typeInfo(@TypeOf(excludes)) != .@"struct") @compileError("'excludes' argument must be a tuple");
        if (comptime includes.len < 1) @compileError("'includes' must have at least one element");

        // just one include so use the optimized BasicView
        if (includes.len == 1 and excludes.len == 0)
            return BasicView(includes[0]).init(self.assure(includes[0]));

        return MultiView(includes, excludes).init(self);
    }

    pub fn basicView(self: *Registry, comptime Component: anytype) BasicView(Component) {
        // just one include so use the optimized BasicView
        return BasicView(Component).init(self.assure(Component));
    }

    pub fn entityIterator(self: *Registry, comptime Component: anytype) utils.ReverseSliceIterator(Entity) {
        // just one include so use the optimized BasicView
        return BasicView(Component).init(self.assure(Component)).entityIterator();
    }

    /// returns the Type that a view will be based on the includes and excludes
    fn ViewType(comptime includes: anytype, comptime excludes: anytype) type {
        if (includes.len == 1 and excludes.len == 0) return BasicView(includes[0]);
        return MultiView(includes, excludes);
    }

    /// creates an optimized group for iterating components
    pub fn group(self: *Registry, comptime owned: anytype, comptime includes: anytype, comptime excludes: anytype) (if (owned.len == 0) BasicGroup else OwningGroup) {
        std.debug.assert(@typeInfo(@TypeOf(owned)) == .@"struct");
        std.debug.assert(@typeInfo(@TypeOf(includes)) == .@"struct");
        std.debug.assert(@typeInfo(@TypeOf(excludes)) == .@"struct");
        std.debug.assert(owned.len + includes.len > 0);
        std.debug.assert(owned.len + includes.len + excludes.len >= 1);

        // create a unique hash to identify the group so that we can look it up
        const hash = comptime hashGroupTypes(owned, includes, excludes);

        for (self.groups.items) |grp| {
            if (grp.hash == hash) {
                if (owned.len == 0) {
                    return BasicGroup.init(self, grp);
                }
                var first_owned = self.assure(owned[0]);
                return OwningGroup.init(self, grp, &first_owned.super);
            }
        }

        // gather up all our Types as typeIds
        var includes_arr: [includes.len]u32 = undefined;
        inline for (includes, 0..) |t, i| {
            _ = self.assure(t);
            includes_arr[i] = utils.typeId(t);
        }

        var excludes_arr: [excludes.len]u32 = undefined;
        inline for (excludes, 0..) |t, i| {
            _ = self.assure(t);
            excludes_arr[i] = utils.typeId(t);
        }

        var owned_arr: [owned.len]u32 = undefined;
        inline for (owned, 0..) |t, i| {
            _ = self.assure(t);
            owned_arr[i] = utils.typeId(t);
        }

        // we need to create a new GroupData
        var new_group_data = GroupData.create(self.allocator, hash, owned_arr[0..], includes_arr[0..], excludes_arr[0..]);

        // before adding the group we need to do some checks to make sure there arent other owning groups with the same types
        if (builtin.mode == .Debug and owned.len > 0) {
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

                const check = overlapping == 0 or ((sz == new_group_data.size) or (sz == grp.size));
                std.debug.assert(check);
            }
        }

        var maybe_valid_if: ?*GroupData = null;
        var discard_if: ?*GroupData = null;

        if (owned.len == 0) {
            self.groups.append(self.allocator, new_group_data) catch unreachable;
        } else {
            // if this is a group in a family, we may need to do an insert so get the insertion index first
            const maybe_index = new_group_data.findInsertionIndex(self.groups.items);

            // if there is a previous group in this family, we use it for inserting our discardIf calls
            if (new_group_data.findPreviousIndex(self.groups.items, maybe_index)) |prev| {
                discard_if = self.groups.items[prev];
            }

            if (maybe_index) |index| {
                maybe_valid_if = self.groups.items[index];
                self.groups.insert(self.allocator, index, new_group_data) catch unreachable;
            } else {
                self.groups.append(self.allocator, new_group_data) catch unreachable;
            }

            // update super on all owned Storages to be the max of size and their current super value
            inline for (owned) |t| {
                var storage = self.assure(t);
                storage.super = @max(storage.super, new_group_data.size);
            }
        }

        // wire up our listeners
        inline for (owned) |t| self.onConstruct(t).beforeBound(maybe_valid_if).connectBound(new_group_data, GroupData.maybeValidIf);
        inline for (includes) |t| self.onConstruct(t).beforeBound(maybe_valid_if).connectBound(new_group_data, GroupData.maybeValidIf);
        inline for (excludes) |t| self.onDestruct(t).beforeBound(maybe_valid_if).connectBound(new_group_data, GroupData.maybeValidIf);

        inline for (owned) |t| self.onDestruct(t).beforeBound(discard_if).connectBound(new_group_data, GroupData.discardIf);
        inline for (includes) |t| self.onDestruct(t).beforeBound(discard_if).connectBound(new_group_data, GroupData.discardIf);
        inline for (excludes) |t| self.onConstruct(t).beforeBound(discard_if).connectBound(new_group_data, GroupData.discardIf);

        // pre-fill the GroupData with any existing entitites that match
        if (owned.len == 0) {
            var view_instance = self.view(owned ++ includes, excludes);
            var view_iter = view_instance.entityIterator();
            while (view_iter.next()) |entity| {
                new_group_data.entity_set.add(entity);
            }
        } else {
            // we cannot iterate backwards because we want to leave behind valid entities in case of owned types
            // ??? why not?
            var first_owned_storage = self.assure(owned[0]);
            for (first_owned_storage.data()) |entity| {
                new_group_data.maybeValidIf(self, entity);
            }
            // for(auto *first = std::get<0>(cpools).data(), *last = first + std::get<0>(cpools).size(); first != last; ++first) {
            //     handler->template maybe_valid_if<std::tuple_element_t<0, std::tuple<std::decay_t<Owned>...>>>(*this, *first);
            // }
        }

        if (owned.len == 0) {
            return BasicGroup.init(self, new_group_data);
        } else {
            var first_owned_storage = self.assure(owned[0]);
            return OwningGroup.init(self, new_group_data, &first_owned_storage.super);
        }
    }

    /// given the 3 group Types arrays, generates a (mostly) unique u64 hash. Simultaneously ensures there are no duped types between
    /// the 3 groups.
    inline fn hashGroupTypes(comptime owned: anytype, comptime includes: anytype, comptime excludes: anytype) u64 {
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

            const owned_str = concatTypes(owned);
            const includes_str = concatTypes(includes);
            const excludes_str = concatTypes(excludes);

            return utils.hashStringFnv(u64, owned_str ++ includes_str ++ excludes_str);
        }
    }

    /// expects a tuple of types. Convertes them to type names, sorts them then concatenates and returns the string.
    inline fn concatTypes(comptime types: anytype) []const u8 {
        comptime {
            if (types.len == 0) return "_";

            const impl = struct {
                fn asc(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.lessThan(u8, lhs, rhs);
                }
            };

            var names: [types.len][]const u8 = undefined;
            for (&names, 0..) |*name, i| {
                name.* = @typeName(types[i]);
            }

            std.sort.pdq([]const u8, &names, {}, impl.asc);

            var res: []const u8 = "";
            for (names) |name| res = res ++ name;
            return res;
        }
    }
};
