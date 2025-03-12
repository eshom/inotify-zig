const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const mem = std.mem;
const path = std.fs.path;
const process = std.process;
const INotifyEvent = std.os.linux.inotify_event;
pub const INotifyInitError = posix.INotifyInitError;
pub const INotifyAddWatchError = posix.INotifyAddWatchError;

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

pub const EventSlice = struct {
    events: []Event,

    pub fn init(allocator: mem.Allocator, watch: *Watch) NextEventError!EventSlice {
        return .{ .events = try watch.nextEvents(allocator) };
    }

    pub fn deinit(self: EventSlice, allocator: mem.Allocator) void {
        for (self.events) |ev| {
            ev.deinit(allocator);
        }
    }
};

pub const WatchMap = std.AutoArrayHashMapUnmanaged(i32, []const u8);

pub const WatchInitError = mem.Allocator.Error || INotifyInitError;
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

    /// Does nothing if watch doesn't exist.
    /// Removing a watch causes an `.in_ignored` event to be generated.
    pub fn removeWatch(self: *Watch, pathname: []const u8) void {
        const wds = self.map.keys();
        const paths = self.map.values();

        // TODO: A version of this where user provides wd key directly would
        // be faster.
        for (wds, paths) |w, p| {
            if (std.mem.eql(u8, p, pathname)) {
                posix.inotify_rm_watch(self.inotify.fd, w);
                break;
            }
        }
    }

    fn countToFirstNonNull(buf: []const u8) usize {
        var count = 0;
        for (buf) |b| {
            if (b == '\x00') {
                count += 1;
            } else {
                return count;
            }
        }
    }

    fn readEvent(
        self: *Watch,
        allocator: mem.Allocator,
        events: []const u8,
    ) NextEventError!?struct { Event, usize } {
        // Enough to hold at least one event
        var buf: [@sizeOf(INotifyEvent) + posix.NAME_MAX + 1]u8 = undefined;
        var out_offset: usize = 0;

        const in_event: *INotifyEvent = @alignCast(@ptrCast(buf[0..@sizeOf(INotifyEvent)]));
        const maybe_name = in_event.getName();

        var filename: ?[]const u8 = undefined;

        if (maybe_name) |name| {
            const offset_addition = @sizeOf(INotifyEvent) + name.len;
            if (offset_addition >= events.len) return null;
            out_offset += offset_addition;
            filename = try allocator.dupe(u8, name);
            std.debug.print("cur_read = {d}\n", .{@sizeOf(INotifyEvent) + name.len});
        } else {
            const offset_addition = @sizeOf(INotifyEvent);
            if (offset_addition >= events.len) return null;
            out_offset += offset_addition;
            std.debug.print("cur_read = {d}\n", .{@sizeOf(INotifyEvent)});
            filename = null;
        }

        errdefer {
            if (filename) |file| {
                allocator.free(file);
            }
        }

        const watch = self.map.get(in_event.wd) orelse return NextEventError.WatchNotFound;
        const watch_copy = try allocator.dupe(u8, watch);
        errdefer allocator.free(watch_copy);

        const out_event: Event = .{
            .flags = @bitCast(in_event.mask),
            .move_cookie = in_event.cookie,
            .watched = watch_copy,
            .filename = filename,
        };

        return .{ out_event, out_offset };
    }

    /// Returns slice of next events.
    /// Blocks unless non blocking option is set.
    /// Event lifetime is orthognal to Watch's. Caller must deinit Events
    pub fn nextEvents(self: *Watch, allocator: mem.Allocator) NextEventError![]Event {
        var buf: [@sizeOf(INotifyEvent) + posix.NAME_MAX + 1]u8 = undefined;
        var offset: usize = 0;

        // Can be more than one event
        const nread = try posix.read(self.inotify.fd, &buf);
        std.debug.print("nread = {d}\n", .{nread});

        if (nread == 0) {
            @branchHint(.cold);
            unreachable; // only happens before Linux 2.6.21 when buffer is too small.
        }

        const buf_start_size = 10;
        const buf_increment = 10;
        var events_buf: []Event = try allocator.alloc(Event, buf_start_size);
        errdefer allocator.free(events_buf);

        var idx: usize = 0;
        while (true) : (idx += 1) {
            const result = try self.readEvent(
                allocator,
                buf[offset..nread],
            ) orelse break;
            const ev, offset = result;

            if (idx >= events_buf.len) {
                events_buf = try allocator.realloc(events_buf, events_buf.len + buf_increment);
            } else {
                events_buf[idx] = ev;
            }
        }

        return events_buf;
    }
};

test Watch {
    @breakpoint();
    const watch: *Watch = try .init(testing.allocator, .non_blocking);
    defer watch.deinit(testing.allocator);

    var pathbuf: [posix.PATH_MAX]u8 = undefined;
    const cwd = try posix.getcwd(&pathbuf);

    const watch_dir = try path.join(testing.allocator, &.{
        cwd,
        "test/watched",
    });
    defer testing.allocator.free(watch_dir);

    const watch_file = try path.join(testing.allocator, &.{
        watch_dir,
        "watched_file2",
    });
    defer testing.allocator.free(watch_file);

    try watch.addWatch(
        testing.allocator,
        watch_dir,
        .{ .in_open = true, .in_ignored = true },
    );

    try watch.addWatch(
        testing.allocator,
        watch_file,
        .{ .in_open = true, .in_ignored = true },
    );

    const touch = try process.Child.run(
        .{
            .allocator = testing.allocator,
            .argv = &.{ "touch", "test/watched/watched_file" },
        },
    );
    testing.allocator.free(touch.stderr);
    testing.allocator.free(touch.stdout);

    const touch2 = try process.Child.run(
        .{
            .allocator = testing.allocator,
            .argv = &.{ "touch", "test/watched/watched_file2" },
        },
    );
    testing.allocator.free(touch2.stderr);
    testing.allocator.free(touch2.stdout);

    watch.removeWatch(watch_dir);
    watch.removeWatch(watch_file);

    const events: EventSlice = try .init(testing.allocator, watch);

    try testing.expectEqualStrings(watch_dir, events.events[0].watched);
    try testing.expectEqualStrings("watched_file", events.events[0].filename.?);
    try testing.expectEqual(0, events.events[0].move_cookie);

    try testing.expectEqual(EventFlags{ .in_open = true }, events.events[0].flags);
    try testing.expectEqual(EventFlags{ .in_open = true }, events.events[1].flags);
    try testing.expectEqual(EventFlags{ .in_ignored = true }, events.events[2].flags);
    try testing.expectEqual(EventFlags{ .in_ignored = true }, events.events[3].flags);

    // try testing.expectError(error.WouldBlock, watch.nextEvents(testing.allocator));
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
