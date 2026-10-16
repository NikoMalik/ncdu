const std = @import("std");

const upper_table: [256]u8 = blk: {
    var table: [256]u8 = undefined;
    for (0..256) |i| {
        table[i] = if (i >= 'a' and i <= 'z') @intCast(i - 32) else @intCast(i);
    }
    break :blk table;
};

pub inline fn toUpper(c: u8) u8 {
    return upper_table[c];
}

const lower_table: [256]u8 = blk: {
    var table: [256]u8 = undefined;
    for (0..256) |i| {
        table[i] = if (i >= 'A' and i <= 'Z') @intCast(i + 32) else @intCast(i);
    }
    break :blk table;
};

pub inline fn toLower(c: u8) u8 {
    return lower_table[c];
}
