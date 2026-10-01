const std = @import("std");

pub const effect = @import("effect.zig");
pub const screencopy = @import("screencopy.zig");

pub const Proxy = opaque {};
pub const Queue = opaque {};

pub const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: [*]const ?*const Interface,
};

pub const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};

pub const no_types = [_]?*const Interface{null} ** 8;

pub const marshal_destroy: u32 = 1 << 0;

pub extern fn wl_proxy_marshal_flags(proxy: *Proxy, opcode: u32, interface: ?*const Interface, version: u32, flags: u32, ...) ?*Proxy;
pub extern fn wl_proxy_get_version(proxy: *Proxy) u32;
pub extern fn wl_proxy_add_listener(
    proxy: *Proxy,
    implementation: *const anyopaque,
    data: ?*anyopaque,
) c_int;
pub extern fn wl_proxy_destroy(proxy: *Proxy) void;
pub extern fn wl_proxy_set_queue(proxy: *Proxy, queue: ?*Queue) void;
pub extern fn wl_proxy_create_wrapper(proxy: *anyopaque) ?*Proxy;
pub extern fn wl_proxy_wrapper_destroy(proxy: *Proxy) void;

pub extern fn wl_display_create_queue(display: *Proxy) ?*Queue;
pub extern fn wl_event_queue_destroy(queue: *Queue) void;
pub extern fn wl_display_get_fd(display: *Proxy) c_int;
pub extern fn wl_display_flush(display: *Proxy) c_int;
pub extern fn wl_display_roundtrip_queue(display: *Proxy, queue: *Queue) c_int;
pub extern fn wl_display_prepare_read_queue(display: *Proxy, queue: *Queue) c_int;
pub extern fn wl_display_read_events(display: *Proxy) c_int;
pub extern fn wl_display_cancel_read(display: *Proxy) void;
pub extern fn wl_display_dispatch_queue_pending(display: *Proxy, queue: *Queue) c_int;

pub extern const wl_registry_interface: Interface;
pub extern const wl_output_interface: Interface;
pub extern const wl_buffer_interface: Interface;
pub extern const wl_shm_interface: Interface;
pub extern const wl_shm_pool_interface: Interface;
pub extern const wl_compositor_interface: Interface;
pub extern const wl_region_interface: Interface;
pub extern const wl_surface_interface: Interface;

pub const RegistryListener = extern struct {
    global: *const fn (
        data: ?*anyopaque,
        registry: *Proxy,
        name: u32,
        interface: [*:0]const u8,
        version: u32,
    ) callconv(.c) void,
    global_remove: *const fn (data: ?*anyopaque, registry: *Proxy, name: u32) callconv(.c) void,
};

pub const OutputListener = extern struct {
    geometry: *const fn (
        data: ?*anyopaque,
        output: *Proxy,
        x: i32,
        y: i32,
        physical_width: i32,
        physical_height: i32,
        subpixel: i32,
        make: [*:0]const u8,
        model: [*:0]const u8,
        transform: i32,
    ) callconv(.c) void,
    mode: *const fn (
        data: ?*anyopaque,
        output: *Proxy,
        flags: u32,
        width: i32,
        height: i32,
        refresh: i32,
    ) callconv(.c) void,
    done: *const fn (data: ?*anyopaque, output: *Proxy) callconv(.c) void,
    scale: *const fn (data: ?*anyopaque, output: *Proxy, factor: i32) callconv(.c) void,
    name: *const fn (data: ?*anyopaque, output: *Proxy, name: [*:0]const u8) callconv(.c) void,
    description: *const fn (
        data: ?*anyopaque,
        output: *Proxy,
        description: [*:0]const u8,
    ) callconv(.c) void,
};

pub const Transform = enum(u32) {
    normal = 0,
    rotate_90 = 1,
    rotate_180 = 2,
    rotate_270 = 3,
    flipped = 4,
    flipped_90 = 5,
    flipped_180 = 6,
    flipped_270 = 7,

    pub fn of(value: i32) Transform {
        return std.enums.fromInt(Transform, value) orelse .normal;
    }

    pub fn turned(self: Transform) bool {
        return @intFromEnum(self) & 1 != 0;
    }

    pub fn flipped_over(self: Transform) bool {
        return @intFromEnum(self) & 4 != 0;
    }

    pub fn quarters(self: Transform) u2 {
        return @intCast(@intFromEnum(self) & 3);
    }
};

pub const Format = enum(u32) {
    argb8888 = 0,
    xrgb8888 = 1,
    abgr8888 = 0x34324241,
    xbgr8888 = 0x34324258,
    _,
};

pub fn getRegistry(display: *Proxy) ?*Proxy {
    return wl_proxy_marshal_flags(
        display,
        1,
        &wl_registry_interface,
        wl_proxy_get_version(display),
        0,
        @as(?*anyopaque, null),
    );
}

pub fn bind(registry: *Proxy, name: u32, interface: *const Interface, version: u32) ?*Proxy {
    return wl_proxy_marshal_flags(
        registry,
        0,
        interface,
        version,
        0,
        name,
        interface.name,
        version,
        @as(?*anyopaque, null),
    );
}

pub fn createPool(shm: *Proxy, fd: c_int, size: i32) ?*Proxy {
    return wl_proxy_marshal_flags(
        shm,
        0,
        &wl_shm_pool_interface,
        wl_proxy_get_version(shm),
        0,
        @as(?*anyopaque, null),
        fd,
        size,
    );
}

pub fn createBuffer(
    pool: *Proxy,
    offset: i32,
    width: i32,
    height: i32,
    stride: i32,
    format: u32,
) ?*Proxy {
    return wl_proxy_marshal_flags(
        pool,
        0,
        &wl_buffer_interface,
        wl_proxy_get_version(pool),
        0,
        @as(?*anyopaque, null),
        offset,
        width,
        height,
        stride,
        format,
    );
}

pub fn destroyPool(pool: *Proxy) void {
    _ = wl_proxy_marshal_flags(pool, 1, null, wl_proxy_get_version(pool), marshal_destroy);
}

pub fn destroyBuffer(buffer: *Proxy) void {
    _ = wl_proxy_marshal_flags(buffer, 0, null, wl_proxy_get_version(buffer), marshal_destroy);
}

pub fn releaseOutput(output: *Proxy) void {
    if (wl_proxy_get_version(output) < 3) return wl_proxy_destroy(output);
    _ = wl_proxy_marshal_flags(output, 0, null, wl_proxy_get_version(output), marshal_destroy);
}

pub fn createRegion(compositor: *Proxy) ?*Proxy {
    return wl_proxy_marshal_flags(
        compositor,
        1,
        &wl_region_interface,
        wl_proxy_get_version(compositor),
        0,
        @as(?*anyopaque, null),
    );
}

pub fn addToRegion(region: *Proxy, x: i32, y: i32, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(region, 1, null, wl_proxy_get_version(region), 0, x, y, width, height);
}

pub fn destroyRegion(region: *Proxy) void {
    _ = wl_proxy_marshal_flags(region, 0, null, wl_proxy_get_version(region), marshal_destroy);
}

pub const Ready = enum { arrived, timeout, broken };

pub const Connection = struct {
    display: *Proxy,
    queue: *Queue,

    pub fn open(display: *Proxy) ?Connection {
        const queue = wl_display_create_queue(display) orelse return null;
        return .{ .display = display, .queue = queue };
    }

    pub fn close(self: Connection) void {
        wl_event_queue_destroy(self.queue);
    }

    pub fn registry(self: Connection) ?*Proxy {
        const wrapper = wl_proxy_create_wrapper(self.display) orelse return null;
        defer wl_proxy_wrapper_destroy(wrapper);

        wl_proxy_set_queue(wrapper, self.queue);
        return getRegistry(wrapper);
    }

    pub fn adopt(self: Connection, proxy: *Proxy) void {
        wl_proxy_set_queue(proxy, self.queue);
    }

    pub fn roundtrip(self: Connection) bool {
        return wl_display_roundtrip_queue(self.display, self.queue) >= 0;
    }

    pub fn pump(self: Connection, timeout_ms: i32) Ready {
        while (wl_display_prepare_read_queue(self.display, self.queue) != 0) {
            if (wl_display_dispatch_queue_pending(self.display, self.queue) < 0) return .broken;
        }

        if (wl_display_flush(self.display) < 0) {
            wl_display_cancel_read(self.display);
            return .broken;
        }

        var watched: [1]std.c.pollfd = .{.{
            .fd = wl_display_get_fd(self.display),
            .events = std.c.POLL.IN,
            .revents = 0,
        }};

        const ready = std.c.poll(&watched, 1, timeout_ms);
        if (ready <= 0) {
            wl_display_cancel_read(self.display);
            return if (ready == 0) .timeout else .broken;
        }

        if (wl_display_read_events(self.display) < 0) return .broken;
        if (wl_display_dispatch_queue_pending(self.display, self.queue) < 0) return .broken;
        return .arrived;
    }
};

const testing = std.testing;

test "a transform tells rotation from flipping" {
    try testing.expect(!Transform.normal.turned());
    try testing.expect(Transform.rotate_90.turned());
    try testing.expect(!Transform.rotate_180.turned());
    try testing.expect(Transform.flipped_270.turned());

    try testing.expect(!Transform.rotate_270.flipped_over());
    try testing.expect(Transform.flipped.flipped_over());
    try testing.expect(Transform.flipped_90.flipped_over());

    try testing.expectEqual(@as(u2, 0), Transform.flipped.quarters());
    try testing.expectEqual(@as(u2, 2), Transform.flipped_180.quarters());
    try testing.expectEqual(@as(u2, 3), Transform.rotate_270.quarters());
}

test "an unknown transform reads as normal" {
    try testing.expectEqual(Transform.rotate_90, Transform.of(1));
    try testing.expectEqual(Transform.normal, Transform.of(8));
    try testing.expectEqual(Transform.normal, Transform.of(-1));
}
