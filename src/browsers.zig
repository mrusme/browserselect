const std = @import("std");
const c = @import("c.zig");
const config_mod = @import("config.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.browsers);

pub const uri_placeholder = "%u";

const generic_names = [_][:0]const u8{ "web-browser", "internet-web-browser", "applications-internet" };
const terminal_names = [_][:0]const u8{ "utilities-terminal", "terminal", "applications-utilities" };

const Icons = struct {
    generic: [:0]const u8,
    terminal: [:0]const u8,

    pub fn resolve() Icons {
        return .{
            .generic = firstAvailable(&generic_names),
            .terminal = firstAvailable(&terminal_names),
        };
    }
};

pub const Icon = union(enum) {
    gicon: *c.GIcon,
    name: [:0]const u8,
};

pub const Action = union(enum) {
    app_info: *c.GAppInfo,
    command: []const [:0]const u8,
    in_terminal: []const [:0]const u8,
};

pub const Entry = struct {
    id: []const u8,
    name: [:0]const u8,
    icon: Icon,
    action: Action,

    fn release(self: Entry) void {
        switch (self.action) {
            .app_info => |info| c.g_object_unref(info),
            else => {},
        }
        switch (self.icon) {
            .gicon => |icon| c.g_object_unref(icon),
            else => {},
        }
    }

    pub fn matches(self: Entry, text: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.id, text) or std.ascii.eqlIgnoreCase(self.name, text);
    }
};

pub const List = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *List) void {
        for (self.entries.items) |entry| entry.release();
        self.entries.deinit(self.gpa);
        self.arena.deinit();
    }
};

const Program = struct {
    program: []const u8,
    label: []const u8,
};

const TextBrowser = struct {
    program: []const u8,
    label: []const u8,
    args: []const []const u8,
};

const graphical = [_]Program{
    .{ .program = "brave-browser", .label = "Brave" },
    .{ .program = "brave", .label = "Brave" },
    .{ .program = "chromium-browser", .label = "Chromium" },
    .{ .program = "chromium", .label = "Chromium" },
    .{ .program = "dillo", .label = "Dillo" },
    .{ .program = "epiphany", .label = "GNOME Web" },
    .{ .program = "falkon", .label = "Falkon" },
    .{ .program = "firefox-esr", .label = "Firefox ESR" },
    .{ .program = "firefox", .label = "Firefox" },
    .{ .program = "floorp", .label = "Floorp" },
    .{ .program = "google-chrome-stable", .label = "Google Chrome" },
    .{ .program = "google-chrome", .label = "Google Chrome" },
    .{ .program = "ladybird", .label = "Ladybird" },
    .{ .program = "librewolf", .label = "LibreWolf" },
    .{ .program = "luakit", .label = "Luakit" },
    .{ .program = "microsoft-edge", .label = "Microsoft Edge" },
    .{ .program = "midori", .label = "Midori" },
    .{ .program = "min", .label = "Min" },
    .{ .program = "netrunner", .label = "Netrunner" },
    .{ .program = "netsurf", .label = "NetSurf" },
    .{ .program = "nyxt", .label = "Nyxt" },
    .{ .program = "opera", .label = "Opera" },
    .{ .program = "otter-browser", .label = "Otter Browser" },
    .{ .program = "palemoon", .label = "Pale Moon" },
    .{ .program = "qutebrowser", .label = "qutebrowser" },
    .{ .program = "seamonkey", .label = "SeaMonkey" },
    .{ .program = "surf", .label = "surf" },
    .{ .program = "thorium-browser", .label = "Thorium" },
    .{ .program = "tor-browser", .label = "Tor Browser" },
    .{ .program = "ungoogled-chromium", .label = "Ungoogled Chromium" },
    .{ .program = "vimb", .label = "vimb" },
    .{ .program = "vivaldi-stable", .label = "Vivaldi" },
    .{ .program = "vivaldi", .label = "Vivaldi" },
    .{ .program = "waterfox", .label = "Waterfox" },
    .{ .program = "zen-browser", .label = "Zen Browser" },
    .{ .program = "zen", .label = "Zen Browser" },
};

const textual = [_]TextBrowser{
    .{ .program = "browsh", .label = "Browsh", .args = &.{ "--startup-url", uri_placeholder } },
    .{ .program = "carbonyl", .label = "Carbonyl", .args = &.{uri_placeholder} },
    .{ .program = "cha", .label = "Chawan", .args = &.{uri_placeholder} },
    .{ .program = "edbrowse", .label = "edbrowse", .args = &.{uri_placeholder} },
    .{ .program = "elinks", .label = "ELinks", .args = &.{uri_placeholder} },
    .{ .program = "links2", .label = "Links 2", .args = &.{uri_placeholder} },
    .{ .program = "links", .label = "Links", .args = &.{uri_placeholder} },
    .{ .program = "lynx", .label = "Lynx", .args = &.{uri_placeholder} },
    .{ .program = "w3m", .label = "w3m", .args = &.{uri_placeholder} },
};

const handled_types = [_][*:0]const u8{
    "x-scheme-handler/https",
    "x-scheme-handler/http",
};

pub const Exclude = struct {
    id: []const u8,
    program: []const u8,
};

pub fn discover(
    gpa: Allocator,
    settings: config_mod.Config.Browsers,
    exclude: Exclude,
    with_terminal: bool,
) Allocator.Error!List {
    var list: List = .{ .gpa = gpa, .arena = .init(gpa) };
    errdefer list.deinit();

    const arena = list.arena.allocator();
    const icons: Icons = .resolve();

    var programs: std.ArrayList([]const u8) = .empty;
    defer programs.deinit(gpa);

    try addDesktopEntries(gpa, arena, &list, &programs, exclude, icons);
    try addGraphical(gpa, arena, &list, &programs, icons);
    if (with_terminal) try addTextual(gpa, arena, &list, &programs, icons);
    try addExtras(gpa, arena, &list, settings.extra, icons);

    applyHide(&list, settings.hide);
    applyOrder(&list, settings.order);

    return list;
}

fn addDesktopEntries(
    gpa: Allocator,
    arena: Allocator,
    list: *List,
    programs: *std.ArrayList([]const u8),
    exclude: Exclude,
    icons: Icons,
) Allocator.Error!void {
    for (handled_types) |content_type| {
        const found = c.g_app_info_get_all_for_type(content_type) orelse continue;
        defer c.g_list_free_full(found, &c.g_object_unref);

        var node: ?*c.GList = found;
        while (node) |current| : (node = current.next) {
            const info: *c.GAppInfo = @ptrCast(current.data orelse continue);
            if (c.g_app_info_should_show(info) == c.FALSE) continue;

            const id = std.mem.span(c.g_app_info_get_id(info) orelse "");
            const name = std.mem.span(c.g_app_info_get_display_name(info) orelse
                c.g_app_info_get_name(info) orelse continue);
            const command = std.mem.span(c.g_app_info_get_executable(info) orelse "");
            const program = std.fs.path.basename(command);

            // We register as a browser ourselves and would otherwise show up
            // in our own list.
            if (std.mem.eql(u8, id, exclude.id)) continue;
            if (std.mem.eql(u8, program, exclude.program)) continue;
            if (contains(programs.items, id) or contains(programs.items, program)) continue;
            if (named(list.entries.items, name)) continue;

            const kept = try arena.dupeZ(u8, name);
            const identifier = if (id.len > 0) try arena.dupe(u8, id) else kept;
            try list.entries.ensureUnusedCapacity(gpa, 1);
            list.entries.appendAssumeCapacity(.{
                .id = identifier,
                .name = kept,
                .icon = iconOf(info, icons),
                .action = .{ .app_info = @ptrCast(c.g_object_ref(info)) },
            });

            if (id.len > 0) try programs.append(gpa, try arena.dupe(u8, id));
            if (program.len > 0) try programs.append(gpa, try arena.dupe(u8, program));
        }
    }
}

fn addGraphical(
    gpa: Allocator,
    arena: Allocator,
    list: *List,
    programs: *std.ArrayList([]const u8),
    icons: Icons,
) Allocator.Error!void {
    for (graphical) |candidate| {
        if (contains(programs.items, candidate.program)) continue;
        if (named(list.entries.items, candidate.label)) continue;
        if (!try c.installed(gpa, candidate.program)) continue;

        try list.entries.append(gpa, .{
            .id = try arena.dupe(u8, candidate.program),
            .name = try arena.dupeZ(u8, candidate.label),
            .icon = .{ .name = try themedIcon(arena, candidate.program, icons.generic) },
            .action = .{ .command = try argv(arena, candidate.program, &.{uri_placeholder}) },
        });
        try programs.append(gpa, try arena.dupe(u8, candidate.program));
    }
}

fn addTextual(
    gpa: Allocator,
    arena: Allocator,
    list: *List,
    programs: *std.ArrayList([]const u8),
    icons: Icons,
) Allocator.Error!void {
    for (textual) |candidate| {
        if (contains(programs.items, candidate.program)) continue;
        if (named(list.entries.items, candidate.label)) continue;
        if (!try c.installed(gpa, candidate.program)) continue;

        try list.entries.append(gpa, .{
            .id = try arena.dupe(u8, candidate.program),
            .name = try arena.dupeZ(u8, candidate.label),
            .icon = .{ .name = icons.terminal },
            .action = .{ .in_terminal = try argv(arena, candidate.program, candidate.args) },
        });
        try programs.append(gpa, try arena.dupe(u8, candidate.program));
    }
}

fn addExtras(
    gpa: Allocator,
    arena: Allocator,
    list: *List,
    extras: []const config_mod.Config.Extra,
    icons: Icons,
) Allocator.Error!void {
    for (extras) |extra| {
        if (extra.command.len == 0) {
            log.warn("browsers.extra \"{s}\" has an empty command and is left out", .{extra.name});
            continue;
        }

        const parts = try arena.alloc([:0]const u8, extra.command.len);
        for (extra.command, 0..) |part, index| parts[index] = try arena.dupeZ(u8, part);

        const fallback = if (extra.terminal) icons.terminal else icons.generic;
        const name = try arena.dupeZ(u8, extra.name);
        try list.entries.append(gpa, .{
            .id = name,
            .name = name,
            .icon = .{ .name = if (extra.icon.len > 0)
                try themedIcon(arena, extra.icon, fallback)
            else
                fallback },
            .action = if (extra.terminal) .{ .in_terminal = parts } else .{ .command = parts },
        });
    }
}

fn applyHide(list: *List, hide: []const []const u8) void {
    if (hide.len == 0) return;

    var kept: usize = 0;
    for (list.entries.items) |entry| {
        if (any(hide, entry)) {
            entry.release();
            continue;
        }
        list.entries.items[kept] = entry;
        kept += 1;
    }
    list.entries.shrinkRetainingCapacity(kept);
}

fn applyOrder(list: *List, order: []const []const u8) void {
    var placed: usize = 0;
    for (order) |wanted| {
        for (list.entries.items[placed..], placed..) |entry, index| {
            if (!entry.matches(wanted)) continue;
            std.mem.rotate(Entry, list.entries.items[placed .. index + 1], index - placed);
            placed += 1;
            break;
        }
    }
}

fn any(texts: []const []const u8, entry: Entry) bool {
    for (texts) |text| {
        if (entry.matches(text)) return true;
    }
    return false;
}

fn contains(texts: []const []const u8, text: []const u8) bool {
    if (text.len == 0) return false;
    for (texts) |known| {
        if (std.ascii.eqlIgnoreCase(known, text)) return true;
    }
    return false;
}

fn named(entries: []const Entry, name: []const u8) bool {
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return true;
    }
    return false;
}

fn iconOf(info: *c.GAppInfo, icons: Icons) Icon {
    const icon = c.g_app_info_get_icon(info) orelse return .{ .name = icons.generic };
    return .{ .gicon = @ptrCast(c.g_object_ref(icon)) };
}

fn themedIcon(arena: Allocator, wanted: []const u8, fallback: [:0]const u8) Allocator.Error![:0]const u8 {
    const theme = iconTheme() orelse return fallback;

    const name = try arena.dupeZ(u8, wanted);
    if (c.gtk_icon_theme_has_icon(theme, name.ptr) != c.FALSE) return name;
    return fallback;
}

fn firstAvailable(names: []const [:0]const u8) [:0]const u8 {
    const fallback = names[names.len - 1];
    const theme = iconTheme() orelse return fallback;
    for (names) |name| {
        if (c.gtk_icon_theme_has_icon(theme, name.ptr) != c.FALSE) return name;
    }
    return fallback;
}

fn iconTheme() ?*c.GtkIconTheme {
    const display = c.gdk_display_get_default() orelse return null;
    return c.gtk_icon_theme_get_for_display(display);
}

fn argv(arena: Allocator, program: []const u8, args: []const []const u8) Allocator.Error![]const [:0]const u8 {
    const parts = try arena.alloc([:0]const u8, args.len + 1);
    parts[0] = try arena.dupeZ(u8, program);
    for (args, 0..) |arg, index| parts[index + 1] = try arena.dupeZ(u8, arg);
    return parts;
}

fn testList(gpa: Allocator, names: []const [:0]const u8) Allocator.Error!List {
    var list: List = .{ .gpa = gpa, .arena = .init(gpa) };
    errdefer list.deinit();

    for (names) |name| {
        try list.entries.append(gpa, .{
            .id = name,
            .name = name,
            .icon = .{ .name = generic_names[0] },
            .action = .{ .command = &.{} },
        });
    }
    return list;
}

fn testNames(gpa: Allocator, list: List) Allocator.Error![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(gpa);

    for (list.entries.items, 0..) |entry, index| {
        if (index > 0) try joined.append(gpa, ' ');
        try joined.appendSlice(gpa, entry.name);
    }
    return joined.toOwnedSlice(gpa);
}

test applyHide {
    const gpa = std.testing.allocator;

    var list = try testList(gpa, &.{ "Firefox", "Chromium", "w3m" });
    defer list.deinit();

    applyHide(&list, &.{ "chromium", "Nothing" });

    const names = try testNames(gpa, list);
    defer gpa.free(names);
    try std.testing.expectEqualStrings("Firefox w3m", names);
}

test applyOrder {
    const gpa = std.testing.allocator;

    var list = try testList(gpa, &.{ "Firefox", "Chromium", "w3m", "Lynx" });
    defer list.deinit();

    applyOrder(&list, &.{ "w3m", "chromium", "Nothing" });

    const names = try testNames(gpa, list);
    defer gpa.free(names);
    try std.testing.expectEqualStrings("w3m Chromium Firefox Lynx", names);
}

test "an empty order leaves the list alone" {
    const gpa = std.testing.allocator;

    var list = try testList(gpa, &.{ "Firefox", "Chromium" });
    defer list.deinit();

    applyOrder(&list, &.{});

    const names = try testNames(gpa, list);
    defer gpa.free(names);
    try std.testing.expectEqualStrings("Firefox Chromium", names);
}
