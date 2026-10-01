const std = @import("std");
const Box = @import("box.zig").Box;

const Allocator = std.mem.Allocator;

const max_reply = 8 << 20;
const magic = "i3-ipc";
const header_len = magic.len + 8;

pub const Message = enum(u32) {
    get_outputs = 3,
    get_tree = 4,
};

pub const Output = struct {
    name: []const u8,
    rect: Box,
};

pub const Window = struct {
    pid: i32,
    rect: Box,
};

pub const Error = error{ Unreachable, Refused, Malformed, TooLarge } || Allocator.Error;

pub fn request(gpa: Allocator, io: std.Io, path: []const u8, kind: Message) Error![]u8 {
    const address = std.Io.net.UnixAddress.init(path) catch return error.Unreachable;

    const stream = address.connect(io) catch return error.Refused;
    defer stream.close(io);

    var head: [header_len]u8 = undefined;
    frame(&head, kind, 0);

    var sending: [header_len]u8 = undefined;
    var out = stream.writer(io, &sending);
    out.interface.writeAll(&head) catch return error.Refused;
    out.interface.flush() catch return error.Refused;

    var receiving: [header_len]u8 = undefined;
    var in = stream.reader(io, &receiving);

    var reply: [header_len]u8 = undefined;
    in.interface.readSliceAll(&reply) catch return error.Malformed;

    const header = parseHeader(&reply) orelse return error.Malformed;
    if (header.length > max_reply) return error.TooLarge;

    const body = try gpa.alloc(u8, header.length);
    errdefer gpa.free(body);

    in.interface.readSliceAll(body) catch return error.Malformed;
    return body;
}

pub fn focusedOutput(listed: std.json.Value) ?Output {
    const items = switch (listed) {
        .array => |array| array.items,
        else => return null,
    };

    for (items) |item| {
        const fields = switch (item) {
            .object => |object| object,
            else => continue,
        };
        if (!flag(fields, "focused")) continue;
        return .{ .name = text(fields, "name"), .rect = rectOf(fields) };
    }
    return null;
}

pub fn collect(arena: Allocator, node: std.json.Value, out: *std.ArrayList(Window)) Allocator.Error!void {
    const fields = switch (node) {
        .object => |object| object,
        else => return,
    };

    if (fields.get("pid")) |found| switch (found) {
        .integer => |pid| if (std.math.cast(i32, pid)) |own| {
            try out.append(arena, .{ .pid = own, .rect = rectOf(fields) });
        },
        else => {},
    };

    for ([_][]const u8{ "nodes", "floating_nodes" }) |branch| {
        const children = fields.get(branch) orelse continue;
        const items = switch (children) {
            .array => |array| array.items,
            else => continue,
        };
        for (items) |child| try collect(arena, child, out);
    }
}

pub fn rectOfPid(windows: []const Window, pid: i32) ?Box {
    for (windows) |window| {
        if (window.pid == pid and !window.rect.empty()) return window.rect;
    }
    return null;
}

fn rectOf(fields: std.json.ObjectMap) Box {
    const found = switch (fields.get("rect") orelse return .{ .x = 0, .y = 0, .width = 0, .height = 0 }) {
        .object => |object| object,
        else => return .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };

    return .{
        .x = number(found, "x"),
        .y = number(found, "y"),
        .width = number(found, "width"),
        .height = number(found, "height"),
    };
}

fn number(fields: std.json.ObjectMap, key: []const u8) i32 {
    return switch (fields.get(key) orelse return 0) {
        .integer => |value| std.math.cast(i32, value) orelse 0,
        else => 0,
    };
}

fn flag(fields: std.json.ObjectMap, key: []const u8) bool {
    return switch (fields.get(key) orelse return false) {
        .bool => |value| value,
        else => false,
    };
}

fn text(fields: std.json.ObjectMap, key: []const u8) []const u8 {
    return switch (fields.get(key) orelse return "") {
        .string => |value| value,
        else => "",
    };
}

fn frame(buffer: *[header_len]u8, kind: Message, length: u32) void {
    @memcpy(buffer[0..magic.len], magic);
    std.mem.writeInt(u32, buffer[magic.len..][0..4], length, .little);
    std.mem.writeInt(u32, buffer[magic.len + 4 ..][0..4], @intFromEnum(kind), .little);
}

const Header = struct {
    length: u32,
    kind: u32,
};

fn parseHeader(bytes: []const u8) ?Header {
    if (bytes.len < header_len) return null;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return null;

    return .{
        .length = std.mem.readInt(u32, bytes[magic.len..][0..4], .little),
        .kind = std.mem.readInt(u32, bytes[magic.len + 4 ..][0..4], .little),
    };
}

const testing = std.testing;

test "a request is framed the way sway expects" {
    var buffer: [header_len]u8 = undefined;
    frame(&buffer, .get_outputs, 0);

    try testing.expectEqualStrings("i3-ipc", buffer[0..6]);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buffer[6..10], .little));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, buffer[10..14], .little));

    const header = parseHeader(&buffer).?;
    try testing.expectEqual(@as(u32, 3), header.kind);

    buffer[0] = 'x';
    try testing.expectEqual(@as(?Header, null), parseHeader(&buffer));
    try testing.expectEqual(@as(?Header, null), parseHeader(buffer[0 .. header_len - 1]));
}

const outputs =
    \\[{"name":"DP-1","active":true,"focused":false,"rect":{"x":0,"y":0,"width":2560,"height":1440}},
    \\ {"name":"HEADLESS-1","active":true,"focused":true,"rect":{"x":2560,"y":0,"width":1920,"height":1080}}]
;

test "the focused output is the one sway marks" {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, outputs, .{});
    defer parsed.deinit();

    const found = focusedOutput(parsed.value).?;
    try testing.expectEqualStrings("HEADLESS-1", found.name);
    try testing.expectEqual(@as(i32, 2560), found.rect.x);
    try testing.expectEqual(@as(i32, 1920), found.rect.width);

    const none = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "[{\"name\":\"DP-1\",\"focused\":false}]",
        .{},
    );
    defer none.deinit();
    try testing.expectEqual(@as(?Output, null), focusedOutput(none.value));
}

const tree =
    \\{"type":"root","name":"root","nodes":[
    \\  {"type":"output","name":"HEADLESS-1","nodes":[
    \\    {"type":"workspace","name":"1","nodes":[
    \\      {"id":5,"type":"con","name":"Firefox","pid":131633,
    \\       "rect":{"x":0,"y":0,"width":640,"height":800}}
    \\    ],"floating_nodes":[
    \\      {"id":9,"type":"floating_con","name":"Browser Select","pid":901,
    \\       "rect":{"x":752,"y":400,"width":416,"height":279}}
    \\    ]}
    \\  ]}
    \\]}
;

test "a window is found by its pid, floating or not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), tree, .{});
    var found: std.ArrayList(Window) = .empty;
    try collect(arena.allocator(), parsed.value, &found);

    try testing.expectEqual(@as(usize, 2), found.items.len);

    const floating = rectOfPid(found.items, 901).?;
    try testing.expectEqual(@as(i32, 752), floating.x);
    try testing.expectEqual(@as(i32, 400), floating.y);
    try testing.expectEqual(@as(i32, 416), floating.width);

    try testing.expectEqual(@as(i32, 640), rectOfPid(found.items, 131633).?.width);
    try testing.expectEqual(@as(?Box, null), rectOfPid(found.items, 4242));
}
