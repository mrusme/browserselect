const std = @import("std");
const builtin = @import("builtin");
const Box = @import("box.zig").Box;
const c = @import("c.zig");
const wl = @import("wayland/c.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.capture);

const screencopy = wl.screencopy;

const native = builtin.cpu.arch.endian();
const quarter_turn = std.math.pi / 2.0;
const frame_timeout_ms = 2000;
const max_pixels: u64 = 1 << 28;
const max_edge = 1 << 16;

const Error = error{Unavailable};

pub const Screen = struct {
    monitor: *c.GdkMonitor,
    output: *wl.Proxy,
    logical: Box,
    transform: wl.Transform,
};

pub const Frame = struct {
    format: wl.Format,
    width: u32,
    height: u32,
    stride: u32,
    inverted: bool,
    pixels: []align(std.heap.page_size_min) u8,

    pub fn release(self: Frame) void {
        std.posix.munmap(self.pixels);
    }
};

const Pending = struct {
    format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    flags: u32 = 0,
    described: bool = false,
    copied: bool = false,
    broken: bool = false,

    fn ready(self: Pending) bool {
        return self.copied;
    }

    fn sized(self: Pending) bool {
        return self.described;
    }
};

const Bound = struct {
    owner: *Capture,
    proxy: *wl.Proxy,
    name: std.ArrayList(u8) = .empty,
    transform: wl.Transform = .normal,
};

pub const Capture = struct {
    gpa: Allocator,
    link: wl.Connection,
    registry: *wl.Proxy,
    shm: ?*wl.Proxy = null,
    manager: ?*wl.Proxy = null,
    outputs: std.ArrayList(*Bound) = .empty,
    screens: std.ArrayList(Screen) = .empty,

    pub fn open(gpa: Allocator, display: *c.GdkDisplay) ?*Capture {
        const wl_display = c.gdk_wayland_display_get_wl_display(display) orelse return null;

        const link = wl.Connection.open(wl_display) orelse return null;
        const registry = link.registry() orelse {
            link.close();
            return null;
        };

        const self = gpa.create(Capture) catch {
            wl.wl_proxy_destroy(registry);
            link.close();
            return null;
        };
        self.* = .{ .gpa = gpa, .link = link, .registry = registry };

        _ = wl.wl_proxy_add_listener(registry, &registry_listener, self);
        if (!link.roundtrip() or !link.roundtrip()) {
            self.close();
            return null;
        }

        if (self.manager == null or self.shm == null) {
            log.warn("this compositor has no wlr-screencopy, so the screen cannot be captured", .{});
            self.close();
            return null;
        }

        self.collect(display);
        if (self.screens.items.len == 0) {
            log.warn("no monitor could be matched to a Wayland output", .{});
            self.close();
            return null;
        }
        return self;
    }

    pub fn close(self: *Capture) void {
        for (self.outputs.items) |bound| {
            bound.name.deinit(self.gpa);
            wl.releaseOutput(bound.proxy);
            self.gpa.destroy(bound);
        }
        self.outputs.deinit(self.gpa);

        for (self.screens.items) |screen| c.g_object_unref(screen.monitor);
        self.screens.deinit(self.gpa);

        if (self.manager) |found| screencopy.destroyManager(found);
        if (self.shm) |found| wl.wl_proxy_destroy(found);
        wl.wl_proxy_destroy(self.registry);
        self.link.close();
        self.gpa.destroy(self);
    }

    pub fn grab(self: *Capture, screen: Screen) ?Frame {
        return self.take(screen) catch null;
    }

    fn take(self: *Capture, screen: Screen) Error!Frame {
        const manager = self.manager orelse return error.Unavailable;
        const shm = self.shm orelse return error.Unavailable;

        var pending: Pending = .{};

        const frame = screencopy.captureOutput(manager, false, screen.output) orelse
            return error.Unavailable;
        defer screencopy.destroyFrame(frame);

        self.link.adopt(frame);
        _ = wl.wl_proxy_add_listener(frame, &frame_listener, &pending);

        if (!self.until(&pending, Pending.sized)) return error.Unavailable;

        const size = @as(usize, pending.stride) * @as(usize, pending.height);
        if (size == 0 or @as(u64, pending.width) * pending.height > max_pixels) {
            log.warn("the compositor offered a {d}x{d} frame", .{ pending.width, pending.height });
            return error.Unavailable;
        }

        const fd = try shareable(size);
        defer _ = std.c.close(fd);

        const pixels = std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch |err| {
            log.warn("cannot map {d} bytes for a frame: {t}", .{ size, err });
            return error.Unavailable;
        };
        errdefer std.posix.munmap(pixels);

        const buffer = self.wrap(shm, fd, size, pending) orelse return error.Unavailable;
        defer wl.destroyBuffer(buffer);

        screencopy.copy(frame, buffer);
        if (!self.until(&pending, Pending.ready)) return error.Unavailable;

        return .{
            .format = @enumFromInt(pending.format),
            .width = pending.width,
            .height = pending.height,
            .stride = pending.stride,
            .inverted = pending.flags & screencopy.y_invert != 0,
            .pixels = pixels,
        };
    }

    fn wrap(self: *Capture, shm: *wl.Proxy, fd: std.posix.fd_t, size: usize, pending: Pending) ?*wl.Proxy {
        const pool = wl.createPool(shm, fd, @intCast(size)) orelse return null;
        defer wl.destroyPool(pool);

        self.link.adopt(pool);
        return wl.createBuffer(
            pool,
            0,
            @intCast(pending.width),
            @intCast(pending.height),
            @intCast(pending.stride),
            pending.format,
        );
    }

    fn until(self: *Capture, pending: *Pending, done: *const fn (Pending) bool) bool {
        while (!done(pending.*) and !pending.broken) {
            switch (self.link.pump(frame_timeout_ms)) {
                .arrived => {},
                .timeout => {
                    log.warn("the compositor sent no frame within {d}ms", .{frame_timeout_ms});
                    return false;
                },
                .broken => {
                    log.warn("the Wayland connection broke while capturing", .{});
                    return false;
                },
            }
        }

        if (pending.broken) log.warn("the compositor failed to capture the screen", .{});
        return !pending.broken;
    }

    fn collect(self: *Capture, display: *c.GdkDisplay) void {
        const monitors = c.gdk_display_get_monitors(display);
        const count = c.g_list_model_get_n_items(monitors);

        var at: c.guint = 0;
        while (at < count) : (at += 1) {
            const item = c.g_list_model_get_item(monitors, at) orelse continue;
            const monitor: *c.GdkMonitor = @ptrCast(item);

            const output = c.gdk_wayland_monitor_get_wl_output(monitor) orelse {
                c.g_object_unref(monitor);
                continue;
            };

            var area: c.GdkRectangle = undefined;
            c.gdk_monitor_get_geometry(monitor, &area);

            self.screens.append(self.gpa, .{
                .monitor = monitor,
                .output = output,
                .logical = .{ .x = area.x, .y = area.y, .width = area.width, .height = area.height },
                .transform = self.transformOf(monitor),
            }) catch {
                c.g_object_unref(monitor);
                return;
            };
        }
    }

    fn transformOf(self: *Capture, monitor: *c.GdkMonitor) wl.Transform {
        const connector = c.gdk_monitor_get_connector(monitor) orelse return .normal;
        const wanted = std.mem.span(connector);

        for (self.outputs.items) |bound| {
            if (std.mem.eql(u8, bound.name.items, wanted)) return bound.transform;
        }

        log.warn("no Wayland output is named {s}, so it is taken as unrotated", .{wanted});
        return .normal;
    }
};

fn shareable(size: usize) Error!std.posix.fd_t {
    var name_buffer: [64]u8 = undefined;
    var attempt: u32 = 0;
    const fd = while (attempt < 8) : (attempt += 1) {
        const name = std.fmt.bufPrintZ(&name_buffer, "/browserselect-{d}-{d}", .{ std.c.getpid(), attempt }) catch
            return error.Unavailable;
        const opened = std.c.shm_open(
            name.ptr,
            @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }),
            0o600,
        );
        if (opened < 0) continue;
        _ = std.c.shm_unlink(name.ptr);
        break opened;
    } else {
        log.warn("cannot create a shared buffer for the capture", .{});
        return error.Unavailable;
    };
    errdefer _ = std.c.close(fd);

    if (std.c.ftruncate(fd, @intCast(size)) != 0) {
        log.warn("cannot size a shared buffer to {d} bytes", .{size});
        return error.Unavailable;
    }
    return fd;
}

pub const Layout = struct {
    format: c.cairo_format_t,
    swapped: bool,
};

pub fn layoutOf(format: wl.Format) ?Layout {
    return switch (format) {
        .argb8888 => .{ .format = .argb32, .swapped = false },
        .xrgb8888 => .{ .format = .rgb24, .swapped = false },
        .abgr8888 => .{ .format = .argb32, .swapped = true },
        .xbgr8888 => .{ .format = .rgb24, .swapped = true },
        else => null,
    };
}

pub fn swapChannels(pixels: []u8, width: u32, height: u32, stride: u32) void {
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const line = pixels[row * stride ..][0 .. width * 4];

        var at: usize = 0;
        while (at < line.len) : (at += 4) {
            const cell = line[at..][0..4];
            const value = std.mem.readInt(u32, cell, native);
            const turned = (value & 0xFF00FF00) |
                ((value & 0x00FF0000) >> 16) |
                ((value & 0x000000FF) << 16);
            std.mem.writeInt(u32, cell, turned, native);
        }
    }
}

pub fn scaleOf(screen: Screen, frame: Frame) f64 {
    const raw: f64 = @floatFromInt(if (screen.transform.turned()) frame.height else frame.width);
    const logical: f64 = @floatFromInt(@max(screen.logical.width, 1));

    if (raw <= 0) return 1;
    return raw / logical;
}

pub fn compose(screen: Screen, frame: Frame) ?*c.cairo_surface_t {
    const scale = @max(1, scaleOf(screen, frame));

    const width = pixelsAcross(screen.logical.width, scale) orelse return null;
    const height = pixelsAcross(screen.logical.height, scale) orelse return null;

    const target = c.cairo_image_surface_create(.rgb24, width, height);
    if (c.cairo_surface_status(target) != c.cairo_status_success) {
        log.warn("cannot make a {d}x{d} image", .{ width, height });
        c.cairo_surface_destroy(target);
        return null;
    }

    const cr = c.cairo_create(target);
    defer c.cairo_destroy(cr);

    if (!place(cr, scale, screen, frame)) {
        c.cairo_surface_destroy(target);
        return null;
    }

    c.cairo_surface_flush(target);
    return target;
}

fn place(cr: *c.cairo_t, scale: f64, screen: Screen, frame: Frame) bool {
    const layout = layoutOf(frame.format) orelse {
        log.warn("this compositor uses a pixel format Browser Select cannot read: 0x{x}", .{
            @intFromEnum(frame.format),
        });
        return false;
    };

    if (layout.swapped) swapChannels(frame.pixels, frame.width, frame.height, frame.stride);

    const source = c.cairo_image_surface_create_for_data(
        frame.pixels.ptr,
        layout.format,
        @intCast(frame.width),
        @intCast(frame.height),
        @intCast(frame.stride),
    );
    defer c.cairo_surface_destroy(source);

    if (c.cairo_surface_status(source) != c.cairo_status_success) {
        log.warn("cannot read a {d}x{d} frame", .{ frame.width, frame.height });
        return false;
    }

    const buffer_width: f64 = @floatFromInt(frame.width);
    const buffer_height: f64 = @floatFromInt(frame.height);

    const turned_width = if (screen.transform.turned()) buffer_height else buffer_width;
    const turned_height = if (screen.transform.turned()) buffer_width else buffer_height;

    const across: f64 = @floatFromInt(screen.logical.width);
    const down: f64 = @floatFromInt(screen.logical.height);

    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_scale(cr, scale, scale);
    c.cairo_translate(cr, across / 2, down / 2);
    if (screen.transform.flipped_over()) c.cairo_scale(cr, -1, 1);
    c.cairo_rotate(cr, quarter_turn * @as(f64, @floatFromInt(screen.transform.quarters())));
    c.cairo_scale(
        cr,
        across / turned_width,
        down / turned_height * (if (frame.inverted) @as(f64, -1) else 1),
    );
    c.cairo_translate(cr, -buffer_width / 2, -buffer_height / 2);

    c.cairo_set_source_surface(cr, source, 0, 0);
    c.cairo_pattern_set_filter(c.cairo_get_source(cr), .good);
    c.cairo_paint(cr);
    return true;
}

fn pixelsAcross(logical: i32, scale: f64) ?c_int {
    if (logical <= 0) return null;

    const wanted = @round(@as(f64, @floatFromInt(logical)) * scale);
    if (wanted < 1 or wanted > max_edge) return null;
    return @intFromFloat(wanted);
}

fn onGlobal(
    data: ?*anyopaque,
    registry: *wl.Proxy,
    name: u32,
    interface: [*:0]const u8,
    version: u32,
) callconv(.c) void {
    const self: *Capture = @ptrCast(@alignCast(data.?));
    const offered = std.mem.span(interface);

    if (std.mem.eql(u8, offered, "wl_shm")) {
        self.shm = wl.bind(registry, name, &wl.wl_shm_interface, 1);
        return;
    }

    if (std.mem.eql(u8, offered, std.mem.span(screencopy.manager_interface.name))) {
        self.manager = wl.bind(registry, name, &screencopy.manager_interface, 1);
        return;
    }

    if (!std.mem.eql(u8, offered, "wl_output")) return;

    const proxy = wl.bind(registry, name, &wl.wl_output_interface, @min(version, 4)) orelse return;
    const bound = self.gpa.create(Bound) catch {
        wl.releaseOutput(proxy);
        return;
    };
    bound.* = .{ .owner = self, .proxy = proxy };

    self.outputs.append(self.gpa, bound) catch {
        self.gpa.destroy(bound);
        wl.releaseOutput(proxy);
        return;
    };
    _ = wl.wl_proxy_add_listener(proxy, &output_listener, bound);
}

fn onGlobalRemove(_: ?*anyopaque, _: *wl.Proxy, _: u32) callconv(.c) void {}

const registry_listener: wl.RegistryListener = .{
    .global = &onGlobal,
    .global_remove = &onGlobalRemove,
};

fn onOutputGeometry(
    data: ?*anyopaque,
    _: *wl.Proxy,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: [*:0]const u8,
    _: [*:0]const u8,
    transform: i32,
) callconv(.c) void {
    const self: *Bound = @ptrCast(@alignCast(data.?));
    self.transform = .of(transform);
}

fn onOutputMode(_: ?*anyopaque, _: *wl.Proxy, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}

fn onOutputDone(_: ?*anyopaque, _: *wl.Proxy) callconv(.c) void {}

fn onOutputScale(_: ?*anyopaque, _: *wl.Proxy, _: i32) callconv(.c) void {}

fn onOutputName(data: ?*anyopaque, _: *wl.Proxy, name: [*:0]const u8) callconv(.c) void {
    const self: *Bound = @ptrCast(@alignCast(data.?));

    self.name.clearRetainingCapacity();
    self.name.appendSlice(self.owner.gpa, std.mem.span(name)) catch |err| {
        log.warn("cannot keep the name of an output: {t}", .{err});
    };
}

fn onOutputDescription(_: ?*anyopaque, _: *wl.Proxy, _: [*:0]const u8) callconv(.c) void {}

const output_listener: wl.OutputListener = .{
    .geometry = &onOutputGeometry,
    .mode = &onOutputMode,
    .done = &onOutputDone,
    .scale = &onOutputScale,
    .name = &onOutputName,
    .description = &onOutputDescription,
};

fn onFrameBuffer(
    data: ?*anyopaque,
    _: *wl.Proxy,
    format: u32,
    width: u32,
    height: u32,
    stride: u32,
) callconv(.c) void {
    const self: *Pending = @ptrCast(@alignCast(data.?));
    self.format = format;
    self.width = width;
    self.height = height;
    self.stride = stride;
    self.described = true;
}

fn onFrameFlags(data: ?*anyopaque, _: *wl.Proxy, flags: u32) callconv(.c) void {
    const self: *Pending = @ptrCast(@alignCast(data.?));
    self.flags = flags;
}

fn onFrameReady(data: ?*anyopaque, _: *wl.Proxy, _: u32, _: u32, _: u32) callconv(.c) void {
    const self: *Pending = @ptrCast(@alignCast(data.?));
    self.copied = true;
}

fn onFrameFailed(data: ?*anyopaque, _: *wl.Proxy) callconv(.c) void {
    const self: *Pending = @ptrCast(@alignCast(data.?));
    self.broken = true;
}

const frame_listener: screencopy.FrameListener = .{
    .buffer = &onFrameBuffer,
    .flags = &onFrameFlags,
    .ready = &onFrameReady,
    .failed = &onFrameFailed,
};

const testing = std.testing;

test "every format the compositors offer maps to cairo" {
    try testing.expectEqual(c.cairo_format_t.argb32, layoutOf(.argb8888).?.format);
    try testing.expect(!layoutOf(.argb8888).?.swapped);
    try testing.expectEqual(c.cairo_format_t.rgb24, layoutOf(.xrgb8888).?.format);
    try testing.expect(!layoutOf(.xrgb8888).?.swapped);
    try testing.expectEqual(c.cairo_format_t.rgb24, layoutOf(.xbgr8888).?.format);
    try testing.expect(layoutOf(.xbgr8888).?.swapped);
    try testing.expectEqual(c.cairo_format_t.argb32, layoutOf(.abgr8888).?.format);
    try testing.expect(layoutOf(.abgr8888).?.swapped);
    try testing.expectEqual(@as(?Layout, null), layoutOf(@enumFromInt(0x36314752)));
}

test "swapping red and blue leaves green, the fourth byte and the row padding alone" {
    var pixels: [4]u32 = .{ 0x11223344, 0xAAAAAAAA, 0x55667788, 0xBBBBBBBB };
    swapChannels(std.mem.sliceAsBytes(pixels[0..]), 1, 2, 8);

    try testing.expectEqual(@as(u32, 0x11443322), pixels[0]);
    try testing.expectEqual(@as(u32, 0xAAAAAAAA), pixels[1]);
    try testing.expectEqual(@as(u32, 0x55887766), pixels[2]);
    try testing.expectEqual(@as(u32, 0xBBBBBBBB), pixels[3]);
}

test "the scale follows the buffer against the logical size" {
    const flat: Screen = .{
        .monitor = undefined,
        .output = undefined,
        .logical = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .transform = .normal,
    };
    const dense: Frame = .{
        .format = .xrgb8888,
        .width = 3840,
        .height = 2160,
        .stride = 3840 * 4,
        .inverted = false,
        .pixels = &.{},
    };
    try testing.expectEqual(@as(f64, 2), scaleOf(flat, dense));

    var turned = flat;
    turned.transform = .rotate_90;
    turned.logical = .{ .x = 0, .y = 0, .width = 2160, .height = 3840 };
    try testing.expectEqual(@as(f64, 1), scaleOf(turned, dense));
}
