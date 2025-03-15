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

pub const WatchEntry = struct {
    watch: WatchDescriptor,
    path: []const u8,
    ignored: bool,
};

pub const Watch = struct {
    fd: EventQueueFD,
    entries: std.MultiArrayList(WatchEntry),

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
            .entries = .empty,
        };
        return watch;
    }

    pub fn deinit(self: *Watch, allocator: mem.Allocator) void {
        for (self.entries.items(.path)) |pth| {
            allocator.free(pth);
        }

        self.entries.deinit(allocator);
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
            self.entries.items(.watch),
            @as(WatchDescriptor, @enumFromInt(wd)),
            comp,
        );

        if (idx_maybe != null) {
            @branchHint(.unlikely);
            // Watch already exists.
            allocator.free(watch_path);
            return;
        }

        try self.entries.append(allocator, .{
            .path = watch_path,
            .watch = @enumFromInt(wd),
            .ignored = false,
        });
    }

    /// Remove watch with either `WatchDescriptor` or `[]u8`.
    /// Sends `.in_ignored` event to the queue.
    pub fn remove(self: *Watch, watch_or_path: anytype) void {
        const T = @TypeOf(watch_or_path);
        const info = @typeInfo(T);
        const slc = self.entries.slice();
        switch (info) {
            .pointer => {
                // TODO: Find a better way to validate a string-like type
                const is_a_string: []const u8 = watch_or_path;
                _ = is_a_string;
                const str: T = watch_or_path;
                for (
                    slc.items(.path),
                    slc.items(.watch),
                    slc.items(.ignored),
                    0..,
                ) |pth, wth, rm, idx| {
                    if (!rm and mem.eql(u8, pth, str)) {
                        posix.inotify_rm_watch(
                            @intFromEnum(self.fd),
                            @intFromEnum(wth),
                        );
                        slc.items(.ignored)[idx] = true;
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
                const idx_maybe = sort.binarySearch(WatchDescriptor, slc.items(.watch), wd, comp);
                if (idx_maybe) |idx| {
                    if (slc.items(.ignored)[idx]) {
                        @branchHint(.cold);
                        debug.panic("Trying to remove `{}`, but it was already removed.\n", .{slc.items(.watch)[idx]});
                    } else {
                        posix.inotify_rm_watch(
                            @intFromEnum(self.fd),
                            @intFromEnum(wd),
                        );
                        slc.items(.ignored)[idx] = true;
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
    debug.print("inotify event queue fd: {d}\n", .{watch.fd});
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

    var slc = watch.entries.slice();

    try testing.expectEqual(1, @intFromEnum(slc.items(.watch)[0]));
    try testing.expectEqual(2, @intFromEnum(slc.items(.watch)[1]));

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

    debug.print("{d}: watched file = {s}\n", .{
        slc.items(.watch)[0],
        slc.items(.path)[0],
    });
    try testing.expectEqualStrings(expected_path, slc.items(.path)[0]);
    debug.print("{d}: watched dir = {s}\n", .{
        slc.items(.watch)[1],
        slc.items(.path)[1],
    });
    try testing.expectEqualStrings(expected_path2, slc.items(.path)[1]);
    try testing.expectEqualSlices(bool, &.{ false, false }, slc.items(.ignored));

    const watch2: *Watch = try .init(testing.allocator, .empty);
    defer watch2.deinit(testing.allocator);

    try watch2.add(
        testing.allocator,
        "test/watched",
        .{ .in_access = true },
    );

    const slc2 = watch2.entries.slice();

    debug.print("{d}: watched dir2 = {s}\n", .{
        slc2.items(.watch)[0],
        slc2.items(.path)[0],
    });
    try testing.expectEqual(1, @intFromEnum(slc2.items(.watch)[0]));

    watch.remove(expected_path);
    try testing.expectEqualSlices(bool, &.{ true, false }, slc.items(.ignored));

    watch.remove(@as(WatchDescriptor, @enumFromInt(2)));
    try testing.expectEqualSlices(bool, &.{ true, true }, slc.items(.ignored));

    watch2.remove(@as(WatchDescriptor, @enumFromInt(1)));
    try testing.expectEqualSlices(bool, &.{true}, slc2.items(.ignored));

    try watch.add(
        testing.allocator,
        "test/watched/watched_file",
        .{ .in_access = true },
    );

    // update slice to include newest element
    slc = watch.entries.slice();

    debug.print("{d}: watched file = {s}\n", .{
        slc.items(.watch)[2],
        slc.items(.path)[2],
    });
    try testing.expectEqual(3, @intFromEnum(slc.items(.watch)[2]));
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
    const slc = watch.entries.slice();
    try testing.expectEqual(1, slc.items(.watch).len);
    try testing.expectEqualSlices(bool, &.{false}, slc.items(.ignored));
}

test {
    _ = @This();
    _ = @import("flags.zig");
}
