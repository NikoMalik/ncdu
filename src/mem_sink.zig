// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const sink = @import("sink.zig");
const Mutex = @import("mutex.zig").AdaptiveMutex;
const _hash = @import("hash.zig");
const ThreadSafeArena = @import("threadsafe_arena.zig");
const SwissTable = @import("swiss_table.zig").SwissTable;

pub const global = struct {
    pub var root: ?*model.Dir = null;
    pub var stats: bool = true; // calculate aggregate directory stats
    // Shared backing arena. Each worker's local ArenaAllocator batches small
    // allocations into larger chunks allocated from this thread-safe arena.
    pub var arena: ThreadSafeArena = .init(std.heap.c_allocator);
};

pub const Thread = struct {
    // Entries allocated during a scan outlive the sink worker, so the chunks
    // are intentionally retained by the shared backing arena after this state
    // is discarded. Local bump allocations avoid a shared atomic operation for
    // every entry.
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(global.arena.allocator()),
};

pub fn statToEntry(stat: *const sink.Stat, e: *model.Entry, parent: *model.Dir) void {
    e.pack.blocks = stat.blocks;
    e.size = stat.size;
    if (e.dir()) |d| {
        d.parent = parent;
        d.pack.dev = model.devices.getId(stat.dev);
    }
    if (e.link()) |l| {
        l.parent = parent;
        l.ino = stat.ino;
        l.pack.nlink = stat.nlink;
        model.inodes.lock.lock();
        defer model.inodes.lock.unlock();
        l.addLink();
    }
    if (e.ext()) |ext| ext.* = stat.ext;
}

pub const Dir = struct {
    dir: *model.Dir,
    entries: Map,

    own_blocks: model.Blocks,
    own_bytes: u64,

    // Additional counts collected from subdirectories. Subdirs may run final()
    // from separate threads so these need to be protected.
    blocks: model.Blocks = 0,
    bytes: u64 = 0,
    items: u32 = 0,
    mtime: u64 = 0,
    suberr: bool = false,
    lock: Mutex = .{},

    const Map = SwissTable([]const u8, *model.Entry, 16, eqlName, hashName, entryName, 0.87, null);

    inline fn hashName(name: []const u8) u64 {
        return _hash.hash_inline(name, 0);
    }

    inline fn eqlName(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    inline fn entryName(e: *const *model.Entry) []const u8 {
        return e.*.name();
    }

    fn init(dir: *model.Dir) Dir {
        var count: usize = 0;
        var it = dir.sub.ptr;
        while (it) |e| : (it = e.next.ptr) count += 1;

        var self = Dir{
            .dir = dir,
            .entries = Map.init(main.allocator, count) catch unreachable,
            .own_blocks = dir.entry.pack.blocks,
            .own_bytes = dir.entry.size,
        };
        self.entries.ensureTotalCapacity(count) catch unreachable;
        self.entries.ensureUnusedCapacity(count) catch unreachable;

        it = dir.sub.ptr;
        while (it) |e| : (it = e.next.ptr)
            self.entries.putAssumeCapacity(e.name(), e);
        return self;
    }

    fn getEntry(self: *Dir, t: *Thread, etype: model.EType, isext: bool, name: []const u8) *model.Entry {
        if (self.entries.get(name)) |e| {
            // Reuse the allocation only when the new entry has a compatible layout.
            if (e.pack.etype.base() == etype.base() and (!isext or e.pack.isext)) {
                e.pack.etype = etype;
                e.pack.isext = isext;
                _ = self.entries.remove(name);
                return e;
            }
        }
        const e = model.Entry.create(t.arena.allocator(), etype, isext, name);
        e.next.ptr = self.dir.sub.ptr;
        self.dir.sub.ptr = e;
        return e;
    }

    pub fn addSpecial(self: *Dir, t: *Thread, name: []const u8, st: model.EType) void {
        self.dir.items += 1;
        if (st == .err) self.dir.pack.suberr = true;
        _ = self.getEntry(t, st, false, name);
    }

    pub fn addStat(self: *Dir, t: *Thread, name: []const u8, stat: *const sink.Stat) *model.Entry {
        if (global.stats) {
            self.dir.items +|= 1;
            if (stat.etype != .link) {
                self.dir.entry.pack.blocks +|= stat.blocks;
                self.dir.entry.size +|= stat.size;
            }
            if (self.dir.entry.ext()) |e| {
                if (stat.ext.mtime > e.mtime) e.mtime = stat.ext.mtime;
            }
        }

        const e = self.getEntry(t, stat.etype, main.config.extended and !stat.ext.isEmpty(), name);
        statToEntry(stat, e, self.dir);
        return e;
    }

    pub fn addDir(self: *Dir, t: *Thread, name: []const u8, stat: *const sink.Stat) Dir {
        return init(self.addStat(t, name, stat).dir().?);
    }

    pub fn setReadError(self: *Dir) void {
        self.dir.pack.err = true;
    }

    pub fn final(self: *Dir, parent: ?*Dir) void {
        // Remove entries we've not seen
        if (self.entries.count() > 0) {
            var it = &self.dir.sub.ptr;
            while (it.*) |e| {
                if (self.entries.get(e.name()) == e) it.* = e.next.ptr else it = &e.next.ptr;
            }
        }
        self.entries.deinit();

        if (!global.stats) return;

        // Grab counts collected from subdirectories
        self.dir.entry.pack.blocks +|= self.blocks;
        self.dir.entry.size +|= self.bytes;
        self.dir.items +|= self.items;
        if (self.suberr) self.dir.pack.suberr = true;
        if (self.dir.entry.ext()) |e| {
            if (self.mtime > e.mtime) e.mtime = self.mtime;
        }

        // Add own counts to parent
        if (parent) |p| {
            p.lock.lock();
            defer p.lock.unlock();
            p.blocks +|= self.dir.entry.pack.blocks - self.own_blocks;
            p.bytes +|= self.dir.entry.size - self.own_bytes;
            p.items +|= self.dir.items;
            if (self.dir.entry.ext()) |e| {
                if (e.mtime > p.mtime) p.mtime = e.mtime;
            }
            if (self.suberr or self.dir.pack.suberr or self.dir.pack.err) p.suberr = true;
        }
    }
};

pub fn createRoot(path: []const u8, stat: *const sink.Stat) Dir {
    const p = global.root orelse blk: {
        model.root = model.Entry.create(main.allocator, .dir, main.config.extended and !stat.ext.isEmpty(), path).dir().?;
        break :blk model.root;
    };
    sink.global.state = .zeroing;
    if (p.items > 10_000) main.handleEvent(false, true);
    // Do the zeroStats() here, after the "root" entry has been
    // stat'ed and opened, so that a fatal error on refresh won't
    // zero-out the requested directory.
    p.entry.zeroStats(p.parent);
    sink.global.state = .running;
    p.entry.pack.blocks = stat.blocks;
    p.entry.size = stat.size;
    p.pack.dev = model.devices.getId(stat.dev);
    if (p.entry.ext()) |e| e.* = stat.ext;
    return Dir.init(p);
}

pub fn done() void {
    if (!global.stats) return;

    sink.global.state = .hlcnt;
    main.handleEvent(false, true);
    const dir = global.root orelse model.root;
    var it: ?*model.Dir = dir;
    while (it) |p| : (it = p.parent) {
        p.updateSubErr();
        if (p != dir) {
            p.entry.pack.blocks +|= dir.entry.pack.blocks;
            p.entry.size +|= dir.entry.size;
            p.items +|= dir.items + 1;
        }
    }
    model.inodes.addAllStats();
}
