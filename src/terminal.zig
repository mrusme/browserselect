const std = @import("std");
const c = @import("c.zig");

const Allocator = std.mem.Allocator;

pub const Terminal = struct {
    argv: [][:0]const u8,

    pub fn deinit(self: Terminal, gpa: Allocator) void {
        for (self.argv) |part| gpa.free(part);
        gpa.free(self.argv);
    }
};

const Known = struct {
    program: []const u8,
    prefix: []const []const u8,
};

const default_prefix: []const []const u8 = &.{"-e"};

const known = [_]Known{
    .{ .program = "ghostty", .prefix = &.{"-e"} },
    .{ .program = "kitty", .prefix = &.{} },
    .{ .program = "foot", .prefix = &.{} },
    .{ .program = "alacritty", .prefix = &.{"-e"} },
    .{ .program = "wezterm", .prefix = &.{ "start", "--" } },
    .{ .program = "ptyxis", .prefix = &.{"--"} },
    .{ .program = "kgx", .prefix = &.{"--"} },
    .{ .program = "gnome-terminal", .prefix = &.{"--"} },
    .{ .program = "konsole", .prefix = &.{"-e"} },
    .{ .program = "xfce4-terminal", .prefix = &.{"-x"} },
    .{ .program = "terminator", .prefix = &.{"-x"} },
    .{ .program = "tilix", .prefix = &.{"-e"} },
    .{ .program = "rio", .prefix = &.{"-e"} },
    .{ .program = "contour", .prefix = &.{ "execute", "--" } },
    .{ .program = "urxvt", .prefix = &.{"-e"} },
    .{ .program = "rxvt", .prefix = &.{"-e"} },
    .{ .program = "st", .prefix = &.{"-e"} },
    .{ .program = "uxterm", .prefix = &.{"-e"} },
    .{ .program = "xterm", .prefix = &.{"-e"} },
};

const launchers = [_]Known{
    .{ .program = "xdg-terminal-exec", .prefix = &.{} },
    .{ .program = "x-terminal-emulator", .prefix = &.{"-e"} },
};

pub fn resolve(
    gpa: Allocator,
    environ: *const std.process.Environ.Map,
    configured: []const []const u8,
) Allocator.Error!?Terminal {
    if (configured.len > 0) return try own(gpa, configured);

    if (environ.get("TERMINAL")) |name| {
        if (name.len > 0 and try c.installed(gpa, name)) return try make(gpa, name, prefixFor(name));
    }

    for (launchers) |launcher| {
        if (try c.installed(gpa, launcher.program)) return try make(gpa, launcher.program, launcher.prefix);
    }

    for (known) |candidate| {
        if (try c.installed(gpa, candidate.program)) return try make(gpa, candidate.program, candidate.prefix);
    }

    return null;
}

fn prefixFor(program: []const u8) []const []const u8 {
    const name = std.fs.path.basename(program);
    for (known) |candidate| {
        if (std.mem.eql(u8, candidate.program, name)) return candidate.prefix;
    }
    for (launchers) |launcher| {
        if (std.mem.eql(u8, launcher.program, name)) return launcher.prefix;
    }
    return default_prefix;
}

fn make(gpa: Allocator, program: []const u8, prefix: []const []const u8) Allocator.Error!Terminal {
    var argv: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (argv.items) |part| gpa.free(part);
        argv.deinit(gpa);
    }

    try argv.append(gpa, try gpa.dupeZ(u8, program));
    for (prefix) |part| try argv.append(gpa, try gpa.dupeZ(u8, part));

    return .{ .argv = try argv.toOwnedSlice(gpa) };
}

fn own(gpa: Allocator, configured: []const []const u8) Allocator.Error!Terminal {
    return try make(gpa, configured[0], configured[1..]);
}

test prefixFor {
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"-e"}), prefixFor("ghostty"));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{}), prefixFor("kitty"));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "start", "--" }), prefixFor("wezterm"));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"--"}), prefixFor("/usr/bin/gnome-terminal"));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{}), prefixFor("xdg-terminal-exec"));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"-e"}), prefixFor("some-unknown-terminal"));
}

test "the configured command is taken verbatim" {
    const gpa = std.testing.allocator;

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();

    const terminal = (try resolve(gpa, &environ, &.{ "kitty", "--hold", "-e" })).?;
    defer terminal.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), terminal.argv.len);
    try std.testing.expectEqualStrings("kitty", terminal.argv[0]);
    try std.testing.expectEqualStrings("--hold", terminal.argv[1]);
    try std.testing.expectEqualStrings("-e", terminal.argv[2]);
}
