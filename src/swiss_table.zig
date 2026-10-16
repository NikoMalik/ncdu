//! Compact flat hash table with SwissTable-style control-byte probing.
const std = @import("std");
const fastmem = @import("fastmem.zig");
const assert = fastmem.assert;
const hashmod = @import("hash.zig");

pub fn HashFn(comptime K: type) type {
    return fn (key: K) callconv(.@"inline") u64;
}

pub inline fn randomSeed() u64 {
    const local = struct {
        threadlocal var counter: u64 = 0;
    };
    local.counter += 1;
    return local.counter ^ @intFromPtr(&local.counter);
}

/// Uses the project's inline hash implementation and a stable seed.
pub inline fn HashPicker(comptime K: type) HashFn(K) {
    return struct {
        pub inline fn hash(key: K) u64 {
            return hashmod.hash_inline(key, 0);
        }
    }.hash;
}

pub fn SwissTable(
    comptime K: type,
    comptime V: type,
    comptime group_size: usize,
    comptime eql_fn: fn (K, K) callconv(.@"inline") bool,
    comptime hash_fn: fn (K) callconv(.@"inline") u64,
    comptime key_from_value: fn (*const V) callconv(.@"inline") K,
    comptime max_load_factor: f32,
    comptime fixed_cap: ?usize,
) type {
    comptime assert(group_size >= 8);
    comptime assert(max_load_factor >= 0 and max_load_factor <= 1);
    return struct {
        comptime {
            if (group_size != 8 and group_size != 16 and group_size != 32 and group_size != 64 and group_size != 128)
                @compileError("group_size must be 8, 16, 32, 64, or 128");
            if (fixed_cap) |cap| {
                if (cap < group_size or cap == 0 or !std.math.isPowerOfTwo(cap))
                    @compileError("fixed_cap must be a power of two >= group_size");
            }
        }
        const Self = @This();
        const ctrl_empty: i8 = -128;
        const ctrl_deleted: i8 = -2;
        const load_pct: usize = @intFromFloat(max_load_factor * 100);
        const Mask = std.meta.Int(.unsigned, group_size);

        const Slot = struct { value: V };
        const Group = struct {
            bytes: @Vector(group_size, i8),

            fn init(ptr: [*]const i8) Group {
                const slice: *const [group_size]i8 = @ptrCast(ptr);
                return .{ .bytes = slice.* };
            }

            fn equal(self: Group, value: i8) Mask {
                const matches: @Vector(group_size, bool) = self.bytes == @as(@Vector(group_size, i8), @splat(value));
                return @bitCast(matches);
            }

            fn empty(self: Group) Mask {
                return self.equal(ctrl_empty);
            }

            fn emptyOrDeleted(self: Group) Mask {
                const matches: @Vector(group_size, bool) = self.bytes < @as(@Vector(group_size, i8), @splat(0));
                return @bitCast(matches);
            }
        };

        allocator: if (fixed_cap == null) std.mem.Allocator else void,
        ctrl: if (fixed_cap) |cap| [cap + group_size]i8 else []i8,
        slots: if (fixed_cap) |cap| [cap]Slot else []Slot,
        cap: usize,
        size: usize = 0,
        growth_left: usize,

        pub const Error = error{ OutOfMemory, CapacityOverflow, CapacityInsufficient, KeyExists };
        pub const GetOrPutResult = struct { found_existing: bool, ptr: *V };

        inline fn getCtrlPtr(self: anytype) if (@TypeOf(self) == *const Self) [*]const i8 else [*]i8 {
            if (comptime fixed_cap != null) return @ptrCast(&self.ctrl[0]);
            return self.ctrl.ptr;
        }

        inline fn getSlotsPtr(self: anytype) if (@TypeOf(self) == *const Self) [*]const Slot else [*]Slot {
            if (comptime fixed_cap != null) return @ptrCast(&self.slots[0]);
            return self.slots.ptr;
        }

        pub fn init(
            allocator: if (fixed_cap == null) std.mem.Allocator else ?std.mem.Allocator,
            initial_capacity: if (fixed_cap == null) usize else ?usize,
        ) Error!Self {
            if (comptime fixed_cap) |cap| {
                var ctrl: [cap + group_size]i8 = undefined;
                @memset(&ctrl, ctrl_empty);
                return .{ .allocator = {}, .ctrl = ctrl, .slots = undefined, .cap = cap, .growth_left = capacityFor(cap) };
            } else if (initial_capacity == 0) {
                return .{ .allocator = allocator, .ctrl = &.{}, .slots = &.{}, .cap = 0, .growth_left = 0 };
            } else if (comptime fixed_cap == null) {
                const cap = std.math.ceilPowerOfTwo(usize, @max(initial_capacity, group_size)) catch return error.CapacityOverflow;
                if (cap == 0 or cap < group_size) return error.CapacityInsufficient;
                const ctrl = try allocator.alloc(i8, cap + group_size);
                errdefer allocator.free(ctrl);
                const slots = try allocator.alloc(Slot, cap);
                @memset(ctrl, ctrl_empty);
                return .{ .allocator = allocator, .ctrl = ctrl, .slots = slots, .cap = cap, .growth_left = capacityFor(cap) };
            }
            unreachable;
        }

        pub fn deinit(self: *Self) void {
            if (comptime fixed_cap == null) {
                self.allocator.free(self.ctrl);
                self.allocator.free(self.slots);
            }
            self.* = undefined;
        }

        pub fn clone(self: *const Self, allocator: std.mem.Allocator) Error!Self {
            if (comptime fixed_cap != null) @compileError("clone not supported for fixed-capacity tables");
            const ctrl = try allocator.alloc(i8, self.cap + group_size);
            errdefer allocator.free(ctrl);
            const slots = try allocator.alloc(Slot, self.cap);
            fastmem.copy(i8, ctrl, self.ctrl);
            fastmem.copy(Slot, slots, self.slots);
            return .{
                .allocator = allocator,
                .ctrl = ctrl,
                .slots = slots,
                .cap = self.cap,
                .size = self.size,
                .growth_left = self.growth_left,
            };
        }

        fn capacityFor(cap: usize) usize {
            return (cap * load_pct) / 100;
        }

        pub fn count(self: *const Self) usize {
            return self.size;
        }

        pub fn capacity(self: *const Self) usize {
            return self.cap;
        }

        pub fn ensureUnusedCapacity(self: *Self, additional: usize) Error!void {
            const needed = std.math.add(usize, self.size, additional) catch return error.CapacityOverflow;
            if (capacityFor(self.cap) < needed) return error.CapacityInsufficient;
        }

        pub fn ensureTotalCapacity(self: *Self, additional: usize) Error!void {
            if (comptime fixed_cap != null) return;
            const needed = std.math.add(usize, self.size, additional) catch return error.CapacityOverflow;
            var new_cap = self.cap;
            if (new_cap == 0 and needed > 0) new_cap = group_size;
            while (capacityFor(new_cap) < needed) {
                new_cap = std.math.mul(usize, new_cap, 2) catch return error.CapacityOverflow;
            }
            if (new_cap == self.cap) return;
            try self.reallocate(new_cap);
        }

        pub fn get(self: *const Self, key: K) ?V {
            if (self.cap == 0) return null;
            const hash = hash_fn(key);
            const tag: i8 = @intCast(hash >> 57);
            var pos: usize = @truncate(hash & (self.cap - 1));
            while (true) {
                const group = Group.init(self.ctrl.ptr + pos);
                var matches = group.equal(tag);
                while (matches != 0) {
                    const idx = (pos + @ctz(matches)) & (self.cap - 1);
                    const value = self.slots[idx].value;
                    if (eql_fn(key_from_value(&value), key)) return value;
                    matches &= matches - 1;
                }
                if (group.empty() != 0) return null;
                pos = (pos + group_size) & (self.cap - 1);
            }
        }

        pub fn getEntry(self: *const Self, key: K) ?struct { key: K, value: V } {
            const value = self.get(key) orelse return null;
            return .{ .key = key_from_value(&value), .value = value };
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.get(key) != null;
        }

        pub fn prefetchKey(self: *const Self, key: K) void {
            if (self.cap == 0) return;
            const pos = self.probeStart(hash_fn(key));
            @prefetch(self.getCtrlPtr() + pos, .{ .cache = .data, .locality = 3, .rw = .read });
            @prefetch(self.getSlotsPtr() + pos, .{ .cache = .data, .locality = 3, .rw = .read });
            const next_pos = self.groupProbe(pos);
            @prefetch(self.getCtrlPtr() + next_pos, .{ .cache = .data, .locality = 2, .rw = .read });
            @prefetch(self.getSlotsPtr() + next_pos, .{ .cache = .data, .locality = 2, .rw = .read });
        }

        inline fn probeStart(self: *const Self, hash: u64) usize {
            return @truncate(hash & (self.cap - 1));
        }

        inline fn groupProbe(self: *const Self, pos: usize) usize {
            return (pos + group_size) & (self.cap - 1);
        }

        pub fn getOrPut(self: *Self, key: K) Error!GetOrPutResult {
            if (self.cap == 0) try self.ensureTotalCapacity(1);
            const hash = hash_fn(key);
            const tag: i8 = @intCast(hash >> 57);
            var pos: usize = @truncate(hash & (self.cap - 1));
            var first_reusable: ?usize = null;
            var groups_checked: usize = 0;
            while (true) {
                const group = Group.init(self.ctrl.ptr + pos);
                var matches = group.equal(tag);
                while (matches != 0) {
                    const idx = (pos + @ctz(matches)) & (self.cap - 1);
                    if (eql_fn(key_from_value(&self.slots[idx].value), key))
                        return .{ .found_existing = true, .ptr = &self.slots[idx].value };
                    matches &= matches - 1;
                }
                if (first_reusable == null) {
                    const reusable = group.emptyOrDeleted();
                    if (reusable != 0) first_reusable = (pos + @ctz(reusable)) & (self.cap - 1);
                }
                if (group.empty() != 0) {
                    const idx = first_reusable orelse unreachable;
                    return self.insertAt(idx, key, tag);
                }
                pos = (pos + group_size) & (self.cap - 1);
                groups_checked += 1;
                if (groups_checked * group_size >= self.cap) {
                    if (first_reusable) |idx| return self.insertAt(idx, key, tag);
                    if (comptime fixed_cap != null) return error.CapacityInsufficient;
                    try self.grow();
                    return self.getOrPut(key);
                }
            }
        }

        fn insertAt(self: *Self, idx: usize, key: K, tag: i8) Error!GetOrPutResult {
            const was_empty = self.ctrl[idx] == ctrl_empty;
            if (was_empty and self.growth_left == 0) {
                if (comptime fixed_cap != null) return error.CapacityInsufficient;
                try self.grow();
                const result = try self.getOrPut(key);
                assert(!result.found_existing);
                return result;
            }
            self.setCtrl(idx, tag);
            if (was_empty) self.growth_left -= 1;
            self.size += 1;
            return .{ .found_existing = false, .ptr = &self.slots[idx].value };
        }

        fn insertUniqueReturn(self: *Self, key: K) *V {
            const hash = hash_fn(key);
            const tag: i8 = @intCast(hash >> 57);
            var pos = self.probeStart(hash);
            var groups_checked: usize = 0;
            while (true) {
                const group = Group.init(self.ctrl.ptr + pos);
                const matches = group.empty();
                if (matches != 0) {
                    const idx = (pos + @ctz(matches)) & (self.cap - 1);
                    self.setCtrl(idx, tag);
                    self.growth_left -= 1;
                    self.size += 1;
                    return &self.slots[idx].value;
                }
                pos = self.groupProbe(pos);
                groups_checked += 1;
                assert(groups_checked * group_size < self.cap);
            }
        }

        pub fn put(self: *Self, key: K, value: V) Error!void {
            const result = try self.getOrPut(key);
            result.ptr.* = value;
        }

        pub fn putNoClobber(self: *Self, key: K, value: V) Error!void {
            const result = try self.getOrPut(key);
            if (result.found_existing) return error.KeyExists;
            result.ptr.* = value;
        }

        pub fn getOrPutValue(self: *Self, key: K, value: V) Error!*V {
            const result = try self.getOrPut(key);
            if (!result.found_existing) result.ptr.* = value;
            return result.ptr;
        }

        pub fn fetchPut(self: *Self, key: K, value: V) Error!?V {
            const result = try self.getOrPut(key);
            if (result.found_existing) {
                const old = result.ptr.*;
                result.ptr.* = value;
                return old;
            }
            result.ptr.* = value;
            return null;
        }

        pub fn putAssumeCapacity(self: *Self, key: K, value: V) void {
            self.put(key, value) catch unreachable;
        }

        pub fn remove(self: *Self, key: K) bool {
            if (self.cap == 0) return false;
            const hash = hash_fn(key);
            const tag: i8 = @intCast(hash >> 57);
            var pos: usize = @truncate(hash & (self.cap - 1));
            while (true) {
                const group = Group.init(self.ctrl.ptr + pos);
                var matches = group.equal(tag);
                while (matches != 0) {
                    const idx = (pos + @ctz(matches)) & (self.cap - 1);
                    if (eql_fn(key_from_value(&self.slots[idx].value), key)) {
                        self.eraseAt(idx);
                        return true;
                    }
                    matches &= matches - 1;
                }
                if (group.empty() != 0) return false;
                pos = (pos + group_size) & (self.cap - 1);
            }
        }

        fn setCtrl(self: *Self, idx: usize, value: i8) void {
            self.ctrl[idx] = value;
            const mirror = ((idx -% group_size) & (self.cap - 1)) + group_size;
            self.ctrl[mirror] = value;
        }

        fn eraseAt(self: *Self, idx: usize) void {
            const cap_mask = self.cap - 1;
            const before_pos = (idx -% group_size) & cap_mask;
            const before = Group.init(self.ctrl.ptr + before_pos).empty();
            const after = Group.init(self.ctrl.ptr + idx).empty();
            if (@clz(before) + @ctz(after) < group_size) {
                self.setCtrl(idx, ctrl_empty);
                self.growth_left += 1;
            } else {
                self.setCtrl(idx, ctrl_deleted);
            }
            self.size -= 1;
        }

        fn grow(self: *Self) Error!void {
            if (comptime fixed_cap != null) return error.CapacityInsufficient;
            assert(self.cap >= group_size);
            if (self.size <= capacityFor(self.cap) / 2) {
                self.rehashInPlace();
                return;
            }
            const new_cap = std.math.mul(usize, self.cap, 2) catch return error.CapacityOverflow;
            try self.reallocate(new_cap);
        }

        fn reallocate(self: *Self, new_cap: usize) Error!void {
            var next = try Self.init(self.allocator, new_cap);
            errdefer next.deinit();
            for (0..self.cap) |i| {
                if (self.ctrl[i] >= 0) {
                    const value = self.slots[i].value;
                    next.insertUniqueReturn(key_from_value(&value)).* = value;
                }
            }
            assert(next.size == self.size);
            self.allocator.free(self.ctrl);
            self.allocator.free(self.slots);
            self.* = next;
        }

        inline fn findInsertSlot(self: *Self, hash: u64) usize {
            var pos = self.probeStart(hash);
            while (true) {
                const matches = Group.init(self.ctrl.ptr + pos).emptyOrDeleted();
                if (matches != 0) return (pos + @ctz(matches)) & (self.cap - 1);
                pos = self.groupProbe(pos);
            }
        }

        inline fn isInSameGroup(self: *const Self, a: usize, b: usize, hash: u64) bool {
            const start = self.probeStart(hash);
            const ga = ((a -% start) & (self.cap - 1)) / group_size;
            const gb = ((b -% start) & (self.cap - 1)) / group_size;
            return ga == gb;
        }

        fn rehashInPlace(self: *Self) void {
            var gi: usize = 0;
            while (gi < self.cap) : (gi += group_size) {
                const group = Group.init(self.ctrl.ptr + gi);
                const mask: @Vector(group_size, i8) = @splat(ctrl_empty);
                const deleted: @Vector(group_size, i8) = @splat(ctrl_deleted);
                const zero: @Vector(group_size, i8) = @splat(0);
                const converted = @select(i8, group.bytes < zero, mask, deleted);
                const dst: *[group_size]i8 = @ptrCast(self.ctrl.ptr + gi);
                dst.* = converted;
            }
            fastmem.copy(i8, self.ctrl.ptr[self.cap..][0..group_size], self.ctrl.ptr[0..group_size]);

            var i: usize = 0;
            outer: while (i < self.cap) : (i += 1) {
                if (self.ctrl[i] != ctrl_deleted) continue;
                inner: while (true) {
                    const hash = hash_fn(key_from_value(&self.slots[i].value));
                    const tag: i8 = @intCast(hash >> 57);
                    const target = self.findInsertSlot(hash);
                    if (self.isInSameGroup(i, target, hash)) {
                        self.setCtrl(i, tag);
                        continue :outer;
                    }
                    const previous = self.ctrl[target];
                    self.setCtrl(target, tag);
                    if (previous == ctrl_empty) {
                        self.setCtrl(i, ctrl_empty);
                        self.slots[target].value = self.slots[i].value;
                        continue :outer;
                    }
                    assert(previous == ctrl_deleted);
                    std.mem.swap(V, &self.slots[i].value, &self.slots[target].value);
                    continue :inner;
                }
            }
            self.growth_left = capacityFor(self.cap) - self.size;
        }

        pub const Iterator = struct {
            table: *const Self,
            index: usize = 0,

            pub fn next(it: *Iterator) ?struct { K, V } {
                while (it.index < it.table.cap) {
                    const i = it.index;
                    it.index += 1;
                    if (it.table.ctrl[i] >= 0) {
                        const value = it.table.slots[i].value;
                        return .{ key_from_value(&value), value };
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .table = self };
        }

        pub fn clear(self: *Self) void {
            @memset(self.ctrl, ctrl_empty);
            self.size = 0;
            self.growth_left = capacityFor(self.cap);
        }

        pub fn clearAndFree(self: *Self) void {
            if (comptime fixed_cap != null) {
                self.clear();
                return;
            }
            self.allocator.free(self.ctrl);
            self.allocator.free(self.slots);
            self.ctrl = &.{};
            self.slots = &.{};
            self.cap = 0;
            self.size = 0;
            self.growth_left = 0;
        }
    };
}
