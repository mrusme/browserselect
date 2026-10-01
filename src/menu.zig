const std = @import("std");
const c = @import("c.zig");
const backdrop_mod = @import("backdrop.zig");
const blur_mod = @import("blur.zig");
const browsers = @import("browsers.zig");
const config_mod = @import("config.zig");
const launch = @import("launch.zig");
const terminal_mod = @import("terminal.zig");
const url = @import("url.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.menu);

const window_class = "browserselect";
const panel_class = "browserselect-panel";
const tint_class = "browserselect-tint";
const theme_class = "background";
const menu_class = "browserselect-menu";
const url_class = "browserselect-url";
const number_class = "browserselect-number";

const border = 1;
const radius = 14;
const plain_opacity = 0.95;
const blurred_opacity = 0.74;
// At 0 GTK 4.12 attaches no buffer, hence sway never maps the window to place.
const waiting_opacity = 0.01;
const placing_tries = 10;
const placing_interval_ms = 10;
const max_numbered = 9;
const row_spacing = 10;
const max_name_chars = 40;

const css =
    \\window.browserselect {
    \\  background: transparent;
    \\}
    \\.browserselect-panel {
    \\  margin: 28px 48px 64px 48px;
    \\  border: 1px solid alpha(currentColor, 0.16);
    \\
++ std.fmt.comptimePrint("  border-radius: {d}px;\n", .{radius}) ++
    \\  box-shadow: 0 16px 36px alpha(black, 0.45);
    \\}
    \\.browserselect-menu {
    \\  padding: 8px;
    \\}
    \\.browserselect-menu scrolledwindow,
    \\.browserselect-menu list {
    \\  background: transparent;
    \\}
    \\.browserselect-menu row {
    \\  border-radius: 9px;
    \\  padding: 6px 10px;
    \\}
    \\.browserselect-menu row:not(:selected) {
    \\  background: transparent;
    \\}
    \\.browserselect-menu row:hover:not(:selected) {
    \\  background: alpha(currentColor, 0.06);
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

const blur_css =
    \\.browserselect-panel {
    \\  backdrop-filter: blur(16px);
    \\}
;

pub const Menu = struct {
    gpa: Allocator,
    app: *c.GtkApplication,
    settings: config_mod.Config.Menu,
    entries: []const browsers.Entry,
    terminal: ?terminal_mod.Terminal,
    uri: ?[:0]const u8,
    backdrop_source: ?backdrop_mod.Source = null,
    window: ?*c.GtkWindow = null,
    panel: ?*c.GtkOverlay = null,
    tint: ?*c.GtkWidget = null,
    list: ?*c.GtkListBox = null,
    blur: blur_mod.Blur = .{},
    backdrop: ?backdrop_mod.Backdrop = null,
    placing: u8 = 0,
    wanted_opacity: ?f64 = null,
    was_active: bool = false,
    launched: bool = false,
    closing: bool = false,
    chosen: ?[]const u8 = null,

    pub fn present(self: *Menu) void {
        loadStyle(css);

        self.wanted_opacity = opacity(self.settings.opacity);
        self.blur.open();
        if (self.backdrop_source) |source| {
            if (self.blur.blurred()) {
                log.debug("the compositor blurs, so menu.static_blur is not needed", .{});
            } else {
                self.backdrop = backdrop_mod.Backdrop.take(source);
            }
        }

        const window = c.cast(c.GtkWindow, c.gtk_application_window_new(self.app));
        c.gtk_window_set_title(window, "Browser Select");
        c.gtk_window_set_decorated(window, c.FALSE);
        c.gtk_window_set_resizable(window, c.FALSE);
        c.gtk_widget_add_css_class(c.cast(c.GtkWidget, window), window_class);

        const panel = c.cast(c.GtkOverlay, c.gtk_overlay_new());
        c.gtk_widget_add_css_class(c.cast(c.GtkWidget, panel), panel_class);
        c.gtk_widget_set_overflow(c.cast(c.GtkWidget, panel), .hidden);
        if (self.backdrop) |*found| c.gtk_overlay_add_overlay(panel, found.widget());

        const tint = c.gtk_box_new(.vertical, 0);
        c.gtk_widget_add_css_class(tint, tint_class);
        c.gtk_widget_add_css_class(tint, theme_class);
        c.gtk_overlay_add_overlay(panel, tint);

        const box = c.gtk_box_new(.vertical, 0);
        c.gtk_widget_add_css_class(box, menu_class);
        c.gtk_widget_set_size_request(box, size(self.settings.width -| 2 * border), -1);
        c.gtk_overlay_add_overlay(panel, box);
        c.gtk_overlay_set_measure_overlay(panel, box, c.TRUE);

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
        c.gtk_scrolled_window_set_propagate_natural_width(view, c.TRUE);
        c.gtk_scrolled_window_set_propagate_natural_height(view, c.TRUE);
        c.gtk_scrolled_window_set_max_content_height(view, size(self.settings.max_height));
        c.gtk_box_append(c.cast(c.GtkBox, box), c.cast(c.GtkWidget, view));

        c.gtk_window_set_child(window, c.cast(c.GtkWidget, panel));

        const keys = c.gtk_event_controller_key_new();
        c.gtk_widget_add_controller(c.cast(c.GtkWidget, window), keys);

        _ = c.connect(keys, "key-pressed", &onKeyPressed, self);
        _ = c.connect(list, "row-activated", &onRowActivated, self);
        _ = c.connect(window, "notify::is-active", &onActiveChanged, self);

        self.window = window;
        self.panel = panel;
        self.tint = tint;
        self.list = list;

        c.gtk_list_box_select_row(list, c.gtk_list_box_get_row_at_index(list, 0));

        c.gtk_widget_realize(c.cast(c.GtkWidget, window));
        const surface = c.gtk_native_get_surface(c.cast(c.GtkNative, window));

        if (surface) |found| self.blur.attach(found);
        if (self.blur.path == .gtk) loadStyle(blur_css);
        c.gtk_widget_set_opacity(tint, self.tintOpacity());
        if (self.backdrop != null) c.gtk_widget_set_opacity(c.cast(c.GtkWidget, panel), waiting_opacity);

        if (surface) |found| _ = c.connect(found, "layout", &onLayout, self);

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
        const entry = self.entries[index];
        const started = launch.open(self.gpa, entry, self.uri, self.terminal);
        if (started) self.chosen = entry.id;
        self.finish(started);
    }

    fn finish(self: *Menu, launched: bool) void {
        if (self.closing) return;
        self.closing = true;
        self.launched = launched;
        if (self.window) |window| {
            self.window = null;
            self.panel = null;
            self.blur.close();
            c.gtk_window_destroy(window);
        }
        c.g_application_quit(c.cast(c.GApplication, self.app));
    }

    fn panelArea(self: *Menu) ?c.cairo_rectangle_int_t {
        const panel = self.panel orelse return null;
        const bounds = self.surfaceBounds(c.cast(c.GtkWidget, panel)) orelse return null;
        if (bounds.width <= 0 or bounds.height <= 0) return null;

        const left = @floor(bounds.x);
        const top = @floor(bounds.y);
        return .{
            .x = @intFromFloat(left),
            .y = @intFromFloat(top),
            .width = @intFromFloat(@ceil(bounds.x + bounds.width) - left),
            .height = @intFromFloat(@ceil(bounds.y + bounds.height) - top),
        };
    }

    fn surfaceBounds(self: *Menu, widget: *c.GtkWidget) ?Bounds {
        const window = self.window orelse return null;

        var bounds: c.graphene_rect_t = undefined;
        const found = c.gtk_widget_compute_bounds(widget, c.cast(c.GtkWidget, window), &bounds);
        if (found == c.FALSE) return null;

        var x: f64 = 0;
        var y: f64 = 0;
        c.gtk_native_get_surface_transform(c.cast(c.GtkNative, window), &x, &y);
        return .{ .x = bounds.x + x, .y = bounds.y + y, .width = bounds.width, .height = bounds.height };
    }

    fn placeBackdrop(self: *Menu) void {
        const found = if (self.backdrop) |*backdrop| backdrop else return;
        if (c.gdk_display_get_default()) |display| c.gdk_display_flush(display);

        const origin = self.surfaceBounds(c.cast(c.GtkWidget, found.fixed));
        const placement: backdrop_mod.Placement =
            if (origin) |bounds| found.place(bounds.x, bounds.y) else .missing;

        switch (placement) {
            .placed => return self.showPanel(),
            .missing => if (self.placing < placing_tries) {
                self.placing += 1;
                _ = c.g_timeout_add(placing_interval_ms, &onPlace, self);
                return;
            } else {
                log.warn(
                    "sway shows no window of this process after {d} tries, so the popup has no blurred background",
                    .{placing_tries},
                );
            },
            .failed => {},
        }

        found.hide();
        self.backdrop = null;
        if (self.tint) |tint| c.gtk_widget_set_opacity(tint, self.tintOpacity());
        self.showPanel();
    }

    fn showPanel(self: *Menu) void {
        const panel = self.panel orelse return;
        c.gtk_widget_set_opacity(c.cast(c.GtkWidget, panel), 1);
    }

    fn tintOpacity(self: *const Menu) f64 {
        if (self.wanted_opacity) |wanted| return wanted;
        return if (self.blur.blurred() or self.backdrop != null) blurred_opacity else plain_opacity;
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

fn onLayout(surface: *c.GdkSurface, _: c_int, _: c_int, data: c.gpointer) callconv(.c) void {
    const self: *Menu = @ptrCast(@alignCast(data.?));

    const area = self.panelArea() orelse return;
    const region = c.cairo_region_create_rectangle(&area);
    defer c.cairo_region_destroy(region);

    c.gdk_surface_set_input_region(surface, region);
    self.blur.shape(area, radius);

    if (self.backdrop != null and self.placing == 0) {
        self.placing = 1;
        _ = c.g_idle_add(&onPlace, self);
    }
}

fn onPlace(data: c.gpointer) callconv(.c) c.gboolean {
    const self: *Menu = @ptrCast(@alignCast(data.?));
    if (self.window != null) self.placeBackdrop();
    return c.source_remove;
}

const Bounds = struct { x: f64, y: f64, width: f64, height: f64 };

fn digitOf(keyval: c.guint) ?usize {
    if (keyval >= c.key_1 and keyval <= c.key_9) return keyval - c.key_1 + 1;
    if (keyval >= c.key_KP_1 and keyval <= c.key_KP_9) return keyval - c.key_KP_1 + 1;
    return null;
}

fn loadStyle(text: [*:0]const u8) void {
    const display = c.gdk_display_get_default() orelse return;

    const provider = c.gtk_css_provider_new();
    defer c.g_object_unref(provider);

    c.gtk_css_provider_load_from_string(provider, text);
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

fn opacity(value: ?f64) ?f64 {
    const wanted = value orelse return null;
    if (wanted >= 0 and wanted <= 1) return wanted;

    log.warn("menu.opacity = {d} is not between 0 and 1, so it is ignored", .{wanted});
    return null;
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

test opacity {
    try std.testing.expectEqual(@as(?f64, 0.5), opacity(0.5));
    try std.testing.expectEqual(@as(?f64, 0), opacity(0));
    try std.testing.expectEqual(@as(?f64, 1), opacity(1));
    try std.testing.expectEqual(@as(?f64, null), opacity(null));
    try std.testing.expectEqual(@as(?f64, null), opacity(1.5));
    try std.testing.expectEqual(@as(?f64, null), opacity(-0.2));
    try std.testing.expectEqual(@as(?f64, null), opacity(std.math.nan(f64)));
}

test "the stylesheet names no color, because a theme that lacks the name draws nothing" {
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, css, '@'));
}
