const std = @import("std");
const c = @import("c.zig");

const Interface = c.Interface;
const Message = c.Message;
const Proxy = c.Proxy;

pub const blur: u32 = 1;

const get_types = [_]?*const Interface{ &surface_interface, &c.wl_surface_interface };

const region_types = [_]?*const Interface{&c.wl_region_interface};

const manager_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = &c.no_types },
    .{ .name = "get_background_effect", .signature = "no", .types = &get_types },
};

const manager_events = [_]Message{
    .{ .name = "capabilities", .signature = "u", .types = &c.no_types },
};

const surface_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = &c.no_types },
    .{ .name = "set_blur_region", .signature = "?o", .types = &region_types },
};

pub const manager_interface: Interface = .{
    .name = "ext_background_effect_manager_v1",
    .version = 1,
    .method_count = manager_requests.len,
    .methods = &manager_requests,
    .event_count = manager_events.len,
    .events = &manager_events,
};

pub const surface_interface: Interface = .{
    .name = "ext_background_effect_surface_v1",
    .version = 1,
    .method_count = surface_requests.len,
    .methods = &surface_requests,
    .event_count = 0,
    .events = null,
};

pub const ManagerListener = extern struct {
    capabilities: *const fn (data: ?*anyopaque, manager: *Proxy, flags: u32) callconv(.c) void,
};

pub fn getEffect(manager: *Proxy, surface: *Proxy) ?*Proxy {
    return c.wl_proxy_marshal_flags(
        manager,
        1,
        &surface_interface,
        c.wl_proxy_get_version(manager),
        0,
        @as(?*anyopaque, null),
        surface,
    );
}

pub fn setBlurRegion(effect: *Proxy, region: ?*Proxy) void {
    _ = c.wl_proxy_marshal_flags(effect, 1, null, c.wl_proxy_get_version(effect), 0, region);
}

pub fn destroyEffect(effect: *Proxy) void {
    _ = c.wl_proxy_marshal_flags(effect, 0, null, c.wl_proxy_get_version(effect), c.marshal_destroy);
}

pub fn destroyManager(manager: *Proxy) void {
    _ = c.wl_proxy_marshal_flags(manager, 0, null, c.wl_proxy_get_version(manager), c.marshal_destroy);
}

const testing = std.testing;

const Expected = struct {
    name: []const u8,
    signature: []const u8,
    types: []const ?[]const u8 = &.{},
};

fn expectMessages(actual: []const Message, expected: []const Expected) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |message, wanted| {
        try testing.expectEqualStrings(wanted.name, std.mem.span(message.name));
        try testing.expectEqualStrings(wanted.signature, std.mem.span(message.signature));
        for (wanted.types, 0..) |type_name, at| {
            const found = message.types[at];
            if (type_name) |named| {
                try testing.expectEqualStrings(named, std.mem.span(found.?.name));
            } else {
                try testing.expectEqual(@as(?*const Interface, null), found);
            }
        }
    }
}

test "the tables say what wayland-scanner generates from the protocol" {
    try testing.expectEqualStrings("ext_background_effect_manager_v1", std.mem.span(manager_interface.name));
    try testing.expectEqual(@as(c_int, 1), manager_interface.version);
    try expectMessages(manager_interface.methods.?[0..@intCast(manager_interface.method_count)], &.{
        .{ .name = "destroy", .signature = "" },
        .{
            .name = "get_background_effect",
            .signature = "no",
            .types = &.{ "ext_background_effect_surface_v1", "wl_surface" },
        },
    });
    try expectMessages(manager_interface.events.?[0..@intCast(manager_interface.event_count)], &.{
        .{ .name = "capabilities", .signature = "u" },
    });

    try testing.expectEqualStrings("ext_background_effect_surface_v1", std.mem.span(surface_interface.name));
    try testing.expectEqual(@as(c_int, 1), surface_interface.version);
    try expectMessages(surface_interface.methods.?[0..@intCast(surface_interface.method_count)], &.{
        .{ .name = "destroy", .signature = "" },
        .{ .name = "set_blur_region", .signature = "?o", .types = &.{"wl_region"} },
    });
    try testing.expectEqual(@as(c_int, 0), surface_interface.event_count);
}
