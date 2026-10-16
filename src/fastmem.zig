const std = @import("std");
const builtin = @import("builtin");

/// Same as @memmove but prefers libc memmove if it is
/// available because it is generally much faster?.
pub inline fn move(comptime T: type, dest: []T, source: []const T) void {
    if (builtin.link_libc) {
        _ = memmove(dest.ptr, source.ptr, source.len * @sizeOf(T));
    } else {
        @memmove(dest, source);
    }
}

/// Same as @memcpy but prefers libc memcpy if it is available
/// because it is generally much faster.
pub inline fn copy(comptime T: type, dest: []T, source: []const T) void {
    // Avoid a libc call for the short strings common during directory scans.
    if (source.len < 64 or !builtin.link_libc) {
        @memcpy(dest[0..source.len], source);
    } else {
        _ = memcpy(dest.ptr, source.ptr, source.len * @sizeOf(T));
    }
}

extern "c" fn memcpy(*anyopaque, *const anyopaque, usize) *anyopaque;
extern "c" fn memmove(*anyopaque, *const anyopaque, usize) *anyopaque;

pub const assert = switch (builtin.mode) {
    .Debug => std.debug.assert,

    .ReleaseSmall, .ReleaseSafe, .ReleaseFast => (struct {
        inline fn assert(ok: bool) void {
            if (!ok) {
                @branchHint(.cold);
                unreachable;
            }
        }
    }).assert,
};
