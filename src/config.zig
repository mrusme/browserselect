const std = @import("std");
const toml = @import("toml");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.config);

pub const Config = struct {
    menu: Menu = .{},
    terminal: Terminal = .{},
    browsers: Browsers = .{},

    pub const Menu = struct {
        width: i64 = 320,
        max_height: i64 = 420,
        icon_size: i64 = 20,
        show_url: bool = true,
        show_numbers: bool = true,
    };

    pub const Terminal = struct {
        command: []const []const u8 = &.{},
    };

    pub const Browsers = struct {
        hide: []const []const u8 = &.{},
        order: []const []const u8 = &.{},
        extra: []const Extra = &.{},
    };

    pub const Extra = struct {
        name: []const u8,
        command: []const []const u8,
        icon: []const u8 = "",
        terminal: bool = false,
    };
};

pub const Loaded = struct {
    value: Config,
    parsed: ?toml.Parsed(Config) = null,

    pub fn deinit(self: Loaded) void {
        if (self.parsed) |parsed| parsed.deinit();
    }
};

pub fn load(gpa: Allocator, io: std.Io, environ: *const std.process.Environ.Map) Loaded {
    const found = path(gpa, environ) catch return .{ .value = .{} };
    const file_path = found orelse return .{ .value = .{} };
    defer gpa.free(file_path);

    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{ .value = .{} },
        else => {
            log.warn("cannot read {s}: {t}", .{ file_path, err });
            return .{ .value = .{} };
        },
    };
    defer gpa.free(source);

    return parse(gpa, source, file_path);
}

fn parse(gpa: Allocator, source: []const u8, file_path: []const u8) Loaded {
    var parser: toml.Parser(Config) = .init(gpa);
    defer parser.deinit();

    const parsed = parser.parseString(source) catch |err| {
        report(&parser, file_path, err);
        return .{ .value = .{} };
    };
    return .{ .value = parsed.value, .parsed = parsed };
}

fn report(parser: *const toml.Parser(Config), file_path: []const u8, err: anyerror) void {
    const info = parser.error_info orelse {
        log.warn("cannot parse {s}: {t}, using the built-in defaults", .{ file_path, err });
        return;
    };
    switch (info) {
        .parse => |position| log.warn(
            "cannot parse {s} at line {d} column {d}: {t}, using the built-in defaults",
            .{ file_path, position.line, position.pos, err },
        ),
        .struct_mapping => |field_path| log.warn(
            "cannot read {f} in {s}: {t}, using the built-in defaults",
            .{ FieldPath{ .parts = field_path }, file_path, err },
        ),
    }
}

const FieldPath = struct {
    parts: []const []const u8,

    pub fn format(self: FieldPath, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.parts, 0..) |part, index| {
            if (index > 0) try writer.writeByte('.');
            try writer.writeAll(part);
        }
    }
};

fn path(gpa: Allocator, environ: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    if (environ.get("XDG_CONFIG_HOME")) |dir| {
        if (dir.len > 0) return try std.fs.path.join(gpa, &.{ dir, "browserselect", "config.toml" });
    }
    if (environ.get("HOME")) |home| {
        if (home.len > 0) return try std.fs.path.join(gpa, &.{ home, ".config", "browserselect", "config.toml" });
    }
    return null;
}

test "an empty file leaves the defaults alone" {
    const loaded = parse(std.testing.allocator, "", "test.toml");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(i64, 320), loaded.value.menu.width);
    try std.testing.expect(loaded.value.menu.show_url);
    try std.testing.expectEqual(@as(usize, 0), loaded.value.browsers.hide.len);
}

test "keys override the defaults" {
    const source =
        \\[menu]
        \\width = 480
        \\show_url = false
        \\
        \\[terminal]
        \\command = ["ghostty", "-e"]
        \\
        \\[browsers]
        \\hide = ["w3m"]
        \\order = ["firefox.desktop"]
        \\
        \\[[browsers.extra]]
        \\name = "Firefox, private"
        \\command = ["firefox", "--private-window", "%u"]
        \\icon = "firefox"
    ;

    const loaded = parse(std.testing.allocator, source, "test.toml");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(i64, 480), loaded.value.menu.width);
    try std.testing.expect(!loaded.value.menu.show_url);
    try std.testing.expectEqual(@as(i64, 420), loaded.value.menu.max_height);
    try std.testing.expectEqualStrings("ghostty", loaded.value.terminal.command[0]);
    try std.testing.expectEqualStrings("w3m", loaded.value.browsers.hide[0]);
    try std.testing.expectEqualStrings("firefox.desktop", loaded.value.browsers.order[0]);
    try std.testing.expectEqual(@as(usize, 1), loaded.value.browsers.extra.len);
    try std.testing.expectEqualStrings("Firefox, private", loaded.value.browsers.extra[0].name);
    try std.testing.expectEqual(@as(usize, 3), loaded.value.browsers.extra[0].command.len);
    try std.testing.expect(!loaded.value.browsers.extra[0].terminal);
}

test "a broken file falls back to the defaults" {
    const loaded = parse(std.testing.allocator, "[menu\nwidth =", "test.toml");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(i64, 320), loaded.value.menu.width);
}
