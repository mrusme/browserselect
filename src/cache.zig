const std = @import("std");
const cexec = @import("cexec");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.cache);

const command: []const []const u8 = &.{"browserselect"};

pub const Store = struct {
    gpa: Allocator,
    io: std.Io,
    environ: std.process.Environ,
    ttl: std.Io.Duration,
    directory: ?[]const u8 = null,

    pub fn resolve(
        gpa: Allocator,
        io: std.Io,
        environ: std.process.Environ,
        timeout: i64,
    ) ?Store {
        if (timeout < 1) return null;
        return .{
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .ttl = .fromSeconds(timeout),
        };
    }

    pub fn recall(self: Store) ?[]u8 {
        var cache = self.open() orelse return null;
        defer cache.close();

        var entry = cache.get(command, self.ttl) catch |err| {
            log.warn("cannot read the remembered browser: {t}", .{err});
            return null;
        } orelse return null;
        defer entry.deinit(self.gpa);

        if (entry.stdout.len == 0) return null;
        return self.gpa.dupe(u8, entry.stdout) catch null;
    }

    pub fn remember(self: Store, id: []const u8) void {
        var cache = self.open() orelse return;
        defer cache.close();

        cache.put(command, .{
            .timestamp = cache.now(),
            .exit_code = 0,
            .stdout = id,
            .stderr = "",
        }) catch |err| log.warn("cannot remember {s}: {t}", .{ id, err });
    }

    fn open(self: Store) ?cexec.Cache {
        return cexec.Cache.open(self.gpa, self.io, .{
            .directory = self.directory,
            .environ = self.environ,
        }) catch |err| {
            log.warn("cannot open the cache: {t}", .{err});
            return null;
        };
    }
};

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    directory: []u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{
            .tmp = tmp,
            .directory = try std.fmt.allocPrint(
                testing.allocator,
                ".zig-cache/tmp/{s}/cache",
                .{tmp.sub_path},
            ),
        };
    }

    fn store(self: Fixture, timeout: i64) Store {
        var made = Store.resolve(testing.allocator, testing.io, .empty, timeout).?;
        made.directory = self.directory;
        return made;
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.directory);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

test "a timeout below one turns the cache off" {
    try testing.expect(Store.resolve(testing.allocator, testing.io, .empty, 0) == null);
    try testing.expect(Store.resolve(testing.allocator, testing.io, .empty, -1) == null);
    try testing.expect(Store.resolve(testing.allocator, testing.io, .empty, 1) != null);
}

test "a remembered browser comes back" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const store = fixture.store(3600);
    try testing.expect(store.recall() == null);

    store.remember("firefox.desktop");

    const recalled = store.recall().?;
    defer testing.allocator.free(recalled);
    try testing.expectEqualStrings("firefox.desktop", recalled);
}

test "a remembered browser is forgotten once it expires" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    fixture.store(3600).remember("w3m");
    const fresh = fixture.store(1).recall().?;
    testing.allocator.free(fresh);

    var cache = try cexec.Cache.open(testing.allocator, testing.io, .{
        .directory = fixture.directory,
    });
    defer cache.close();
    try cache.put(command, .{
        .timestamp = cache.now() - 120,
        .exit_code = 0,
        .stdout = "w3m",
        .stderr = "",
    });

    try testing.expect(fixture.store(60).recall() == null);

    const recalled = fixture.store(180).recall().?;
    defer testing.allocator.free(recalled);
    try testing.expectEqualStrings("w3m", recalled);
}

test "the newest choice replaces the one before it" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const store = fixture.store(3600);
    store.remember("firefox");
    store.remember("Chromium");

    const recalled = store.recall().?;
    defer testing.allocator.free(recalled);
    try testing.expectEqualStrings("Chromium", recalled);
}

test "the entry is stored where cexec stores the browserselect command" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    fixture.store(3600).remember("firefox");

    const stored = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{
        fixture.directory,
        &cexec.Cache.fileName(cexec.Cache.digest("browserselect")),
    });
    defer testing.allocator.free(stored);

    const contents = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        stored,
        testing.allocator,
        .limited(cexec.Cache.max_entry_bytes),
    );
    defer testing.allocator.free(contents);
    try testing.expect(std.mem.find(u8, contents, "firefox") != null);
}
