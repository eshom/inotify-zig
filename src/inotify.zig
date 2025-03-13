const std = @import("std");
const math = std.math;
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;
const debug = std.debug;
const mem = std.mem;
const path = std.fs.path;
const process = std.process;
const fmt = std.fmt;
const sort = std.sort;
const INotifyEvent = linux.inotify_event;

pub const flags = @import("flags.zig");

pub const EventQueueFD = enum(i32) {
    _,
};

pub const WatchDescriptor = enum(i32) {
    _,
};

pub const Watch = struct {
    fd: EventQueueFD,
    watches: std.ArrayListUnmanaged(WatchDescriptor),
    paths: std.ArrayListUnmanaged([]const u8),
    ignored: std.ArrayListUnmanaged(bool),

    fn comp(a: WatchDescriptor, b: WatchDescriptor) math.Order {
        const a_ = @intFromEnum(a);
        const b_ = @intFromEnum(b);
        if (a_ == b_) {
            return .eq;
        } else if (a_ < b_) {
            return .lt;
        } else if (a_ > b_) {
            return .gt;
        } else {
            @branchHint(.cold);
            unreachable;
        }
    }

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
            .ignored = .empty,
        };
        return watch;
    }

    pub fn deinit(self: *Watch, allocator: mem.Allocator) void {
        for (self.paths.items) |pth| {
            allocator.free(pth);
        }

        self.paths.deinit(allocator);
        self.watches.deinit(allocator);
        self.ignored.deinit(allocator);

        posix.close(@intFromEnum(self.fd));

        allocator.destroy(self);
    }

    // TODO: Test invalid path inputs (fuzz!)
    pub fn add(
        self: *Watch,
        allocator: mem.Allocator,
        pathname: []const u8,
        mask: flags.EventFlags,
    ) (posix.INotifyAddWatchError ||
        posix.GetCwdError ||
        mem.Allocator.Error)!void {
        var path_buf: [posix.PATH_MAX]u8 = undefined;

        const cwd = try posix.getcwd(&path_buf);
        if ((posix.PATH_MAX -| pathname.len -| cwd.len) == 0) return error.NameTooLong;

        const watch_path = try path.resolve(allocator, &.{ cwd, pathname });
        errdefer allocator.free(watch_path);

        // For an inotify instance, wd values are never reused and keep increasing.
        // This is why you cannot use them as indices to an array.
        const wd = try posix.inotify_add_watch(
            @intFromEnum(self.fd),
            watch_path,
            @bitCast(mask),
        );
        errdefer posix.inotify_rm_watch(@intFromEnum(self.fd), wd);

        const idx_maybe = sort.binarySearch(
            WatchDescriptor,
            self.watches.items,
            @as(WatchDescriptor, @enumFromInt(wd)),
            comp,
        );

        if (idx_maybe) |idx| {
            @branchHint(.unlikely);
            // Watch already exists.
            _ = idx;
            allocator.free(watch_path);
            return;
        } else {
            @branchHint(.likely);
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

            try self.ignored.append(allocator, false);
        }
    }

    /// Remove watch with either `WatchDescriptor` or `[]u8`.
    /// Sends `.in_ignored` event to the queue.
    pub fn remove(self: *Watch, watch_or_path: anytype) void {
        const T = @TypeOf(watch_or_path);
        const info = @typeInfo(T);
        switch (info) {
            .pointer => {
                // TODO: Find a better way to validate a string-like type
                const is_a_string: []const u8 = watch_or_path;
                _ = is_a_string;
                const str: T = watch_or_path;
                for (
                    self.paths.items,
                    self.watches.items,
                    self.ignored.items,
                    0..,
                ) |pth, wth, rm, idx| {
                    if (!rm and mem.eql(u8, pth, str)) {
                        posix.inotify_rm_watch(
                            @intFromEnum(self.fd),
                            @intFromEnum(wth),
                        );
                        self.ignored.items[idx] = true;
                        break;
                    }
                } else {
                    @branchHint(.cold);
                    debug.panic("Could not find a watch associated with path: {s}\n", .{str});
                }
            },
            .@"enum" => {
                if (T != WatchDescriptor) {
                    @compileError(fmt.comptimePrint("Expected `WatchDescriptor` type, found `{}`", .{T}));
                }
                const wd: T = watch_or_path;
                const idx_maybe = sort.binarySearch(WatchDescriptor, self.watches.items, wd, comp);
                if (idx_maybe) |idx| {
                    if (self.ignored.items[idx]) {
                        @branchHint(.cold);
                        debug.panic("Trying to remove `{}`, but it was already removed.\n", .{self.watches.items[idx]});
                    } else {
                        posix.inotify_rm_watch(
                            @intFromEnum(self.fd),
                            @intFromEnum(wd),
                        );
                        self.ignored.items[idx] = true;
                    }
                } else {
                    @branchHint(.cold);
                    debug.panic("Could not find watch descriptor associted with `{}`\n", .{wd});
                }
            },
            else => @compileError(fmt.comptimePrint("Expected either a string-like type or `WatchDescriptor`, found `{}`\n", .{T})),
        }
    }
};

test "init and deinit inotify" {
    const watch: *Watch = try .init(testing.allocator, .empty);
    std.debug.print("inotify event queue fd: {d}\n", .{watch.fd});
    defer watch.deinit(testing.allocator);
}

test "add and remove watches" {
    const watch: *Watch = try .init(testing.allocator, .empty);
    defer watch.deinit(testing.allocator);

    try testing.expectError(
        error.OutOfMemory,
        Watch.init(testing.failing_allocator, .empty),
    );

    try watch.add(
        testing.allocator,
        "test/watched/watched_file",
        .{ .in_access = true },
    );

    try testing.expectError(error.OutOfMemory, watch.add(
        testing.failing_allocator,
        "test/watched/watched_file",
        .{ .in_access = true },
    ));

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
    try testing.expectEqualSlices(bool, &.{ false, false }, watch.ignored.items);

    const watch2: *Watch = try .init(testing.allocator, .empty);
    defer watch2.deinit(testing.allocator);

    try watch2.add(
        testing.allocator,
        "test/watched",
        .{ .in_access = true },
    );
    std.debug.print("{d}: watched dir2 = {s}\n", .{
        watch2.watches.items[0],
        watch2.paths.items[0],
    });
    try testing.expectEqual(1, @intFromEnum(watch2.watches.items[0]));

    watch.remove(expected_path);
    try testing.expectEqualSlices(bool, &.{ true, false }, watch.ignored.items);

    watch.remove(@as(WatchDescriptor, @enumFromInt(2)));
    try testing.expectEqualSlices(bool, &.{ true, true }, watch.ignored.items);

    watch2.remove(@as(WatchDescriptor, @enumFromInt(1)));
    try testing.expectEqualSlices(bool, &.{true}, watch2.ignored.items);

    try watch.add(
        testing.allocator,
        "test/watched/watched_file",
        .{ .in_access = true },
    );

    std.debug.print("{d}: watched file = {s}\n", .{
        watch.watches.items[2],
        watch.paths.items[2],
    });
    try testing.expectEqual(3, @intFromEnum(watch.watches.items[2]));
    watch.remove(@as(WatchDescriptor, @enumFromInt(3)));
}

test "multiple watches for the same file" {
    const watch: *Watch = try .init(testing.allocator, .empty);
    defer watch.deinit(testing.allocator);
    for (0..10) |idx| {
        _ = idx;
        try watch.add(
            testing.allocator,
            "test/watched/watched_file",
            .{ .in_access = true },
        );
    }
    try testing.expectEqual(1, watch.watches.items.len);
    try testing.expectEqualSlices(bool, &.{false}, watch.ignored.items);
}

test {
    _ = @import("flags.zig");
}
