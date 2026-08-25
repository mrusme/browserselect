const std = @import("std");
const build_options = @import("build_options");
const c = @import("c.zig");
const browsers = @import("browsers.zig");
const config_mod = @import("config.zig");
const menu_mod = @import("menu.zig");
const terminal_mod = @import("terminal.zig");
const url = @import("url.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.browserselect);

const prgname = "browserselect";
const version = build_options.version;

const exclude: browsers.Exclude = .{
    .id = "browserselect.desktop",
    .program = prgname,
};

const usage =
    \\Usage: browserselect [options] [url]
    \\
    \\Lists the browsers installed on the system and opens the address in the
    \\one you pick. Register it as the default browser to get the list on every
    \\link. Without an address the picked browser is started on its own.
    \\
    \\Options:
    \\  -h, --help     Print this help and exit
    \\  -v, --version  Print the version and exit
    \\
    \\Keys:
    \\  Up, Down       Move through the list
    \\  1 to 9         Pick that entry
    \\  Return         Pick the selected entry
    \\  Escape         Close without opening anything
    \\
    \\Configuration is read from $XDG_CONFIG_HOME/browserselect/config.toml, or
    \\$HOME/.config/browserselect/config.toml when XDG_CONFIG_HOME is unset.
;

const State = struct {
    gpa: Allocator,
    settings: *const config_mod.Config,
    uri: ?[:0]const u8,
    terminal: ?terminal_mod.Terminal,
    list: ?browsers.List = null,
    menu: ?menu_mod.Menu = null,
};

pub fn main(init: std.process.Init) !u8 {
    c.g_set_prgname(prgname);

    const gpa = init.gpa;

    var uri: ?[:0]u8 = null;
    defer if (uri) |address| gpa.free(address);

    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try write(init.io, "{s}\n", .{usage});
            return 0;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try write(init.io, prgname ++ " " ++ version ++ "\n", .{});
            return 0;
        }
        if (uri != null) continue;
        uri = url.resolve(gpa, arg) catch |err| switch (err) {
            error.Invalid => {
                try write(init.io, "{s}: cannot read \"{s}\" as an address\n", .{ prgname, arg });
                return 2;
            },
            else => |leftover| return leftover,
        };
    }

    const loaded = config_mod.load(gpa, init.io, init.environ_map);
    defer loaded.deinit();

    const terminal = try terminal_mod.resolve(gpa, init.environ_map, loaded.value.terminal.command);
    defer if (terminal) |found| found.deinit(gpa);

    var state: State = .{
        .gpa = gpa,
        .settings = &loaded.value,
        .uri = uri,
        .terminal = terminal,
    };

    // Non-unique, because a second click on a link has to bring up its own
    // popup instead of being handed to the instance that is already running.
    const app = c.gtk_application_new(null, c.application_non_unique);
    _ = c.connect(app, "activate", &onActivate, &state);

    _ = c.g_application_run(c.cast(c.GApplication, app), 0, null);

    c.g_object_unref(app);
    if (state.list) |*list| list.deinit();

    const menu = state.menu orelse return 1;
    return if (menu.launched) 0 else 1;
}

fn onActivate(app: *c.GtkApplication, data: c.gpointer) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data.?));

    if (state.menu) |*menu| {
        if (menu.window) |window| c.gtk_window_present(window);
        return;
    }

    c.gtk_window_set_default_icon_name(prgname);

    var list = browsers.discover(
        state.gpa,
        state.settings.browsers,
        exclude,
        state.terminal != null,
    ) catch {
        log.err("out of memory while looking for browsers", .{});
        c.g_application_quit(c.cast(c.GApplication, app));
        return;
    };

    if (list.entries.items.len == 0) {
        list.deinit();
        log.err("no browser was found on this system", .{});
        c.g_application_quit(c.cast(c.GApplication, app));
        return;
    }

    state.list = list;
    state.menu = .{
        .gpa = state.gpa,
        .app = app,
        .settings = state.settings.menu,
        .entries = state.list.?.entries.items,
        .terminal = state.terminal,
        .uri = state.uri,
    };
    if (state.menu) |*menu| menu.present();
}

fn write(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.print(fmt, args);
    try out.interface.flush();
}

test {
    _ = @import("browsers.zig");
    _ = @import("config.zig");
    _ = @import("launch.zig");
    _ = @import("menu.zig");
    _ = @import("terminal.zig");
    _ = @import("url.zig");
}
