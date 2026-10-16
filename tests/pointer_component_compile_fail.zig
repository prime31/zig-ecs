// Each build selects one invalid call and requires the component-type diagnostic.
const std = @import("std");
const ecs = @import("ecs");
const options = @import("pointer_case");
const C = struct { n: u32 = 0 };
fn less(_: void, a: *C, b: *C) bool {
    return a.n < b.n;
}
test "pointer component is rejected" {
    var r = ecs.Registry.init(std.testing.allocator);
    defer r.deinit();
    const e = r.create();
    var value: C = .{};
    _ = &value;
    switch (comptime options.case_index) {
        0 => {
            _ = r.add(e, &value);
        },
        1 => {
            _ = r.addTyped(*C, e, &value);
        },
        2 => {
            _ = r.addTypes(e, .{*C});
        },
        3 => {
            _ = r.replace(e, &value);
        },
        4 => {
            _ = r.replaceTyped(*C, e, &value);
        },
        5 => {
            _ = r.addOrReplace(e, &value);
        },
        6 => {
            _ = r.addOrReplaceTyped(*C, e, &value);
        },
        7 => {
            _ = r.fetchReplace(e, &value);
        },
        8 => {
            _ = r.notifyUpdated(*C, e);
        },
        9 => {
            _ = r.fetchRemove(*C, e);
        },
        10 => {
            _ = r.remove(*C, e);
        },
        11 => {
            _ = r.removeIfExists(*C, e);
        },
        12 => {
            _ = r.has(*C, e);
        },
        13 => {
            _ = r.get(*C, e);
        },
        14 => {
            _ = r.getConst(*C, e);
        },
        15 => {
            _ = r.getOrAdd(*C, e);
        },
        16 => {
            _ = r.tryGet(*C, e);
        },
        17 => {
            _ = r.tryGetConst(*C, e);
        },
        18 => {
            _ = r.assure(*C);
        },
        19 => {
            _ = r.prepare(*C);
        },
        20 => {
            _ = r.len(*C);
        },
        21 => {
            _ = r.reserve(*C, 2);
        },
        22 => {
            _ = r.raw(*C);
        },
        23 => {
            _ = r.data(*C);
        },
        24 => {
            _ = r.onConstruct(*C);
        },
        25 => {
            _ = r.onUpdate(*C);
        },
        26 => {
            _ = r.onDestruct(*C);
        },
        27 => {
            _ = r.sortable(*C);
        },
        28 => {
            _ = r.view(.{*C}, .{});
        },
        29 => {
            _ = r.view(.{C}, .{*C});
        },
        30 => {
            _ = r.basicView(*C);
        },
        31 => {
            _ = r.entityIterator(*C);
        },
        32 => {
            _ = r.group(.{*C}, .{}, .{});
        },
        33 => {
            _ = r.group(.{}, .{*C}, .{});
        },
        34 => {
            _ = r.group(.{C}, .{}, .{*C});
        },
        35 => {
            _ = r.singletons().add(&value);
        },
        36 => {
            _ = r.singletons().get(*C);
        },
        37 => {
            _ = r.singletons().getConst(*C);
        },
        38 => {
            _ = r.singletons().getOrAdd(*C);
        },
        39 => {
            _ = r.singletons().remove(*C);
        },
        40 => {
            _ = r.singletons().has(*C);
        },
        41 => {
            _ = r.sort(*C, less);
        },
        else => unreachable,
    }
}
