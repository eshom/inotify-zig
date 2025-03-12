const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;
const debug = std.debug;
const mem = std.mem;
const path = std.fs.path;
const process = std.process;
const fmt = std.fmt;
const INotifyEvent = linux.inotify_event;

pub const flags = @import("flags.zig");

pub const EventQueueFD = enum(i32) {
    _,
};

pub const WatchDescriptor = enum(i32) {
    _,
};

// TODO: If watch descriptor is always increasing by one, `watches` and `paths`
// can be simplified to just a single one-indexed array.
pub const Watch = struct {
    fd: EventQueueFD,
    watches: std.ArrayListUnmanaged(WatchDescriptor),
    paths: std.ArrayListUnmanaged([]const u8),
    removed: std.ArrayListUnmanaged(bool),

    pub fn init(
        allocator: mem.Allocator,
        init_flags: flags.InitFlags,
    ) (mem.Allocator.Error || posix.INotifyInitError)!*Watch {
        const watch: *Watch = try allocator.create(Watch);
        errdefer allocator.destroy(watch);

        const fd: EventQueueFD = @enumFromInt(
            try posix.inotify_init1(@bitCast(init_flags)),
        );
        errdefer posix.close(@intFromEnum(fd));

        watch.* = .{
            .fd = fd,
            .watches = .empty,
            .paths = .empty,
            .removed = .empty,
        };
        return watch;
    }

    pub fn deinit(self: *Watch, allocator: mem.Allocator) void {
        for (self.paths.items) |pth| {
            allocator.free(pth);
        }

        self.paths.deinit(allocator);
        self.watches.deinit(allocator);
        self.removed.deinit(allocator);

        posix.close(@intFromEnum(self.fd));

        allocator.destroy(self);
    }

    pub fn add(
        self: *Watch,
        allocator: mem.Allocator,
        pathname: []const u8,
        mask: flags.EventFlags,
    ) (posix.INotifyAddWatchError ||
        posix.GetCwdError ||
        mem.Allocator.Error)!void {
        // TODO: Consider creating a buffer on the stack
        const path_buf = try allocator.alloc(u8, posix.PATH_MAX);
        defer allocator.free(path_buf);

        const cwd = try posix.getcwd(path_buf);
        // TODO: Test invalid path inputs (fuzz!)
        const watch_path = try path.resolve(allocator, &.{ cwd, pathname });
        errdefer allocator.free(watch_path);

        const wd = try posix.inotify_add_watch(@intFromEnum(self.fd), watch_path, @bitCast(mask));

        try self.paths.append(allocator, watch_path);
        errdefer {
            debug.assert(self.paths.items.len > 0);
            const str = self.paths.pop().?;
            allocator.free(str);
        }

        try self.watches.append(allocator, @enumFromInt(wd));
        errdefer {
            debug.assert(self.paths.items.len > 0);
            const w = self.paths.pop().?;
            allocator.free(w);
        }

        try self.removed.append(allocator, false);
    }

    /// Remove watch with either `WatchDescriptor` or `[]const u8`.
    /// Sends `.in_ignored` event to the queue.
    pub fn remove(self: *Watch, watch_or_path: anytype) void {
        const T = @TypeOf(watch_or_path);
        switch (T) {
            []const u8 => |str| {
                for (
                    self.paths.items,
                    self.watches.items,
                    self.removed.items,
                    0..,
                ) |pth, wth, rm, idx| {
                    if (!rm and mem.eql(u8, pth, str)) {
                        posix.inotify_rm_watch(
                            @intFromEnum(self.fd),
                            @intFromEnum(wth),
                        );
                        self.removed.items[idx] = true;
                    }
                }
            },
            //TODO: Binary search instead of linear. The watch descriptors
            // are in increasing order.
            WatchDescriptor => |wd| {
                for (
                    self.watches.items,
                    self.removed.items,
                    0..,
                ) |wth, rm, idx| {
                    if (!rm and wd == wth) {
                        posix.inotify_rm_watch(
                            @intFromEnum(self.fd),
                            @intFromEnum(wth),
                        );
                        self.removed.items[idx] = true;
                    }
                }
            },
            else => @compileError("Expected either `[]const u8` or `WatchDescriptor`. Found " ++ fmt.comptimePrint("{}", .{T})),
        }
    }
};

test "init and deinit inotify" {
    const watch: *Watch = try .init(testing.allocator, .empty);
    std.debug.print("inotify event queue fd: {d}\n", .{watch.fd});
    defer watch.deinit(testing.allocator);
}

test "add a watch" {
    const watch: *Watch = try .init(testing.allocator, .empty);
    defer watch.deinit(testing.allocator);

    try watch.add(
        testing.allocator,
        "test/watched/watched_file",
        .{ .in_access = true },
    );

    try watch.add(
        testing.allocator,
        "test/watched",
        .{ .in_access = true },
    );

    try testing.expectEqual(1, @intFromEnum(watch.watches.items[0]));
    try testing.expectEqual(2, @intFromEnum(watch.watches.items[1]));

    var buf: [posix.PATH_MAX]u8 = undefined;
    const cwd = try posix.getcwd(&buf);
    const expected_path = try path.join(
        testing.allocator,
        &.{ cwd, "test/watched/watched_file" },
    );
    defer testing.allocator.free(expected_path);

    const expected_path2 = try path.join(
        testing.allocator,
        &.{ cwd, "test/watched" },
    );
    defer testing.allocator.free(expected_path2);

    std.debug.print("{d}: watched file = {s}\n", .{
        watch.watches.items[0],
        watch.paths.items[0],
    });
    try testing.expectEqualStrings(expected_path, watch.paths.items[0]);
    std.debug.print("{d}: watched dir = {s}\n", .{
        watch.watches.items[1],
        watch.paths.items[1],
    });
    try testing.expectEqualStrings(expected_path2, watch.paths.items[1]);
}

test {
    _ = @import("flags.zig");
}
