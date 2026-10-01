const std = @import("std");

const Allocator = std.mem.Allocator;

pub const box_width = 13;
pub const passes = 3;

const native = @import("builtin").cpu.arch.endian();

pub const Planes = struct {
    width: usize,
    height: usize,
    values: []f32,

    pub fn deinit(self: Planes, gpa: Allocator) void {
        gpa.free(self.values);
    }

    pub fn plane(self: Planes, channel: usize) []f32 {
        const size = self.width * self.height;
        return self.values[channel * size ..][0..size];
    }
};

pub fn shrink(
    gpa: Allocator,
    pixels: []const u8,
    width: usize,
    height: usize,
    stride: usize,
    factor: usize,
) Allocator.Error!Planes {
    const step = @max(factor, 1);
    const across = @max(width / step, 1);
    const down = @max(height / step, 1);
    const size = across * down;

    const values = try gpa.alloc(f32, size * 3);
    @memset(values, 0);
    const shrunk: Planes = .{ .width = across, .height = down, .values = values };

    const block_width = @min(step, width);
    const block_height = @min(step, height);
    const count: f32 = @floatFromInt(block_width * block_height);

    for (0..down) |row| {
        for (0..block_height) |inner| {
            const line = pixels[(row * step + inner) * stride ..];
            for (0..across) |column| {
                const at = row * across + column;
                for (0..block_width) |offset| {
                    const cell = line[(column * step + offset) * 4 ..][0..4];
                    const value = std.mem.readInt(u32, cell, native);
                    values[at] += @floatFromInt((value >> 16) & 0xff);
                    values[size + at] += @floatFromInt((value >> 8) & 0xff);
                    values[2 * size + at] += @floatFromInt(value & 0xff);
                }
            }
        }
    }

    for (values) |*value| value.* /= count;
    return shrunk;
}

pub fn blur(gpa: Allocator, planes: Planes) Allocator.Error!void {
    const longest = @max(planes.width, planes.height);
    const line = try gpa.alloc(f32, longest);
    defer gpa.free(line);
    const smoothed = try gpa.alloc(f32, longest);
    defer gpa.free(smoothed);

    for (0..3) |channel| {
        const values = planes.plane(channel);
        for (0..passes) |_| {
            for (0..planes.height) |row| {
                const across = values[row * planes.width ..][0..planes.width];
                smooth(across, smoothed[0..planes.width]);
            }
            for (0..planes.width) |column| {
                const down = line[0..planes.height];
                for (down, 0..) |*value, row| value.* = values[row * planes.width + column];
                smooth(down, smoothed[0..planes.height]);
                for (down, 0..) |value, row| values[row * planes.width + column] = value;
            }
        }
    }
}

fn smooth(values: []f32, scratch: []f32) void {
    const reach = box_width / 2;
    const last: isize = @intCast(values.len - 1);
    const clamped = struct {
        fn at(all: []const f32, index: isize, end: isize) f32 {
            return all[@intCast(std.math.clamp(index, 0, end))];
        }
    }.at;

    var sum: f32 = 0;
    var index: isize = -reach;
    while (index <= reach) : (index += 1) sum += clamped(values, index, last);

    for (scratch, 0..) |*out, position| {
        out.* = sum / box_width;
        const here: isize = @intCast(position);
        sum += clamped(values, here + reach + 1, last) - clamped(values, here - reach, last);
    }
    @memcpy(values, scratch);
}

pub fn pack(planes: Planes, out: []u8) void {
    const size = planes.width * planes.height;
    for (0..size) |at| {
        for (0..3) |channel| {
            const value = planes.values[channel * size + at];
            out[at * 3 + channel] = @intFromFloat(std.math.clamp(@round(value), 0, 255));
        }
    }
}

const testing = std.testing;

fn filled(pixels: []u32, value: u32) []const u8 {
    @memset(pixels, value);
    return std.mem.sliceAsBytes(pixels);
}

test "a flat image stays flat through the shrink and the blur" {
    var pixels: [32 * 24]u32 = undefined;
    const bytes = filled(&pixels, 0x00406080);

    const planes = try shrink(testing.allocator, bytes, 32, 24, 32 * 4, 4);
    defer planes.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 8), planes.width);
    try testing.expectEqual(@as(usize, 6), planes.height);

    try blur(testing.allocator, planes);

    var packed_bytes: [8 * 6 * 3]u8 = undefined;
    pack(planes, &packed_bytes);
    var at: usize = 0;
    while (at < packed_bytes.len) : (at += 3) {
        try testing.expectEqualSlices(u8, &.{ 0x40, 0x60, 0x80 }, packed_bytes[at..][0..3]);
    }
}

test "a shrink averages each block" {
    var pixels: [4 * 2]u32 = .{
        0x00ff0000, 0x00000000, 0x00ff00ff, 0x00ff00ff,
        0x00000000, 0x00ff0000, 0x00000000, 0x00000000,
    };
    const planes = try shrink(testing.allocator, std.mem.sliceAsBytes(&pixels), 4, 2, 16, 2);
    defer planes.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), planes.width);
    try testing.expectEqual(@as(usize, 1), planes.height);
    try testing.expectEqual(@as(f32, 127.5), planes.plane(0)[0]);
    try testing.expectEqual(@as(f32, 127.5), planes.plane(0)[1]);
    try testing.expectEqual(@as(f32, 0), planes.plane(1)[1]);
    try testing.expectEqual(@as(f32, 127.5), planes.plane(2)[1]);
}

test "a single bright pixel keeps its sum and spreads symmetrically" {
    const side = 64;
    const values = try testing.allocator.alloc(f32, side * side * 3);
    const planes: Planes = .{ .width = side, .height = side, .values = values };
    defer planes.deinit(testing.allocator);
    @memset(values, 0);

    const center = side / 2;
    planes.plane(0)[center * side + center] = 255;

    try blur(testing.allocator, planes);

    const red = planes.plane(0);
    var sum: f32 = 0;
    for (red) |value| sum += value;
    try testing.expectApproxEqAbs(@as(f32, 255), sum, 0.01);

    const reach = passes * (box_width / 2);
    for (1..reach + 1) |distance| {
        const right = red[center * side + center + distance];
        const left = red[center * side + center - distance];
        const below = red[(center + distance) * side + center];
        const above = red[(center - distance) * side + center];
        try testing.expectApproxEqAbs(right, left, 1e-5);
        try testing.expectApproxEqAbs(right, below, 1e-5);
        try testing.expectApproxEqAbs(right, above, 1e-5);
        try testing.expect(right > 0);
    }
    try testing.expectApproxEqAbs(@as(f32, 0), red[center * side + center + reach + 1], 1e-4);
    try testing.expectEqual(@as(f32, 0), planes.plane(1)[center * side + center]);
}
