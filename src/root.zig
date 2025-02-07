const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;

pub const InotifyInst = struct {
    fd: i32,
};

/// Event Flags
pub const events = struct {
    /// Events suitable for mask parameter of `inotify_add_watch`
    pub const Mask = enum(u32) {
        in_access = 0x00000001, // File was accessed.
        in_modify = 0x00000002, // File was modified.
        in_attrib = 0x00000004, // Metadata changed.
        in_close_write = 0x00000008, // Writtable file was closed.
        in_close_nowrite = 0x00000010, // Unwrittable file closed.
        in_open = 0x00000020, // File was opened.
        in_moved_from = 0x00000040, // File was moved from X.
        in_moved_to = 0x00000080, // File was moved to Y.
        in_create = 0x00000100, // Subfile was created.
        in_delete = 0x00000200, // Subfile was deleted.
        in_delete_self = 0x00000400, // Self was deleted.
        in_move_self = 0x00000800, // Self was moved.
    };

    /// Helper events
    pub const Helper = enum(u32) {
        in_close = events.Mask.in_close_write | events.Mask.in_close_nowrite, // Close.
        in_move = events.Mask.in_moved_from | events.Mask.in_moved_to, // Moves.
    };

    /// Events sent by the kernel.
    pub const Kernel = enum(u32) {
        in_unmount = 0x00002000, // Backing fs was unmounted.
        in_q_overflow = 0x00004000, // Event queued overflowed.
        in_ignored = 0x00008000, // File was ignored.
    };

    /// Special flags
    pub const Special = enum(u32) {
        in_onlydir = 0x01000000, // Only watch the path if it is a directory.
        in_dont_follow = 0x02000000, // Do not follow a sym link.
        in_excl_unlink = 0x04000000, // Exclude events on unlinked objects.
        in_mask_create = 0x10000000, // Only create watches.
        in_mask_add = 0x20000000, // Add to the mask of an already existing watch.
        in_isdir = 0x40000000, // Event occurred against dir.
        in_oneshot = 0x80000000, // Only send event once.
    };

    /// All events suitable for mask parameter of `inotify_add_watch`
    pub const All = enum(u32) {
        in_all_events = events.Mask.in_access |
            events.Mask.in_modify |
            events.Mask.in_attrib |
            events.Mask.in_close_write |
            events.Mask.in_close_nowrite |
            events.Mask.in_open |
            events.Mask.in_moved_from |
            events.Mask.in_moved_to |
            events.Mask.in_create |
            events.Mask.in_delete |
            events.Mask.in_delete_self |
            events.Mask.in_move_self,
    };

    pub const Flags = packed union {
        mask: events.Mask,
        helper: events.Helper,
        kernel: events.Kernel,
        special: events.Special,
        all: events.All,
    };

    pub fn int(self: Flags) u32 {
        switch (self) {
            inline else => |val| return @intFromEnum(val),
        }
    }
};
