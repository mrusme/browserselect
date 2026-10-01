const c = @import("c.zig");

const Interface = c.Interface;
const Message = c.Message;
const Proxy = c.Proxy;

const capture_output_types = [_]?*const Interface{
    &frame_interface,
    null,
    &c.wl_output_interface,
};

const capture_region_types = [_]?*const Interface{
    &frame_interface,
    null,
    &c.wl_output_interface,
    null,
    null,
    null,
    null,
};

const copy_types = [_]?*const Interface{&c.wl_buffer_interface};

const manager_requests = [_]Message{
    .{ .name = "capture_output", .signature = "nio", .types = &capture_output_types },
    .{ .name = "capture_output_region", .signature = "nioiiii", .types = &capture_region_types },
    .{ .name = "destroy", .signature = "", .types = &c.no_types },
};

const frame_requests = [_]Message{
    .{ .name = "copy", .signature = "o", .types = &copy_types },
    .{ .name = "destroy", .signature = "", .types = &c.no_types },
};

const frame_events = [_]Message{
    .{ .name = "buffer", .signature = "uuuu", .types = &c.no_types },
    .{ .name = "flags", .signature = "u", .types = &c.no_types },
    .{ .name = "ready", .signature = "uuu", .types = &c.no_types },
    .{ .name = "failed", .signature = "", .types = &c.no_types },
};

pub const manager_interface: Interface = .{
    .name = "zwlr_screencopy_manager_v1",
    .version = 1,
    .method_count = manager_requests.len,
    .methods = &manager_requests,
    .event_count = 0,
    .events = null,
};

pub const frame_interface: Interface = .{
    .name = "zwlr_screencopy_frame_v1",
    .version = 1,
    .method_count = frame_requests.len,
    .methods = &frame_requests,
    .event_count = frame_events.len,
    .events = &frame_events,
};

pub const y_invert: u32 = 1;

pub const FrameListener = extern struct {
    buffer: *const fn (
        data: ?*anyopaque,
        frame: *Proxy,
        format: u32,
        width: u32,
        height: u32,
        stride: u32,
    ) callconv(.c) void,
    flags: *const fn (data: ?*anyopaque, frame: *Proxy, flags: u32) callconv(.c) void,
    ready: *const fn (
        data: ?*anyopaque,
        frame: *Proxy,
        seconds_high: u32,
        seconds_low: u32,
        nanoseconds: u32,
    ) callconv(.c) void,
    failed: *const fn (data: ?*anyopaque, frame: *Proxy) callconv(.c) void,
};

pub fn captureOutput(manager: *Proxy, cursor: bool, output: *Proxy) ?*Proxy {
    return c.wl_proxy_marshal_flags(
        manager,
        0,
        &frame_interface,
        c.wl_proxy_get_version(manager),
        0,
        @as(?*anyopaque, null),
        @as(i32, if (cursor) 1 else 0),
        output,
    );
}

pub fn copy(frame: *Proxy, buffer: *Proxy) void {
    _ = c.wl_proxy_marshal_flags(frame, 0, null, c.wl_proxy_get_version(frame), 0, buffer);
}

pub fn destroyFrame(frame: *Proxy) void {
    _ = c.wl_proxy_marshal_flags(frame, 1, null, c.wl_proxy_get_version(frame), c.marshal_destroy);
}

pub fn destroyManager(manager: *Proxy) void {
    _ = c.wl_proxy_marshal_flags(
        manager,
        2,
        null,
        c.wl_proxy_get_version(manager),
        c.marshal_destroy,
    );
}
