const std = @import("std");
const wayland = @import("wayland/c.zig");

pub const gboolean = c_int;
pub const gpointer = ?*anyopaque;
pub const gulong = c_ulong;
pub const guint = c_uint;

pub const TRUE: gboolean = 1;
pub const FALSE: gboolean = 0;

pub const GList = extern struct {
    data: gpointer,
    next: ?*GList,
    prev: ?*GList,
};

pub extern fn g_list_append(list: ?*GList, data: gpointer) *GList;
pub extern fn g_list_free(list: ?*GList) void;
pub extern fn g_list_free_full(list: ?*GList, free_func: GDestroyNotify) void;

pub const GError = extern struct {
    domain: u32,
    code: c_int,
    message: ?[*:0]u8,
};

pub extern fn g_error_free(err: *GError) void;

pub const GParamSpec = opaque {};
pub const GType = usize;

pub extern fn g_type_check_instance_is_a(instance: *anyopaque, iface_type: GType) gboolean;

pub const GBytes = opaque {};

pub extern fn g_bytes_new(data: [*]const u8, size: usize) *GBytes;
pub extern fn g_bytes_unref(bytes: *GBytes) void;

pub const GListModel = opaque {};

pub extern fn g_list_model_get_n_items(list: *GListModel) guint;
pub extern fn g_list_model_get_item(list: *GListModel, position: guint) gpointer;

pub const GSourceFunc = *const fn (data: gpointer) callconv(.c) gboolean;
pub const source_remove: gboolean = FALSE;

pub extern fn g_idle_add(function: GSourceFunc, data: gpointer) guint;
pub extern fn g_timeout_add(interval: guint, function: GSourceFunc, data: gpointer) guint;

pub const GCallback = *const fn () callconv(.c) void;
pub const GClosureNotify = *const fn (data: gpointer, closure: gpointer) callconv(.c) void;
pub const GDestroyNotify = *const fn (data: gpointer) callconv(.c) void;

pub const GConnectFlags = guint;
pub const connect_default: GConnectFlags = 0;

pub extern fn g_object_ref(object: gpointer) gpointer;
pub extern fn g_object_unref(object: gpointer) void;
pub extern fn g_free(mem: gpointer) void;

pub extern fn g_signal_connect_data(
    instance: gpointer,
    detailed_signal: [*:0]const u8,
    c_handler: GCallback,
    data: gpointer,
    destroy_data: ?GClosureNotify,
    connect_flags: GConnectFlags,
) gulong;

pub inline fn connect(
    instance: anytype,
    signal: [*:0]const u8,
    handler: anytype,
    data: gpointer,
) gulong {
    comptime checkHandler(@TypeOf(handler));
    return g_signal_connect_data(@ptrCast(instance), signal, @ptrCast(handler), data, null, connect_default);
}

fn checkHandler(comptime T: type) void {
    const message = "a signal handler is a pointer to a callconv(.c) function, not " ++ @typeName(T);
    const pointer = switch (@typeInfo(T)) {
        .pointer => |info| info,
        else => @compileError(message),
    };
    const function = switch (@typeInfo(pointer.child)) {
        .@"fn" => |info| info,
        else => @compileError(message),
    };
    switch (function.calling_convention) {
        .auto, .@"inline" => @compileError(message),
        else => {},
    }
}

pub inline fn cast(comptime T: type, ptr: anytype) *T {
    comptime checkCast(T, @TypeOf(ptr));
    return @ptrCast(ptr);
}

fn checkCast(comptime T: type, comptime From: type) void {
    const message = "a GObject cast goes from one opaque handle to another, not from " ++
        @typeName(From) ++ " to " ++ @typeName(T);
    if (@typeInfo(T) != .@"opaque") @compileError(message);
    const pointer = switch (@typeInfo(From)) {
        .pointer => |info| info,
        else => @compileError(message),
    };
    if (pointer.size != .one or pointer.is_const) @compileError(message);
    if (@typeInfo(pointer.child) != .@"opaque") @compileError(message);
}

pub extern fn g_set_prgname(name: [*:0]const u8) void;
pub extern fn g_find_program_in_path(program: [*:0]const u8) ?[*:0]u8;

pub fn installed(gpa: std.mem.Allocator, program: []const u8) std.mem.Allocator.Error!bool {
    const name = try gpa.dupeZ(u8, program);
    defer gpa.free(name);

    const found = g_find_program_in_path(name.ptr) orelse return false;
    g_free(found);
    return true;
}

pub const GPid = c_int;
pub const GSpawnFlags = guint;

pub const spawn_search_path: GSpawnFlags = 1 << 2;
pub const spawn_stdout_to_dev_null: GSpawnFlags = 1 << 3;
pub const spawn_stderr_to_dev_null: GSpawnFlags = 1 << 4;

pub const GSpawnChildSetupFunc = *const fn (data: gpointer) callconv(.c) void;

pub extern fn g_spawn_async(
    working_directory: ?[*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: ?[*:null]const ?[*:0]const u8,
    flags: GSpawnFlags,
    child_setup: ?GSpawnChildSetupFunc,
    user_data: gpointer,
    child_pid: ?*GPid,
    err: *?*GError,
) gboolean;

pub const GUriFlags = guint;
pub const uri_flags_none: GUriFlags = 0;

pub extern fn g_uri_is_valid(uri: [*:0]const u8, flags: GUriFlags, err: ?*?*GError) gboolean;

pub const GApplication = opaque {};
pub const GApplicationFlags = guint;
pub const application_non_unique: GApplicationFlags = 1 << 5;

pub extern fn g_application_run(application: *GApplication, argc: c_int, argv: ?[*][*:0]u8) c_int;
pub extern fn g_application_quit(application: *GApplication) void;

pub const GAppInfo = opaque {};
pub const GAppLaunchContext = opaque {};
pub const GIcon = opaque {};

pub extern fn g_app_info_get_all_for_type(content_type: [*:0]const u8) ?*GList;
pub extern fn g_app_info_get_id(appinfo: *GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_display_name(appinfo: *GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_name(appinfo: *GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_executable(appinfo: *GAppInfo) ?[*:0]const u8;
pub extern fn g_app_info_get_icon(appinfo: *GAppInfo) ?*GIcon;
pub extern fn g_app_info_should_show(appinfo: *GAppInfo) gboolean;
pub extern fn g_app_info_launch_uris(
    appinfo: *GAppInfo,
    uris: ?*GList,
    context: ?*GAppLaunchContext,
    err: *?*GError,
) gboolean;

pub const cairo_t = opaque {};
pub const cairo_surface_t = opaque {};
pub const cairo_pattern_t = opaque {};
pub const cairo_region_t = opaque {};

pub const cairo_format_t = enum(c_int) {
    invalid = -1,
    argb32 = 0,
    rgb24 = 1,
};

pub const cairo_filter_t = enum(c_uint) {
    fast = 0,
    good = 1,
    best = 2,
    nearest = 3,
    bilinear = 4,
};

pub const cairo_status_t = c_uint;
pub const cairo_status_success: cairo_status_t = 0;

pub const cairo_rectangle_int_t = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

pub extern fn cairo_region_create_rectangle(rectangle: *const cairo_rectangle_int_t) *cairo_region_t;
pub extern fn cairo_region_destroy(region: *cairo_region_t) void;

pub extern fn cairo_image_surface_create(format: cairo_format_t, width: c_int, height: c_int) *cairo_surface_t;
pub extern fn cairo_image_surface_create_for_data(
    data: [*]u8,
    format: cairo_format_t,
    width: c_int,
    height: c_int,
    stride: c_int,
) *cairo_surface_t;
pub extern fn cairo_image_surface_get_data(surface: *cairo_surface_t) ?[*]u8;
pub extern fn cairo_image_surface_get_width(surface: *cairo_surface_t) c_int;
pub extern fn cairo_image_surface_get_height(surface: *cairo_surface_t) c_int;
pub extern fn cairo_image_surface_get_stride(surface: *cairo_surface_t) c_int;
pub extern fn cairo_surface_status(surface: *cairo_surface_t) cairo_status_t;
pub extern fn cairo_surface_flush(surface: *cairo_surface_t) void;
pub extern fn cairo_surface_destroy(surface: *cairo_surface_t) void;

pub extern fn cairo_create(target: *cairo_surface_t) *cairo_t;
pub extern fn cairo_destroy(cr: *cairo_t) void;
pub extern fn cairo_save(cr: *cairo_t) void;
pub extern fn cairo_restore(cr: *cairo_t) void;
pub extern fn cairo_translate(cr: *cairo_t, tx: f64, ty: f64) void;
pub extern fn cairo_scale(cr: *cairo_t, sx: f64, sy: f64) void;
pub extern fn cairo_rotate(cr: *cairo_t, angle: f64) void;
pub extern fn cairo_rectangle(cr: *cairo_t, x: f64, y: f64, width: f64, height: f64) void;
pub extern fn cairo_clip(cr: *cairo_t) void;
pub extern fn cairo_paint(cr: *cairo_t) void;
pub extern fn cairo_set_source_surface(cr: *cairo_t, surface: *cairo_surface_t, x: f64, y: f64) void;
pub extern fn cairo_get_source(cr: *cairo_t) *cairo_pattern_t;
pub extern fn cairo_pattern_set_filter(pattern: *cairo_pattern_t, filter: cairo_filter_t) void;

pub const graphene_rect_t = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const GdkDisplay = opaque {};
pub const GdkSurface = opaque {};
pub const GdkMonitor = opaque {};
pub const GdkAppLaunchContext = opaque {};
pub const GdkPaintable = opaque {};
pub const GdkTexture = opaque {};
pub const GdkModifierType = guint;

pub const GdkRectangle = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

pub const GdkMemoryFormat = enum(c_uint) {
    r8g8b8 = 7,
};

pub extern fn gdk_display_get_default() ?*GdkDisplay;
pub extern fn gdk_display_get_app_launch_context(display: *GdkDisplay) *GdkAppLaunchContext;
pub extern fn gdk_display_get_monitors(display: *GdkDisplay) *GListModel;
pub extern fn gdk_display_flush(display: *GdkDisplay) void;
pub extern fn gdk_monitor_get_geometry(monitor: *GdkMonitor, geometry: *GdkRectangle) void;
pub extern fn gdk_monitor_get_connector(monitor: *GdkMonitor) ?[*:0]const u8;
pub extern fn gdk_surface_set_input_region(surface: *GdkSurface, region: ?*cairo_region_t) void;
pub extern fn gdk_memory_texture_new(
    width: c_int,
    height: c_int,
    format: GdkMemoryFormat,
    bytes: *GBytes,
    stride: usize,
) *GdkTexture;

pub extern fn gdk_wayland_display_get_type() GType;
pub extern fn gdk_wayland_display_get_wl_display(display: *GdkDisplay) ?*wayland.Proxy;
pub extern fn gdk_wayland_surface_get_wl_surface(surface: *GdkSurface) ?*wayland.Proxy;
pub extern fn gdk_wayland_monitor_get_wl_output(monitor: *GdkMonitor) ?*wayland.Proxy;

pub fn waylandDisplay() ?*GdkDisplay {
    const display = gdk_display_get_default() orelse return null;
    if (g_type_check_instance_is_a(display, gdk_wayland_display_get_type()) == FALSE) return null;
    return display;
}

pub const key_Escape: guint = 0xff1b;
pub const key_1: guint = 0x0031;
pub const key_9: guint = 0x0039;
pub const key_KP_1: guint = 0xffb1;
pub const key_KP_9: guint = 0xffb9;

pub const PangoEllipsizeMode = enum(guint) {
    none = 0,
    start = 1,
    middle = 2,
    end = 3,
};

pub const GtkOrientation = enum(guint) {
    horizontal = 0,
    vertical = 1,
};

pub const GtkSelectionMode = enum(guint) {
    none = 0,
    single = 1,
    browse = 2,
    multiple = 3,
};

pub const GtkPolicyType = enum(guint) {
    always = 0,
    automatic = 1,
    never = 2,
    external = 3,
};

pub const GtkOverflow = enum(guint) {
    visible = 0,
    hidden = 1,
};

pub const GtkContentFit = enum(guint) {
    fill = 0,
    contain = 1,
    cover = 2,
    scale_down = 3,
};

pub const GtkApplication = opaque {};
pub const GtkWidget = opaque {};
pub const GtkWindow = opaque {};
pub const GtkNative = opaque {};
pub const GtkOverlay = opaque {};
pub const GtkFixed = opaque {};
pub const GtkPicture = opaque {};
pub const GtkBox = opaque {};
pub const GtkLabel = opaque {};
pub const GtkImage = opaque {};
pub const GtkListBox = opaque {};
pub const GtkListBoxRow = opaque {};
pub const GtkScrolledWindow = opaque {};
pub const GtkCssProvider = opaque {};
pub const GtkStyleProvider = opaque {};
pub const GtkEventController = opaque {};
pub const GtkEventControllerKey = opaque {};
pub const GtkIconTheme = opaque {};

pub extern fn gtk_get_major_version() guint;
pub extern fn gtk_get_minor_version() guint;
pub extern fn gtk_get_micro_version() guint;

pub extern fn gtk_application_new(application_id: ?[*:0]const u8, flags: GApplicationFlags) *GtkApplication;
pub extern fn gtk_application_window_new(application: *GtkApplication) *GtkWidget;

pub extern fn gtk_window_set_title(window: *GtkWindow, title: ?[*:0]const u8) void;
pub extern fn gtk_window_set_decorated(window: *GtkWindow, setting: gboolean) void;
pub extern fn gtk_window_set_resizable(window: *GtkWindow, resizable: gboolean) void;
pub extern fn gtk_window_set_child(window: *GtkWindow, child: ?*GtkWidget) void;
pub extern fn gtk_window_present(window: *GtkWindow) void;
pub extern fn gtk_window_destroy(window: *GtkWindow) void;
pub extern fn gtk_window_is_active(window: *GtkWindow) gboolean;
pub extern fn gtk_window_set_default_icon_name(name: [*:0]const u8) void;

pub extern fn gtk_native_get_surface(self: *GtkNative) ?*GdkSurface;
pub extern fn gtk_native_get_surface_transform(self: *GtkNative, x: *f64, y: *f64) void;

pub extern fn gtk_widget_realize(widget: *GtkWidget) void;
pub extern fn gtk_widget_set_hexpand(widget: *GtkWidget, expand: gboolean) void;
pub extern fn gtk_widget_set_size_request(widget: *GtkWidget, width: c_int, height: c_int) void;
pub extern fn gtk_widget_set_overflow(widget: *GtkWidget, overflow: GtkOverflow) void;
pub extern fn gtk_widget_set_opacity(widget: *GtkWidget, opacity: f64) void;
pub extern fn gtk_widget_set_visible(widget: *GtkWidget, visible: gboolean) void;
pub extern fn gtk_widget_set_can_target(widget: *GtkWidget, can_target: gboolean) void;
pub extern fn gtk_widget_add_css_class(widget: *GtkWidget, css_class: [*:0]const u8) void;
pub extern fn gtk_widget_add_controller(widget: *GtkWidget, controller: *GtkEventController) void;
pub extern fn gtk_widget_compute_bounds(
    widget: *GtkWidget,
    target: *GtkWidget,
    out_bounds: *graphene_rect_t,
) gboolean;

pub extern fn gtk_overlay_new() *GtkWidget;
pub extern fn gtk_overlay_add_overlay(overlay: *GtkOverlay, widget: *GtkWidget) void;
pub extern fn gtk_overlay_set_measure_overlay(
    overlay: *GtkOverlay,
    widget: *GtkWidget,
    measure: gboolean,
) void;

pub extern fn gtk_fixed_new() *GtkWidget;
pub extern fn gtk_fixed_put(fixed: *GtkFixed, widget: *GtkWidget, x: f64, y: f64) void;
pub extern fn gtk_fixed_move(fixed: *GtkFixed, widget: *GtkWidget, x: f64, y: f64) void;

pub extern fn gtk_picture_new() *GtkWidget;
pub extern fn gtk_picture_set_paintable(self: *GtkPicture, paintable: ?*GdkPaintable) void;
pub extern fn gtk_picture_set_content_fit(self: *GtkPicture, content_fit: GtkContentFit) void;

pub extern fn gtk_box_new(orientation: GtkOrientation, spacing: c_int) *GtkWidget;
pub extern fn gtk_box_append(box: *GtkBox, child: *GtkWidget) void;

pub extern fn gtk_label_new(str: ?[*:0]const u8) *GtkWidget;
pub extern fn gtk_label_set_ellipsize(self: *GtkLabel, mode: PangoEllipsizeMode) void;
pub extern fn gtk_label_set_max_width_chars(self: *GtkLabel, n_chars: c_int) void;
pub extern fn gtk_label_set_xalign(self: *GtkLabel, xalign: f32) void;

pub extern fn gtk_image_new() *GtkWidget;
pub extern fn gtk_image_set_from_gicon(image: *GtkImage, icon: ?*GIcon) void;
pub extern fn gtk_image_set_from_icon_name(image: *GtkImage, icon_name: ?[*:0]const u8) void;
pub extern fn gtk_image_set_pixel_size(image: *GtkImage, pixel_size: c_int) void;

pub extern fn gtk_list_box_new() *GtkWidget;
pub extern fn gtk_list_box_append(box: *GtkListBox, child: *GtkWidget) void;
pub extern fn gtk_list_box_set_selection_mode(box: *GtkListBox, mode: GtkSelectionMode) void;
pub extern fn gtk_list_box_select_row(box: *GtkListBox, row: ?*GtkListBoxRow) void;
pub extern fn gtk_list_box_get_row_at_index(box: *GtkListBox, index: c_int) ?*GtkListBoxRow;
pub extern fn gtk_list_box_row_get_index(row: *GtkListBoxRow) c_int;

pub extern fn gtk_scrolled_window_new() *GtkWidget;
pub extern fn gtk_scrolled_window_set_child(window: *GtkScrolledWindow, child: ?*GtkWidget) void;
pub extern fn gtk_scrolled_window_set_policy(
    window: *GtkScrolledWindow,
    hscrollbar_policy: GtkPolicyType,
    vscrollbar_policy: GtkPolicyType,
) void;
pub extern fn gtk_scrolled_window_set_propagate_natural_width(
    window: *GtkScrolledWindow,
    propagate: gboolean,
) void;
pub extern fn gtk_scrolled_window_set_propagate_natural_height(
    window: *GtkScrolledWindow,
    propagate: gboolean,
) void;
pub extern fn gtk_scrolled_window_set_max_content_height(window: *GtkScrolledWindow, height: c_int) void;

pub const style_provider_priority_application: guint = 600;

pub extern fn gtk_css_provider_new() *GtkCssProvider;
pub extern fn gtk_css_provider_load_from_string(provider: *GtkCssProvider, string: [*:0]const u8) void;
pub extern fn gtk_style_context_add_provider_for_display(
    display: *GdkDisplay,
    provider: *GtkStyleProvider,
    priority: guint,
) void;

pub extern fn gtk_event_controller_key_new() *GtkEventController;

pub extern fn gtk_icon_theme_get_for_display(display: *GdkDisplay) *GtkIconTheme;
pub extern fn gtk_icon_theme_has_icon(self: *GtkIconTheme, icon_name: [*:0]const u8) gboolean;
