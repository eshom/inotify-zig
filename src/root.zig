const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const InotifyInitError = posix.INotifyInitError;

pub const Inotify = struct {
    fd: i32,

    pub fn init(flags: InitFlags) InotifyInitError!Inotify {
        const fd = try posix.inotify_init1(@bitCast(flags));
        return .{
            .fd = fd,
        };
    }

    pub fn deinit(self: Inotify) void {
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
};

// TODO: Make flags doc clearer.
// take from manual when calrification is warranted.

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

    pub const watchables: EventFlags = .{
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

    pub const specials: EventFlags = .{
        .in_dont_follow = true,
        .in_excl_unlink = true,
        .in_mask_add = true,
        .in_oneshot = true,
        .in_onlydir = true,
        .in_mask_create = true,
    };

    pub const returnables: EventFlags = .{
        .in_ignored = true,
        .in_isdir = true,
        .in_q_overflow = true,
        .in_unmount = true,
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
