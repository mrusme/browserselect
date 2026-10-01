const std = @import("std");
const Box = @import("box.zig").Box;
const c = @import("c.zig");
const capture = @import("capture.zig");
const pixels = @import("pixels.zig");
const sway = @import("sway.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.backdrop);

const backdrop_class = "browserselect-backdrop";
const shrink_factor = 4;

pub const Source = struct {
    gpa: Allocator,
    io: std.Io,
    socket: ?[]const u8,

    pub fn of(
        gpa: Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        wanted: bool,
    ) ?Source {
        if (!wanted) return null;

        const socket = environ.get("SWAYSOCK") orelse "";
        return .{ .gpa = gpa, .io = io, .socket = if (socket.len > 0) socket else null };
    }
};

pub const Placement = enum { placed, missing, failed };

pub const Backdrop = struct {
    source: Source,
    socket: []const u8,
    output: Box,
    texture: *c.GdkTexture,
    fixed: *c.GtkFixed = undefined,
    picture: *c.GtkWidget = undefined,

    pub fn take(source: Source) ?Backdrop {
        const socket = source.socket orelse {
            log.warn(
                "menu.static_blur needs sway, however $SWAYSOCK is not set, " ++
                    "so the popup has no blurred background",
                .{},
            );
            return null;
        };
        const display = c.waylandDisplay() orelse {
            log.warn("menu.static_blur needs a Wayland session, so the popup has no blurred background", .{});
            return null;
        };

        const gpa = source.gpa;
        const reply = sway.request(gpa, source.io, socket, .get_outputs) catch |err| {
            log.warn("cannot ask sway for its outputs: {t}, so the popup has no blurred background", .{err});
            return null;
        };
        defer gpa.free(reply);

        const parsed = std.json.parseFromSlice(std.json.Value, gpa, reply, .{}) catch {
            log.warn("sway answered the output query with something other than JSON", .{});
            return null;
        };
        defer parsed.deinit();

        const focused = sway.focusedOutput(parsed.value) orelse {
            log.warn("sway reports no focused output, so the popup has no blurred background", .{});
            return null;
        };

        const shot = capture.Capture.open(gpa, display) orelse return null;
        defer shot.close();

        const screen = screenNamed(shot, focused.name) orelse {
            log.warn("no monitor is named {s}, so the popup has no blurred background", .{focused.name});
            return null;
        };

        const texture = blurred(gpa, shot, screen) orelse return null;
        return .{ .source = source, .socket = socket, .output = screen.logical, .texture = texture };
    }

    pub fn widget(self: *Backdrop) *c.GtkWidget {
        const picture = c.gtk_picture_new();
        c.gtk_picture_set_paintable(c.cast(c.GtkPicture, picture), c.cast(c.GdkPaintable, self.texture));
        c.gtk_picture_set_content_fit(c.cast(c.GtkPicture, picture), .fill);
        c.gtk_widget_set_size_request(picture, self.output.width, self.output.height);
        c.gtk_widget_add_css_class(picture, backdrop_class);
        c.g_object_unref(self.texture);

        const fixed = c.cast(c.GtkFixed, c.gtk_fixed_new());
        c.gtk_fixed_put(fixed, picture, 0, 0);
        c.gtk_widget_set_can_target(c.cast(c.GtkWidget, fixed), c.FALSE);

        self.fixed = fixed;
        self.picture = picture;
        return c.cast(c.GtkWidget, fixed);
    }

    pub fn place(self: *Backdrop, origin_x: f64, origin_y: f64) Placement {
        const window = self.ownWindow() catch return .failed;
        const found = window orelse return .missing;

        const x = @as(f64, @floatFromInt(self.output.x - found.x)) - origin_x;
        const y = @as(f64, @floatFromInt(self.output.y - found.y)) - origin_y;
        c.gtk_fixed_move(self.fixed, self.picture, x, y);
        return .placed;
    }

    pub fn hide(self: *Backdrop) void {
        c.gtk_widget_set_visible(c.cast(c.GtkWidget, self.fixed), c.FALSE);
    }

    fn ownWindow(self: *Backdrop) error{Unreadable}!?Box {
        const gpa = self.source.gpa;
        const reply = sway.request(gpa, self.source.io, self.socket, .get_tree) catch |err| {
            log.warn("cannot read the sway tree: {t}, so the popup has no blurred background", .{err});
            return error.Unreadable;
        };
        defer gpa.free(reply);

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), reply, .{}) catch {
            log.warn("sway answered the tree query with something other than JSON", .{});
            return error.Unreadable;
        };

        var found: std.ArrayList(sway.Window) = .empty;
        sway.collect(arena.allocator(), parsed.value, &found) catch return error.Unreadable;
        return sway.rectOfPid(found.items, std.c.getpid());
    }
};

fn screenNamed(shot: *capture.Capture, name: []const u8) ?capture.Screen {
    for (shot.screens.items) |screen| {
        const connector = c.gdk_monitor_get_connector(screen.monitor) orelse continue;
        if (std.mem.eql(u8, std.mem.span(connector), name)) return screen;
    }
    return null;
}

fn blurred(gpa: Allocator, shot: *capture.Capture, screen: capture.Screen) ?*c.GdkTexture {
    const frame = shot.grab(screen) orelse return null;
    const composed = capture.compose(screen, frame);
    frame.release();
    const surface = composed orelse return null;
    defer c.cairo_surface_destroy(surface);

    const across: usize = @intCast(c.cairo_image_surface_get_width(surface));
    const down: usize = @intCast(c.cairo_image_surface_get_height(surface));
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
    const data = c.cairo_image_surface_get_data(surface) orelse return null;

    const scale = @as(f64, @floatFromInt(across)) / @as(f64, @floatFromInt(@max(screen.logical.width, 1)));
    const factor: usize = @intFromFloat(@max(1, @round(shrink_factor * scale)));

    const planes = pixels.shrink(gpa, data[0 .. stride * down], across, down, stride, factor) catch {
        log.warn("out of memory while shrinking the screen", .{});
        return null;
    };
    defer planes.deinit(gpa);

    pixels.blur(gpa, planes) catch {
        log.warn("out of memory while blurring the screen", .{});
        return null;
    };

    const bytes = gpa.alloc(u8, planes.width * planes.height * 3) catch {
        log.warn("out of memory while packing the blurred screen", .{});
        return null;
    };
    defer gpa.free(bytes);
    pixels.pack(planes, bytes);

    const shared = c.g_bytes_new(bytes.ptr, bytes.len);
    defer c.g_bytes_unref(shared);

    return c.gdk_memory_texture_new(
        @intCast(planes.width),
        @intCast(planes.height),
        .r8g8b8,
        shared,
        planes.width * 3,
    );
}
