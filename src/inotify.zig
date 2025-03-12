const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;
const mem = std.mem;
const path = std.fs.path;
const process = std.process;
const INotifyEvent = linux.inotify_event;

pub const flags = @import("flags.zig");

pub const EventQueueFD = enum(i32) {
    _,
};

pub const Watch = struct {
    fd: EventQueueFD,

    pub fn init(
        allocator: mem.Allocator,
        init_flags: flags.InitFlags,
    ) (mem.Allocator.Error || posix.INotifyInitError)!*Watch {
        const watch: *Watch = try allocator.create(Watch);

        const fd: EventQueueFD = @enumFromInt(try posix.inotify_init1(@bitCast(init_flags)));

        watch.* = .{
            .fd = fd,
        };
        return watch;
    }

    pub fn deinit(self: *Watch, allocator: mem.Allocator) void {
        posix.close(@intFromEnum(self.fd));
        allocator.destroy(self);
    }
};

test "init and deinit inotify" {
    const watch: *Watch = try .init(testing.allocator, .empty);
    std.debug.print("inotify event queue fd: {d}\n", .{watch.fd});
    defer watch.deinit(testing.allocator);
}

test {
    _ = @import("flags.zig");
}
