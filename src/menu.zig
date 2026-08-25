const std = @import("std");
const c = @import("c.zig");
const browsers = @import("browsers.zig");
const config_mod = @import("config.zig");
const launch = @import("launch.zig");
const terminal_mod = @import("terminal.zig");
const url = @import("url.zig");

const Allocator = std.mem.Allocator;

const window_class = "browserselect";
const menu_class = "browserselect-menu";
const url_class = "browserselect-url";
const number_class = "browserselect-number";

const max_numbered = 9;
const row_spacing = 10;
const max_name_chars = 40;

const css =
    \\window.browserselect > .browserselect-menu {
    \\  border: 1px solid alpha(currentColor, 0.15);
    \\  padding: 6px;
    \\}
    \\.browserselect-menu list {
    \\  background: transparent;
    \\}
    \\.browserselect-menu row {
    \\  border-radius: 6px;
    \\  padding: 6px 10px;
    \\}
    \\.browserselect-url {
    \\  font-size: 0.9em;
    \\  opacity: 0.55;
    \\  padding: 2px 10px 6px 10px;
    \\}
    \\.browserselect-number {
    \\  opacity: 0.45;
    \\}
;

pub const Menu = struct {
    gpa: Allocator,
    app: *c.GtkApplication,
    settings: config_mod.Config.Menu,
    entries: []const browsers.Entry,
    terminal: ?terminal_mod.Terminal,
    uri: ?[:0]const u8,
    window: ?*c.GtkWindow = null,
    list: ?*c.GtkListBox = null,
    was_active: bool = false,
    launched: bool = false,
    closing: bool = false,

    pub fn present(self: *Menu) void {
        applyStyle();

        const window = c.cast(c.GtkWindow, c.gtk_application_window_new(self.app));
        c.gtk_window_set_title(window, "Browser Select");
        c.gtk_window_set_decorated(window, c.FALSE);
        c.gtk_window_set_resizable(window, c.FALSE);
        c.gtk_widget_add_css_class(c.cast(c.GtkWidget, window), window_class);

        const box = c.gtk_box_new(.vertical, 0);
        c.gtk_widget_add_css_class(box, menu_class);
        c.gtk_widget_set_size_request(box, size(self.settings.width), -1);

        if (self.settings.show_url) {
            if (self.uri) |address| c.gtk_box_append(c.cast(c.GtkBox, box), urlLine(address));
        }

        const list = c.cast(c.GtkListBox, c.gtk_list_box_new());
        c.gtk_list_box_set_selection_mode(list, .browse);
        for (self.entries, 0..) |entry, index| {
            c.gtk_list_box_append(list, self.row(entry, index));
        }

        const view = c.cast(c.GtkScrolledWindow, c.gtk_scrolled_window_new());
        c.gtk_scrolled_window_set_child(view, c.cast(c.GtkWidget, list));
        c.gtk_scrolled_window_set_policy(view, .never, .automatic);
        c.gtk_scrolled_window_set_propagate_natural_height(view, c.TRUE);
        c.gtk_scrolled_window_set_max_content_height(view, size(self.settings.max_height));
        c.gtk_box_append(c.cast(c.GtkBox, box), c.cast(c.GtkWidget, view));

        c.gtk_window_set_child(window, box);

        const keys = c.gtk_event_controller_key_new();
        c.gtk_widget_add_controller(c.cast(c.GtkWidget, window), keys);

        _ = c.connect(keys, "key-pressed", &onKeyPressed, self);
        _ = c.connect(list, "row-activated", &onRowActivated, self);
        _ = c.connect(window, "notify::is-active", &onActiveChanged, self);

        self.window = window;
        self.list = list;

        c.gtk_list_box_select_row(list, c.gtk_list_box_get_row_at_index(list, 0));
        c.gtk_window_present(window);
    }

    fn urlLine(uri: [:0]const u8) *c.GtkWidget {
        const label = c.cast(c.GtkLabel, c.gtk_label_new(url.display(uri).ptr));
        c.gtk_label_set_xalign(label, 0);
        c.gtk_label_set_ellipsize(label, .middle);
        c.gtk_label_set_max_width_chars(label, 1);
        c.gtk_widget_add_css_class(c.cast(c.GtkWidget, label), url_class);
        c.gtk_widget_set_hexpand(c.cast(c.GtkWidget, label), c.TRUE);
        return c.cast(c.GtkWidget, label);
    }

    fn row(self: *Menu, entry: browsers.Entry, index: usize) *c.GtkWidget {
        const box = c.gtk_box_new(.horizontal, row_spacing);

        const image = c.cast(c.GtkImage, c.gtk_image_new());
        c.gtk_image_set_pixel_size(image, size(self.settings.icon_size));
        switch (entry.icon) {
            .gicon => |icon| c.gtk_image_set_from_gicon(image, icon),
            .name => |name| c.gtk_image_set_from_icon_name(image, name.ptr),
        }
        c.gtk_box_append(c.cast(c.GtkBox, box), c.cast(c.GtkWidget, image));

        const label = c.cast(c.GtkLabel, c.gtk_label_new(entry.name.ptr));
        c.gtk_label_set_xalign(label, 0);
        c.gtk_label_set_ellipsize(label, .end);
        c.gtk_label_set_max_width_chars(label, max_name_chars);
        c.gtk_widget_set_hexpand(c.cast(c.GtkWidget, label), c.TRUE);
        c.gtk_box_append(c.cast(c.GtkBox, box), c.cast(c.GtkWidget, label));

        if (self.settings.show_numbers and index < max_numbered) {
            var buffer: [4]u8 = undefined;
            const text = std.fmt.bufPrintZ(&buffer, "{d}", .{index + 1}) catch return box;
            const number = c.cast(c.GtkLabel, c.gtk_label_new(text.ptr));
            c.gtk_widget_add_css_class(c.cast(c.GtkWidget, number), number_class);
            c.gtk_box_append(c.cast(c.GtkBox, box), c.cast(c.GtkWidget, number));
        }

        return box;
    }

    fn activate(self: *Menu, index: usize) void {
        if (self.closing or index >= self.entries.len) return;
        const started = launch.open(self.gpa, self.entries[index], self.uri, self.terminal);
        self.finish(started);
    }

    fn finish(self: *Menu, launched: bool) void {
        if (self.closing) return;
        self.closing = true;
        self.launched = launched;
        if (self.window) |window| {
            self.window = null;
            c.gtk_window_destroy(window);
        }
        c.g_application_quit(c.cast(c.GApplication, self.app));
    }
};

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, data: c.gpointer) callconv(.c) void {
    const self: *Menu = @ptrCast(@alignCast(data.?));
    const index = c.gtk_list_box_row_get_index(row);
    if (index < 0) return;
    self.activate(@intCast(index));
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    _: c.GdkModifierType,
    data: c.gpointer,
) callconv(.c) c.gboolean {
    const self: *Menu = @ptrCast(@alignCast(data.?));

    if (keyval == c.key_Escape) {
        self.finish(false);
        return c.TRUE;
    }

    const digit = digitOf(keyval) orelse return c.FALSE;
    if (digit > self.entries.len) return c.FALSE;
    self.activate(digit - 1);
    return c.TRUE;
}

fn onActiveChanged(window: *c.GtkWindow, _: *c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const self: *Menu = @ptrCast(@alignCast(data.?));

    // is-active is notified on the way in as well, so closing on every
    // inactive notification would kill the window before it is ever shown.
    if (c.gtk_window_is_active(window) != c.FALSE) {
        self.was_active = true;
        return;
    }
    if (self.was_active) self.finish(false);
}

fn digitOf(keyval: c.guint) ?usize {
    if (keyval >= c.key_1 and keyval <= c.key_9) return keyval - c.key_1 + 1;
    if (keyval >= c.key_KP_1 and keyval <= c.key_KP_9) return keyval - c.key_KP_1 + 1;
    return null;
}

fn applyStyle() void {
    const display = c.gdk_display_get_default() orelse return;

    const provider = c.gtk_css_provider_new();
    defer c.g_object_unref(provider);

    c.gtk_css_provider_load_from_string(provider, css);
    c.gtk_style_context_add_provider_for_display(
        display,
        c.cast(c.GtkStyleProvider, provider),
        c.style_provider_priority_application,
    );
}

fn size(value: i64) c_int {
    if (value < 1) return 1;
    return std.math.cast(c_int, value) orelse std.math.maxInt(c_int);
}

test digitOf {
    try std.testing.expectEqual(@as(?usize, 1), digitOf(c.key_1));
    try std.testing.expectEqual(@as(?usize, 9), digitOf(c.key_9));
    try std.testing.expectEqual(@as(?usize, 3), digitOf(c.key_KP_1 + 2));
    try std.testing.expectEqual(@as(?usize, null), digitOf(c.key_Escape));
    try std.testing.expectEqual(@as(?usize, null), digitOf('0'));
}

test size {
    try std.testing.expectEqual(@as(c_int, 320), size(320));
    try std.testing.expectEqual(@as(c_int, 1), size(1));
    try std.testing.expectEqual(@as(c_int, 1), size(0));
    try std.testing.expectEqual(@as(c_int, 1), size(-1));
    try std.testing.expectEqual(@as(c_int, 1), size(std.math.minInt(i64)));
    try std.testing.expectEqual(@as(c_int, std.math.maxInt(c_int)), size(std.math.maxInt(i64)));
}
