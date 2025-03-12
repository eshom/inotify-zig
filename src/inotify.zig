const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;
const mem = std.mem;
const path = std.fs.path;
const process = std.process;
const INotifyEvent = linux.inotify_event;

/// Flags used by inotify.
/// See manual `inotify(7)` for details.
pub const EventFlags = packed struct(u32) {
    // Events suitable for mask parameter of `inotify_add_watch`
    in_access: bool = false,
    in_modify: bool = false,
    in_attrib: bool = false,
    in_close_write: bool = false,
    in_close_nowrite: bool = false,
    in_open: bool = false,
    in_moved_from: bool = false,
    in_moved_to: bool = false,
    in_create: bool = false,
    in_delete: bool = false,
    in_delete_self: bool = false,
    in_move_self: bool = false,
    _padding1: u1 = 0, // bit 13
    // Events sent by the kernel.
    in_unmount: bool = false,
    in_q_overflow: bool = false,
    in_ignored: bool = false,
    _padding2: u8 = 0,
    // Special flags
    in_onlydir: bool = false,
    in_dont_follow: bool = false,
    in_excl_unlink: bool = false,
    _padding3: u1 = 0, // bit 28
    in_mask_create: bool = false,
    in_mask_add: bool = false,
    in_isdir: bool = false,
    in_oneshot: bool = false,

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
