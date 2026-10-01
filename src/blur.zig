const std = @import("std");
const c = @import("c.zig");
const wl = @import("wayland/c.zig");

const log = std.log.scoped(.blur);

const effect = wl.effect;

pub const Rect = c.cairo_rectangle_int_t;

pub const Path = enum { none, gtk, own };

const first_gtk_path: std.SemanticVersion = .{ .major = 4, .minor = 23, .patch = 3 };

pub const Blur = struct {
    path: Path = .none,
    link: ?wl.Connection = null,
    registry: ?*wl.Proxy = null,
    manager: ?*wl.Proxy = null,
    compositor: ?*wl.Proxy = null,
    effect_object: ?*wl.Proxy = null,
    capabilities: u32 = 0,
    shaped: ?Rect = null,

    pub fn open(self: *Blur) void {
        const display = c.waylandDisplay() orelse {
            log.debug("the display is not a Wayland one, so there is no blur", .{});
            return;
        };
        const wl_display = c.gdk_wayland_display_get_wl_display(display) orelse return;

        const link = wl.Connection.open(wl_display) orelse return;
        self.link = link;
        self.registry = link.registry() orelse return self.release();

        _ = wl.wl_proxy_add_listener(self.registry.?, &registry_listener, self);
        if (!link.roundtrip() or !link.roundtrip()) return self.release();

        const capable = self.manager != null and self.capabilities & effect.blur != 0;
        self.path = pathOf(
            capable,
            c.gtk_get_major_version(),
            c.gtk_get_minor_version(),
            c.gtk_get_micro_version(),
        );
        log.debug("blur path: {t}", .{self.path});

        if (self.path != .own) self.release();
    }

    pub fn attach(self: *Blur, surface: *c.GdkSurface) void {
        if (self.path != .own) return;

        const manager = self.manager orelse return self.abandon();
        const target = c.gdk_wayland_surface_get_wl_surface(surface) orelse return self.abandon();
        const made = effect.getEffect(manager, target) orelse return self.abandon();

        self.link.?.adopt(made);
        self.effect_object = made;
    }

    pub fn shape(self: *Blur, area: Rect, radius: c_int) void {
        const made = self.effect_object orelse return;
        const compositor = self.compositor orelse return;
        if (self.shaped) |previous| {
            if (std.meta.eql(previous, area)) return;
        }

        const region = wl.createRegion(compositor) orelse return;
        defer wl.destroyRegion(region);

        var parts: [max_parts]Rect = undefined;
        for (rounded(area, radius, &parts)) |part| {
            wl.addToRegion(region, part.x, part.y, part.width, part.height);
        }
        effect.setBlurRegion(made, region);
        self.shaped = area;
    }

    pub fn blurred(self: Blur) bool {
        return self.path != .none;
    }

    pub fn close(self: *Blur) void {
        self.release();
        self.path = .none;
    }

    fn abandon(self: *Blur) void {
        log.warn("the compositor offers blur, however the window has no Wayland surface to request it for", .{});
        self.close();
    }

    fn release(self: *Blur) void {
        if (self.effect_object) |made| effect.destroyEffect(made);
        if (self.manager) |found| effect.destroyManager(found);
        if (self.compositor) |found| wl.wl_proxy_destroy(found);
        if (self.registry) |found| wl.wl_proxy_destroy(found);
        if (self.link) |link| link.close();

        self.effect_object = null;
        self.manager = null;
        self.compositor = null;
        self.registry = null;
        self.link = null;
        self.shaped = null;
    }
};

pub fn pathOf(capable: bool, major: c.guint, minor: c.guint, micro: c.guint) Path {
    if (!capable) return .none;

    const running: std.SemanticVersion = .{ .major = major, .minor = minor, .patch = micro };
    return if (running.order(first_gtk_path) == .lt) .own else .gtk;
}

pub const max_radius = 64;
pub const max_parts = 2 * max_radius + 1;

pub fn rounded(area: Rect, radius: c_int, out: *[max_parts]Rect) []Rect {
    const corner = std.math.clamp(radius, 0, @min(max_radius, @divTrunc(@min(area.width, area.height), 2)));

    var count: usize = 0;
    var row: c_int = 0;
    while (row < corner) : (row += 1) {
        const inset = insetOf(corner, row);
        out[count] = .{
            .x = area.x + inset,
            .y = area.y + row,
            .width = area.width - 2 * inset,
            .height = 1,
        };
        count += 1;
    }

    if (area.height > 2 * corner) {
        out[count] = .{
            .x = area.x,
            .y = area.y + corner,
            .width = area.width,
            .height = area.height - 2 * corner,
        };
        count += 1;
    }

    row = 0;
    while (row < corner) : (row += 1) {
        const inset = insetOf(corner, corner - 1 - row);
        out[count] = .{
            .x = area.x + inset,
            .y = area.y + area.height - corner + row,
            .width = area.width - 2 * inset,
            .height = 1,
        };
        count += 1;
    }
    return out[0..count];
}

fn insetOf(radius: c_int, row: c_int) c_int {
    const r: f64 = @floatFromInt(radius);
    const dy = r - @as(f64, @floatFromInt(row)) - 0.5;
    return @intFromFloat(@max(0, @ceil(r - @sqrt(r * r - dy * dy) - 0.25)));
}

fn onGlobal(
    data: ?*anyopaque,
    registry: *wl.Proxy,
    name: u32,
    interface: [*:0]const u8,
    _: u32,
) callconv(.c) void {
    const self: *Blur = @ptrCast(@alignCast(data.?));
    const offered = std.mem.span(interface);

    if (std.mem.eql(u8, offered, std.mem.span(effect.manager_interface.name))) {
        const bound = wl.bind(registry, name, &effect.manager_interface, 1) orelse return;
        self.manager = bound;
        _ = wl.wl_proxy_add_listener(bound, &manager_listener, self);
        return;
    }

    if (std.mem.eql(u8, offered, "wl_compositor")) {
        self.compositor = wl.bind(registry, name, &wl.wl_compositor_interface, 1);
    }
}

fn onGlobalRemove(_: ?*anyopaque, _: *wl.Proxy, _: u32) callconv(.c) void {}

const registry_listener: wl.RegistryListener = .{
    .global = &onGlobal,
    .global_remove = &onGlobalRemove,
};

fn onCapabilities(data: ?*anyopaque, _: *wl.Proxy, flags: u32) callconv(.c) void {
    const self: *Blur = @ptrCast(@alignCast(data.?));
    self.capabilities = flags;
}

const manager_listener: effect.ManagerListener = .{ .capabilities = &onCapabilities };

const testing = std.testing;

test "the path follows the capability and the GTK version" {
    try testing.expectEqual(Path.own, pathOf(true, 4, 22, 5));
    try testing.expectEqual(Path.own, pathOf(true, 4, 23, 2));
    try testing.expectEqual(Path.gtk, pathOf(true, 4, 23, 3));
    try testing.expectEqual(Path.gtk, pathOf(true, 4, 24, 0));
    try testing.expectEqual(Path.none, pathOf(false, 4, 22, 5));
    try testing.expectEqual(Path.none, pathOf(false, 4, 24, 0));
}

test "a 14px radius is followed by 29 rectangles inside the bounds" {
    const area: Rect = .{ .x = 48, .y = 28, .width = 720, .height = 60 };
    var parts: [max_parts]Rect = undefined;
    const shape_parts = rounded(area, 14, &parts);

    try testing.expectEqual(@as(usize, 29), shape_parts.len);

    var covered: c_int = 0;
    for (shape_parts) |part| {
        try testing.expect(part.x >= area.x);
        try testing.expect(part.y >= area.y);
        try testing.expect(part.x + part.width <= area.x + area.width);
        try testing.expect(part.y + part.height <= area.y + area.height);
        try testing.expect(part.width > 0 and part.height > 0);
        covered += part.height;
    }
    try testing.expectEqual(area.height, covered);

    try testing.expect(shape_parts[0].x > area.x);
    try testing.expectEqual(area.width, shape_parts[14].width);
}

test "the rounded region is symmetric" {
    const area: Rect = .{ .x = 10, .y = 20, .width = 300, .height = 200 };
    var parts: [max_parts]Rect = undefined;
    const shape_parts = rounded(area, 14, &parts);

    for (shape_parts, 0..) |part, at| {
        const mirrored = shape_parts[shape_parts.len - 1 - at];
        try testing.expectEqual(part.x, mirrored.x);
        try testing.expectEqual(part.width, mirrored.width);
        try testing.expectEqual(part.height, mirrored.height);

        const left = part.x - area.x;
        const right = area.x + area.width - (part.x + part.width);
        try testing.expectEqual(left, right);
    }

    var at: usize = 1;
    while (at < 14) : (at += 1) {
        try testing.expect(shape_parts[at].x <= shape_parts[at - 1].x);
    }
}

test "a panel smaller than the corners gets a smaller radius" {
    const area: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 10 };
    var parts: [max_parts]Rect = undefined;
    const shape_parts = rounded(area, 14, &parts);

    try testing.expectEqual(@as(usize, 10), shape_parts.len);
    for (shape_parts) |part| try testing.expect(part.y + part.height <= 10);
}
