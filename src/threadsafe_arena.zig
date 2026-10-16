//! Thread-safe arena allocator. Allocations use atomic bump allocation in the
//! active chunk. Chunks that cannot be reused are kept on a free list.
const std = @import("std");
const assert = @import("fastmem.zig").assert;
const mem = std.mem;
const Allocator = mem.Allocator;
const Alignment = mem.Alignment;

const ArenaAllocator = @This();

child_allocator: Allocator,
state: State,

pub const State = struct {
    used_list: ?*Node = null,
    free_list: ?*Node = null,

    pub const init: State = .{};

    pub fn promote(state: State, child_allocator: Allocator) ArenaAllocator {
        return .{ .child_allocator = child_allocator, .state = state };
    }
};

pub fn init(child_allocator: Allocator) ArenaAllocator {
    return State.init.promote(child_allocator);
}

pub fn allocator(arena: *ArenaAllocator) Allocator {
    return .{
        .ptr = arena,
        .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
    };
}

/// Call only after all users of this allocator have stopped.
pub fn deinit(arena: ArenaAllocator) void {
    for ([_]?*Node{ arena.state.used_list, arena.state.free_list }) |first_node| {
        var it = first_node;
        while (it) |node| {
            it = node.next;
            arena.child_allocator.rawFree(node.allocatedSliceUnsafe(), .of(Node), @returnAddress());
        }
    }
}

pub fn queryCapacity(arena: ArenaAllocator) usize {
    return countListCapacity(arena.state.used_list) + countListCapacity(arena.state.free_list);
}

/// Ensure the arena owns at least `capacity` bytes of reusable allocation
/// space. Call before concurrent allocations begin.
pub fn preheat(arena: *ArenaAllocator, capacity: usize) bool {
    var current_capacity = arena.queryCapacity();
    while (current_capacity < capacity) {
        const additional = capacity - current_capacity;
        const size = mem.alignForward(usize, @sizeOf(Node) + additional, 2);
        const ptr = arena.child_allocator.rawAlloc(size, .of(Node), @returnAddress()) orelse return false;
        const node: *Node = @ptrCast(@alignCast(ptr));
        node.* = .{
            .size = .fromInt(size),
            .end_index = 0,
            .next = arena.loadFirstNode(),
        };
        while (true) {
            switch (arena.tryPushNode(node)) {
                .success => break,
                .failure => |old_first_node| node.next = old_first_node,
            }
        }
        current_capacity += size - @sizeOf(Node);
    }
    return true;
}

fn countListCapacity(first_node: ?*Node) usize {
    var capacity: usize = 0;
    var it = first_node;
    while (it) |node| : (it = node.next) capacity += node.size.toInt() - @sizeOf(Node);
    return capacity;
}

pub const ResetMode = union(enum) {
    free_all,
    retain_capacity,
    retain_with_limit: usize,
};

pub fn reset(arena: *ArenaAllocator, mode: ResetMode) bool {
    const limit: ?usize = switch (mode) {
        .retain_capacity => null,
        .retain_with_limit => |n| n,
        .free_all => 0,
    };
    if (limit == 0) {
        arena.deinit();
        arena.state = .init;
        return true;
    }

    const used_capacity = countListCapacity(arena.state.used_list);
    const free_capacity = countListCapacity(arena.state.free_list);
    const new_used_capacity = if (limit) |n| @min(n, used_capacity) else used_capacity;
    const new_free_capacity = if (limit) |n| @min(n - new_used_capacity, free_capacity) else free_capacity;
    var ok = true;

    for (
        [_]*?*Node{ &arena.state.used_list, &arena.state.free_list },
        [_]usize{ new_used_capacity, new_free_capacity },
    ) |first_node_ptr, new_capacity| {
        var it = first_node_ptr.*;
        const node: *Node = while (it) |node| {
            it = node.next;
            if (it == null) break node;
            arena.child_allocator.rawFree(node.allocatedSliceUnsafe(), .of(Node), @returnAddress());
        } else continue;

        const allocated_slice = node.allocatedSliceUnsafe();
        const new_size = mem.alignBackward(usize, @sizeOf(Node) + new_capacity, 2);
        if (new_size == @sizeOf(Node)) {
            arena.child_allocator.rawFree(allocated_slice, .of(Node), @returnAddress());
            first_node_ptr.* = null;
            continue;
        }

        node.end_index = 0;
        first_node_ptr.* = node;
        if (allocated_slice.len == new_size) continue;
        if (arena.child_allocator.rawResize(allocated_slice, .of(Node), new_size, @returnAddress())) {
            node.size = .fromInt(new_size);
        } else {
            const ptr = arena.child_allocator.rawAlloc(new_size, .of(Node), @returnAddress()) orelse {
                ok = false;
                continue;
            };
            arena.child_allocator.rawFree(allocated_slice, .of(Node), @returnAddress());
            const new_node: *Node = @ptrCast(@alignCast(ptr));
            new_node.* = .{ .size = .fromInt(new_size), .end_index = 0, .next = null };
            first_node_ptr.* = new_node;
        }
    }
    return ok;
}

const Node = struct {
    size: Size,
    end_index: usize,
    next: ?*Node,

    const Size = packed struct(usize) {
        resizing: bool,
        _: std.meta.Int(.unsigned, @bitSizeOf(usize) - 1) = 0,

        fn fromInt(n: usize) Size {
            assert(n >= @sizeOf(Node));
            const result: Size = @bitCast(n);
            assert(!result.resizing);
            return result;
        }

        fn toInt(size: Size) usize {
            var result = size;
            result.resizing = false;
            return @bitCast(result);
        }

        comptime {
            assert(Size{ .resizing = true } == @as(Size, @bitCast(@as(usize, 1))));
        }
    };

    fn loadBuf(node: *Node) []u8 {
        const size = @atomicLoad(Size, &node.size, .monotonic);
        return @as([*]u8, @ptrCast(node))[0..size.toInt()][@sizeOf(Node)..];
    }

    fn beginResize(node: *Node) ?[]u8 {
        const size = @atomicRmw(Size, &node.size, .Or, .{ .resizing = true }, .acquire);
        if (size.resizing) return null;
        return @as([*]u8, @ptrCast(node))[0..size.toInt()];
    }

    fn endResize(node: *Node, size: usize, prev_size: usize) void {
        assert(size >= prev_size);
        assert(@atomicLoad(Size, &node.size, .unordered).toInt() == prev_size);
        @atomicStore(Size, &node.size, .fromInt(size), .release);
    }

    fn allocatedSliceUnsafe(node: *Node) []u8 {
        return @as([*]u8, @ptrCast(node))[0..node.size.toInt()];
    }
};

fn loadFirstNode(arena: *ArenaAllocator) ?*Node {
    return @atomicLoad(?*Node, &arena.state.used_list, .acquire);
}

const PushResult = union(enum) { success, failure: ?*Node };

fn tryPushNode(arena: *ArenaAllocator, node: *Node) PushResult {
    assert(node != node.next);
    if (@cmpxchgStrong(?*Node, &arena.state.used_list, node.next, node, .release, .acquire)) |old| {
        return .{ .failure = old };
    }
    return .success;
}

fn stealFreeList(arena: *ArenaAllocator) ?*Node {
    return @atomicRmw(?*Node, &arena.state.free_list, .Xchg, null, .acquire);
}

fn pushFreeList(arena: *ArenaAllocator, first: *Node, last: *Node) void {
    assert(first != last.next and first != first.next and last != last.next);
    while (@cmpxchgWeak(?*Node, &arena.state.free_list, last.next, first, .release, .monotonic)) |old| {
        last.next = old;
    }
}

fn alignedIndex(buf_ptr: [*]u8, end_index: usize, alignment: Alignment) usize {
    return alignment.forward(@intFromPtr(buf_ptr) +% end_index) -% @intFromPtr(buf_ptr);
}

fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const arena: *ArenaAllocator = @ptrCast(@alignCast(ctx));
    _ = ret_addr;
    assert(n > 0);

    var cur_first_node = arena.loadFirstNode();
    var cur_new_node: ?*Node = null;
    defer if (cur_new_node) |node| {
        node.next = null;
        arena.pushFreeList(node, node);
    };

    retry: while (true) {
        const first_node: ?*Node, const prev_size: usize = first_node: {
            const node = cur_first_node orelse break :first_node .{ null, 0 };
            const buf = node.loadBuf();
            const alignable = n + alignment.toByteUnits() - 1;
            const end_index = @atomicRmw(usize, &node.end_index, .Add, alignable, .acquire);
            const index = alignedIndex(buf.ptr, end_index, alignment);
            assert(end_index + alignable >= index + n);
            if (end_index + alignable != index + n) {
                _ = @cmpxchgStrong(usize, &node.end_index, end_index + alignable, index + n, .monotonic, .monotonic);
            }
            if (index + n > buf.len) break :first_node .{ node, buf.len };
            return buf[index..][0..n].ptr;
        };

        resize_chunk: {
            const node = first_node orelse break :resize_chunk;
            const allocated = node.beginResize() orelse break :resize_chunk;
            var size = allocated.len;
            defer node.endResize(size, allocated.len);
            const buf = allocated[@sizeOf(Node)..];
            const end_index = @atomicLoad(usize, &node.end_index, .monotonic);
            const index = alignedIndex(buf.ptr, end_index, alignment);
            const new_size = mem.alignForward(usize, @sizeOf(Node) + index + n, 2);
            if (new_size <= allocated.len) continue :retry;
            if (arena.child_allocator.rawResize(allocated, .of(Node), new_size, @returnAddress())) {
                size = new_size;
                if (null == @cmpxchgStrong(usize, &node.end_index, end_index, index + n, .acquire, .monotonic)) {
                    return allocated.ptr[0..new_size][@sizeOf(Node) + index ..][0..n].ptr;
                }
            }
        }

        free_list: {
            const free_list = arena.stealFreeList() orelse break :free_list;
            const first_free: *Node, const last_free: *Node, const node: *Node, const prev: ?*Node = find: {
                var best_prev: ?*Node = null;
                var best: ?*Node = null;
                var best_diff: usize = std.math.maxInt(usize);
                var prev_it: ?*Node = null;
                var it: ?*Node = free_list;
                while (it) |candidate| : ({
                    prev_it = candidate;
                    it = candidate.next;
                }) {
                    assert(!candidate.size.resizing);
                    const buf = candidate.allocatedSliceUnsafe()[@sizeOf(Node)..];
                    const index = alignedIndex(buf.ptr, 0, alignment);
                    const diff = index + n -| buf.len;
                    if (diff < best_diff) {
                        best_prev = prev_it;
                        best = candidate;
                        best_diff = diff;
                    }
                }
                break :find .{ free_list, prev_it.?, best.?, best_prev };
            };

            const index, const need_resize = blk: {
                const buf = node.allocatedSliceUnsafe()[@sizeOf(Node)..];
                const aligned = alignedIndex(buf.ptr, 0, alignment);
                break :blk .{ aligned, aligned + n > buf.len };
            };
            if (need_resize) {
                const new_size = mem.alignForward(usize, @sizeOf(Node) + index + n, 2);
                if (arena.child_allocator.rawResize(node.allocatedSliceUnsafe(), .of(Node), new_size, @returnAddress())) {
                    node.size = .fromInt(new_size);
                } else {
                    arena.pushFreeList(first_free, last_free);
                    break :free_list;
                }
            }

            const buf = node.allocatedSliceUnsafe()[@sizeOf(Node)..];
            const old_next = node.next;
            node.end_index = index + n;
            node.next = first_node;
            switch (arena.tryPushNode(node)) {
                .success => {
                    if (prev) |p| p.next = old_next;
                    const new_first = if (node == first_free) old_next else first_free;
                    const new_last = if (node == last_free) prev else last_free;
                    if (new_first) |first| arena.pushFreeList(first, new_last.?);
                    return buf[index..][0..n].ptr;
                },
                .failure => |old_first| {
                    node.next = old_next;
                    arena.pushFreeList(first_free, last_free);
                    cur_first_node = old_first;
                    continue :retry;
                },
            }
        }

        const new_node: *Node = if (cur_new_node) |node| node else blk: {
            @branchHint(.cold);
            const min_size = @sizeOf(Node) + alignment.toByteUnits() + n;
            const big_size = prev_size + min_size + 16;
            const size = mem.alignForward(usize, big_size + big_size / 2, 2);
            const ptr = arena.child_allocator.rawAlloc(size, .of(Node), @returnAddress()) orelse return null;
            const node: *Node = @ptrCast(@alignCast(ptr));
            node.* = .{ .size = .fromInt(size), .end_index = undefined, .next = undefined };
            cur_new_node = node;
            break :blk node;
        };
        const buf = new_node.allocatedSliceUnsafe()[@sizeOf(Node)..];
        const index = alignedIndex(buf.ptr, 0, alignment);
        assert(new_node.size.toInt() >= @sizeOf(Node) + index + n);
        new_node.end_index = index + n;
        new_node.next = first_node;
        switch (arena.tryPushNode(new_node)) {
            .success => {
                cur_new_node = null;
                return buf[index..][0..n].ptr;
            },
            .failure => |old_first| cur_first_node = old_first,
        }
    }
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const arena: *ArenaAllocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;
    assert(memory.len > 0 and new_len > 0);
    const node = arena.loadFirstNode() orelse return false;
    const buf_ptr = @as([*]u8, @ptrCast(node)) + @sizeOf(Node);
    const end = @atomicLoad(usize, &node.end_index, .monotonic);
    if (buf_ptr + end != memory.ptr + memory.len) return new_len <= memory.len;
    if (new_len <= memory.len) {
        const new_end = end - (memory.len - new_len);
        assert(buf_ptr + new_end == memory.ptr + new_len);
        _ = @cmpxchgStrong(usize, &node.end_index, end, new_end, .release, .monotonic);
        return true;
    }
    if (node.loadBuf().len -| end >= new_len - memory.len) {
        const new_end = end + (new_len - memory.len);
        assert(buf_ptr + new_end == memory.ptr + new_len);
        return null == @cmpxchgStrong(usize, &node.end_index, end, new_end, .acquire, .monotonic);
    }
    return false;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const arena: *ArenaAllocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;
    assert(memory.len > 0);
    const node = arena.loadFirstNode() orelse return;
    const buf_ptr = @as([*]u8, @ptrCast(node)) + @sizeOf(Node);
    const end = @atomicLoad(usize, &node.end_index, .monotonic);
    if (buf_ptr + end != memory.ptr + memory.len) return;
    const new_end = end - memory.len;
    assert(buf_ptr + new_end == memory.ptr);
    _ = @cmpxchgStrong(usize, &node.end_index, end, new_end, .release, .monotonic);
}
