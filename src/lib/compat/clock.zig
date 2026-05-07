//! Code taken from 0.15.2 `std.posix`. See README.md for license and details.
const builtin = @import("builtin");
const std = @import("std");

const native_os = builtin.os.tag;

pub const GetTimeError = error{UnsupportedClock} || std.posix.UnexpectedError;

pub fn gettime(clock_id: std.posix.system.clockid_t) GetTimeError!std.posix.system.timespec {
    var tp: std.posix.system.timespec = undefined;

    if (native_os == .windows) {
        @compileError("Windows does not support POSIX; use Windows-specific API or cross-platform std.time API");
    } else if (native_os == .wasi and !builtin.link_libc) {
        var ts: std.posix.system.timestamp_t = undefined;
        switch (std.posix.system.clock_time_get(clock_id, 1, &ts)) {
            .SUCCESS => {
                tp = .{
                    .sec = @intCast(ts / std.time.ns_per_s),
                    .nsec = @intCast(ts % std.time.ns_per_s),
                };
            },
            .INVAL => return error.UnsupportedClock,
            else => |err| return std.posix.unexpectedErrno(err),
        }
        return tp;
    }

    switch (std.posix.errno(std.posix.system.clock_gettime(clock_id, &tp))) {
        .SUCCESS => return tp,
        .FAULT => unreachable,
        .INVAL => return error.UnsupportedClock,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}
