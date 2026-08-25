const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const browsers = @import("browsers.zig");
const terminal_mod = @import("terminal.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.launch);

pub fn open(
    gpa: Allocator,
    entry: browsers.Entry,
    uri: ?[:0]const u8,
    terminal: ?terminal_mod.Terminal,
) bool {
    return switch (entry.action) {
        .app_info => |info| withAppInfo(info, uri),
        .command => |command| run(gpa, &.{}, command, uri, entry.name),
        .in_terminal => |command| {
            const found = terminal orelse {
                log.warn("no terminal is installed, so {s} cannot be started", .{entry.name});
                return false;
            };
            return run(gpa, found.argv, command, uri, entry.name);
        },
    };
}

fn expand(
    gpa: Allocator,
    prefix: []const [:0]const u8,
    command: []const [:0]const u8,
    uri: ?[:0]const u8,
) Allocator.Error![][:0]u8 {
    var parts: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (parts.items) |part| gpa.free(part);
        parts.deinit(gpa);
    }

    for (prefix) |part| try parts.append(gpa, try gpa.dupeZ(u8, part));

    for (command) |part| {
        if (std.mem.eql(u8, part, browsers.uri_placeholder)) {
            const address = uri orelse continue;
            try parts.append(gpa, try gpa.dupeZ(u8, address));
            continue;
        }
        try parts.append(gpa, try substitute(gpa, part, uri orelse ""));
    }

    return parts.toOwnedSlice(gpa);
}

fn substitute(gpa: Allocator, part: []const u8, uri: []const u8) Allocator.Error![:0]u8 {
    if (std.mem.indexOf(u8, part, browsers.uri_placeholder) == null) return gpa.dupeZ(u8, part);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var rest = part;
    while (std.mem.indexOf(u8, rest, browsers.uri_placeholder)) |at| {
        try out.appendSlice(gpa, rest[0..at]);
        try out.appendSlice(gpa, uri);
        rest = rest[at + browsers.uri_placeholder.len ..];
    }
    try out.appendSlice(gpa, rest);

    return out.toOwnedSliceSentinel(gpa, 0);
}

fn run(
    gpa: Allocator,
    prefix: []const [:0]const u8,
    command: []const [:0]const u8,
    uri: ?[:0]const u8,
    name: []const u8,
) bool {
    const parts = expand(gpa, prefix, command, uri) catch {
        log.warn("out of memory while starting {s}", .{name});
        return false;
    };
    defer {
        for (parts) |part| gpa.free(part);
        gpa.free(parts);
    }

    const argv = gpa.allocSentinel(?[*:0]const u8, parts.len, null) catch {
        log.warn("out of memory while starting {s}", .{name});
        return false;
    };
    defer gpa.free(argv);
    for (parts, 0..) |part, index| argv[index] = part.ptr;

    var err: ?*c.GError = null;
    const started = c.g_spawn_async(
        null,
        argv.ptr,
        null,
        c.spawn_search_path | c.spawn_stdout_to_dev_null | c.spawn_stderr_to_dev_null,
        detach,
        null,
        null,
        &err,
    ) != c.FALSE;

    if (!started) {
        defer if (err) |detail| c.g_error_free(detail);
        log.warn("cannot start {s}: {s}", .{ name, message(err) });
    }
    return started;
}

fn withAppInfo(info: *c.GAppInfo, uri: ?[:0]const u8) bool {
    var uris: ?*c.GList = null;
    if (uri) |address| uris = c.g_list_append(null, @constCast(@as(*const anyopaque, address.ptr)));
    defer if (uris) |node| c.g_list_free(node);

    const context = launchContext();
    defer if (context) |value| c.g_object_unref(value);

    var err: ?*c.GError = null;
    const opened = c.g_app_info_launch_uris(info, uris, @ptrCast(context), &err) != c.FALSE;

    if (!opened) {
        defer if (err) |detail| c.g_error_free(detail);
        const name = c.g_app_info_get_display_name(info) orelse "the chosen browser";
        log.warn("cannot start {s}: {s}", .{ name, message(err) });
    }
    return opened;
}

fn launchContext() ?*c.GdkAppLaunchContext {
    const display = c.gdk_display_get_default() orelse return null;
    return c.gdk_display_get_app_launch_context(display);
}

fn message(err: ?*c.GError) [*:0]const u8 {
    const detail = err orelse return "no detail";
    return detail.message orelse "no detail";
}

const detach: ?c.GSpawnChildSetupFunc = switch (builtin.os.tag) {
    .windows => null,
    else => &newSession,
};

// The browser has to keep running once we quit, hence the child is put in a
// session of its own instead of staying in our process group.
extern fn setsid() c_int;

fn newSession(_: c.gpointer) callconv(.c) void {
    _ = setsid();
}

fn expectArgv(expected: []const []const u8, actual: []const [:0]u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn free(gpa: Allocator, parts: [][:0]u8) void {
    for (parts) |part| gpa.free(part);
    gpa.free(parts);
}

test "the placeholder becomes the address" {
    const gpa = std.testing.allocator;

    const parts = try expand(gpa, &.{}, &.{ "w3m", "%u" }, "https://example.com");
    defer free(gpa, parts);

    try expectArgv(&.{ "w3m", "https://example.com" }, parts);
}

test "a terminal prefix comes first" {
    const gpa = std.testing.allocator;

    const parts = try expand(gpa, &.{ "ghostty", "-e" }, &.{ "lynx", "%u" }, "https://example.com");
    defer free(gpa, parts);

    try expectArgv(&.{ "ghostty", "-e", "lynx", "https://example.com" }, parts);
}

test "a bare placeholder is dropped without an address" {
    const gpa = std.testing.allocator;

    const parts = try expand(gpa, &.{}, &.{ "firefox", "--new-window", "%u" }, null);
    defer free(gpa, parts);

    try expectArgv(&.{ "firefox", "--new-window" }, parts);
}

test "a placeholder inside an argument is replaced" {
    const gpa = std.testing.allocator;

    const parts = try expand(gpa, &.{}, &.{ "sh", "-c", "curl -fsSL %u | less" }, "https://example.com");
    defer free(gpa, parts);

    try expectArgv(&.{ "sh", "-c", "curl -fsSL https://example.com | less" }, parts);
}

test "arguments without a placeholder are kept" {
    const gpa = std.testing.allocator;

    const parts = try expand(gpa, &.{}, &.{ "firefox", "--private-window" }, "https://example.com");
    defer free(gpa, parts);

    try expectArgv(&.{ "firefox", "--private-window" }, parts);
}
