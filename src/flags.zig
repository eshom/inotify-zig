const std = @import("std");
const testing = std.testing;

pub fn @"or"(a: EventFlags, b: EventFlags) EventFlags {
    const aint: u32 = @bitCast(a);
    const bint: u32 = @bitCast(b);
    return @bitCast(aint | bint);
}

test @"or" {
    const a: EventFlags = .in_close;
    const b: EventFlags = .in_move;
    const expected: EventFlags = .{
        .in_close_nowrite = true,
        .in_close_write = true,
        .in_moved_from = true,
        .in_moved_to = true,
    };
    try testing.expectEqual(expected, @"or"(a, b));
}

pub fn @"and"(a: EventFlags, b: EventFlags) EventFlags {
    const aint: u32 = @bitCast(a);
    const bint: u32 = @bitCast(b);
    return @bitCast(aint & bint);
}

test @"and" {
    const a: EventFlags = .{
        .in_open = true,
        .in_access = true,
    };
    const b: EventFlags = .{
        .in_open = true,
        .in_delete = true,
    };
    const expected: EventFlags = .{
        .in_open = true,
    };
    try testing.expectEqual(expected, @"and"(a, b));
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
