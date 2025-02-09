const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const mem = std.mem;
const path = std.fs.path;
const process = std.process;

const INotifyEvent = std.os.linux.inotify_event;

/// watched: the path associated with the event
/// flags: flags of the associated event
/// move_cookie: used to match `in_moved_from` and `in_moved_to`.
/// Otherwise it's always 0.
/// filename: optional filename associated with the event.
pub const Event = struct {
    flags: EventFlags,
    move_cookie: u32,
    watched: []const u8,
    filename: ?[]const u8,

    pub fn deinit(self: Event, allocator: mem.Allocator) void {
        if (self.filename) |name| {
            allocator.free(name);
        }
        allocator.free(self.watched);
    }
};

pub const WatchMap = std.AutoArrayHashMapUnmanaged(i32, []const u8);

pub const INotifyInitError = posix.INotifyInitError;
pub const WatchInitError = mem.Allocator.Error || INotifyInitError;
pub const INotifyAddWatchError = posix.INotifyAddWatchError;

pub const AddWatchError = error{
    UnsupportedRelativePath,
} || INotifyAddWatchError || mem.Allocator.Error;

pub const NextEventError = error{
    WatchNotFound,
} || posix.ReadError || mem.Allocator.Error;

pub const Watch = struct {
    inotify: Inotify,
    map: WatchMap,

    pub fn init(
        allocator: mem.Allocator,
        flags: InitFlags,
    ) WatchInitError!*Watch {
        const inotify: Inotify = try .init(flags);
        const watchmap: WatchMap = .empty;
        var watch = try allocator.create(Watch);
        watch.inotify = inotify;
        watch.map = watchmap;
        return watch;
    }

    /// Frees the backing map including the values.
    /// Closes the inotify instance.
    /// Frees itself.
    pub fn deinit(self: *Watch, allocator: mem.Allocator) void {
        const values = self.map.values();
        for (values) |v| {
            allocator.free(v);
        }
        self.map.deinit(allocator);
        self.inotify.deinit();
        allocator.destroy(self);
    }

    /// Does not add watch if pathname is already watched.
    pub fn addWatch(
        self: *Watch,
        allocator: mem.Allocator,
        pathname: []const u8,
        mask: EventFlags,
    ) AddWatchError!void {
        // TODO: Make relative path absolute path without realpath() somehow.
        const resolved = try path.resolvePosix(allocator, &.{pathname});
        errdefer allocator.free(resolved);

        if (!path.isAbsolutePosix(resolved)) {
            return AddWatchError.UnsupportedRelativePath;
        }

        const wd = try posix.inotify_add_watch(
            self.inotify.fd,
            resolved,
            @bitCast(mask),
        );
        const entry = try self.map.getOrPut(allocator, wd);
        if (!entry.found_existing) {
            entry.value_ptr.* = resolved;
        }
    }

    /// Returns the next event.
    /// Blocks unless non blocking option is set.
    /// Event lifetime is orthognal to Watch's. Caller must deinit
    /// each event.
    pub fn nextEvent(self: *Watch, allocator: mem.Allocator) NextEventError!Event {
        var buf: [@sizeOf(INotifyEvent) + posix.NAME_MAX + 1]u8 = undefined;
        const nread = try posix.read(self.inotify.fd, &buf);

        if (nread == 0) {
            @branchHint(.cold);
            unreachable; // only happens before Linux 2.6.21 when buffer is too small.
        }

        const event: *INotifyEvent = @alignCast(@ptrCast(buf[0..@sizeOf(INotifyEvent)]));

        const maybe_name = event.getName();

        const watch = self.map.get(event.wd) orelse return NextEventError.WatchNotFound;
        const watch_copy = try allocator.dupe(u8, watch);
        errdefer allocator.free(watch_copy);

        var filename: ?[]const u8 = undefined;
        if (maybe_name) |name| {
            filename = try allocator.dupe(u8, name);
        } else {
            filename = null;
        }

        return .{
            .flags = @bitCast(event.mask),
            .move_cookie = event.cookie,
            .watched = watch_copy,
            .filename = filename,
        };
    }
};

test Watch {
    const watch: *Watch = try .init(testing.allocator, .non_blocking);
    defer watch.deinit(testing.allocator);

    var pathbuf: [posix.PATH_MAX]u8 = undefined;
    const cwd = try posix.getcwd(&pathbuf);
    const watch_subdir = "test/watched";
    const watch_dir = try path.join(testing.allocator, &.{ cwd, watch_subdir });
    defer testing.allocator.free(watch_dir);

    try watch.addWatch(
        testing.allocator,
        watch_dir,
        .{ .in_open = true },
    );

    const touch = try process.Child.run(
        .{
            .allocator = testing.allocator,
            .argv = &.{ "touch", "test/watched/watched_file" },
        },
    );
    testing.allocator.free(touch.stderr);
    testing.allocator.free(touch.stdout);

    for (watch.map.values()) |val| {
        std.debug.print("{s}\n", .{val});
    }

    const event = try watch.nextEvent(testing.allocator);
    defer event.deinit(testing.allocator);

    try testing.expectEqualStrings(watch_dir, event.watched);
    try testing.expectEqualStrings("watched_file", event.filename.?);
    try testing.expectEqual(0, event.move_cookie);
    try testing.expectEqual(EventFlags{ .in_open = true }, event.flags);
    try testing.expectError(error.WouldBlock, watch.nextEvent(testing.allocator));
}

const Inotify = struct {
    fd: i32,

    fn init(flags: InitFlags) INotifyInitError!Inotify {
        const fd = try posix.inotify_init1(@bitCast(flags));
        return .{
            .fd = fd,
        };
    }

    fn deinit(self: Inotify) void {
        // TODO: Needs fsync?
        posix.close(self.fd);
    }
};

test Inotify {
    const instance1: Inotify = try .init(.empty);
    defer instance1.deinit();

    const instance2: Inotify = try .init(.non_blocking);
    defer instance2.deinit();

    const instance3: Inotify = try .init(.close_on_exec);
    defer instance3.deinit();

    const instance4: Inotify = try .init(.non_blocking_close_on_exec);
    defer instance4.deinit();
}

pub const InitFlags = packed struct(u32) {
    _padding1: u11 = 0,
    in_nonblock: bool = false,
    _padding2: u7 = 0,
    in_cloexec: bool = false,
    _padding3: u12 = 0,

    pub const empty: InitFlags = .{};
    pub const non_blocking: InitFlags = .{ .in_nonblock = true };
    pub const close_on_exec: InitFlags = .{ .in_cloexec = true };
    pub const non_blocking_close_on_exec: InitFlags = .{
        .in_cloexec = true,
        .in_nonblock = true,
    };
};

// TODO: Make flags doc clearer.
// take from manual when calrification is warranted.
//
// TODO: Fix and test for big endian

/// Flags used by inotify.
/// See manual `inotify(7)` for details.
pub const EventFlags = packed struct(u32) {
    // Events suitable for mask parameter of `inotify_add_watch`
    in_access: bool = false, // File was accessed.
    in_modify: bool = false, // file was modified.
    in_attrib: bool = false, // Metadata changed.
    in_close_write: bool = false, // Writtable file was closed.
    in_close_nowrite: bool = false, // Unwrittable file closed.
    in_open: bool = false, // File was opened.
    in_moved_from: bool = false, // File was moved from X.
    in_moved_to: bool = false, // File was moved to Y.
    in_create: bool = false, // Subfile was created.
    in_delete: bool = false, // Subfile was deleted.
    in_delete_self: bool = false, // Self was deleted.
    in_move_self: bool = false, // self was moved.
    _padding1: u1 = 0, // bit 13
    // Events sent by the kernel.
    in_unmount: bool = false, // Backing fs was unmounted.
    in_q_overflow: bool = false, // Event queued overflowed.
    in_ignored: bool = false, // File was ignored.
    _padding2: u8 = 0, // bits 17 to 24
    // Special flags
    in_onlydir: bool = false, // Only watch the path if it is a directory
    in_dont_follow: bool = false, // Do not follow a sym link.
    in_excl_unlink: bool = false, // Exclude events on unlinked objects.
    _padding3: u1 = 0, // bit 28
    in_mask_create: bool = false, // Only create watches.
    in_mask_add: bool = false, // Add to the mask of an already existing watch.
    in_isdir: bool = false, // Event occuurred against dir.
    in_oneshot: bool = false, // Only send event once.

    pub const all: EventFlags = .{
        .in_access = true,
        .in_modify = true,
        .in_attrib = true,
        .in_close_write = true,
        .in_close_nowrite = true,
        .in_open = true,
        .in_moved_from = true,
        .in_moved_to = true,
        .in_create = true,
        .in_delete = true,
        .in_delete_self = true,
        .in_move_self = true,
    };

    pub const in_close: EventFlags = .{
        .in_close_nowrite = true,
        .in_close_write = true,
    };

    pub const in_move: EventFlags = .{
        .in_moved_from = true,
        .in_moved_to = true,
    };
};
