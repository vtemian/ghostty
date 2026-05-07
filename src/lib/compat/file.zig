//! Code taken from 0.15.2 `std.posix` and `std.fs.file`. See README.md for
//! license and details.
const builtin = @import("builtin");
const std = @import("std");

pub const ReadToEndAllocError = error{ FileTooBig, BytesReadMismatch } ||
    std.Io.File.StatError ||
    std.Io.File.ReadStreamingError ||
    std.mem.Allocator.Error;

/// This is a much simpler `readToEndAlloc` that just pre-allocates the memory
/// for the file ahead of time, and errors out if the size is larger than
/// `max_bytes`.
///
/// Caller owns the memory.
pub fn readToEndAlloc(file: std.Io.File, alloc: std.mem.Allocator, max_bytes: usize) ReadToEndAllocError![]u8 {
    const size = (try file.stat(std.Io.Threaded.global_single_threaded.io())).size;
    if (size > max_bytes) {
        return error.FileTooBig;
    }

    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    if (try file.readStreaming(std.Io.Threaded.global_single_threaded.io(), &.{buf}) != size) {
        return error.BytesReadMismatch;
    }

    return buf;
}

pub const Posix = struct {
    const native_os = builtin.os.tag;
    const windows = std.os.windows;
    const wasi = std.os.wasi;
    const iovec_const = extern struct {
        base: [*]const u8,
        len: usize,
    };

    pub const FcntlError = error{
        PermissionDenied,
        FileBusy,
        ProcessFdQuotaExceeded,
        Locked,
        DeadLock,
        LockedRegionLimitExceeded,
    } || std.posix.UnexpectedError;

    pub fn fcntl(fd: std.posix.fd_t, cmd: i32, arg: usize) FcntlError!usize {
        while (true) {
            const rc = std.posix.system.fcntl(fd, cmd, arg);
            switch (std.posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN, .ACCES => return error.Locked,
                .BADF => unreachable,
                .BUSY => return error.FileBusy,
                .INVAL => unreachable, // invalid parameters
                .PERM => return error.PermissionDenied,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NOTDIR => unreachable, // invalid parameter
                .DEADLK => return error.DeadLock,
                .NOLCK => return error.LockedRegionLimitExceeded,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    pub const WriteError = error{
        DiskQuota,
        FileTooBig,
        InputOutput,
        NoSpaceLeft,
        DeviceBusy,
        InvalidArgument,

        /// File descriptor does not hold the required rights to write to it.
        AccessDenied,
        PermissionDenied,
        BrokenPipe,
        SystemResources,
        OperationAborted,
        NotOpenForWriting,

        /// The process cannot access the file because another process has locked
        /// a portion of the file. Windows-only.
        LockViolation,

        /// This error occurs when no global event loop is configured,
        /// and reading from the file descriptor would block.
        WouldBlock,

        /// Connection reset by peer.
        ConnectionResetByPeer,

        /// This error occurs in Linux if the process being written to
        /// no longer exists.
        ProcessNotFound,
        /// This error occurs when a device gets disconnected before or mid-flush
        /// while it's being written to - errno(6): No such device or address.
        NoDevice,

        /// The socket type requires that message be sent atomically, and the size of the message
        /// to be sent made this impossible. The message is not transmitted.
        MessageTooBig,
    } || std.posix.UnexpectedError;

    /// Write to a file descriptor.
    /// Retries when interrupted by a signal.
    /// Returns the number of bytes written. If nonzero bytes were supplied, this will be nonzero.
    ///
    /// Note that a successful write() may transfer fewer than count bytes.  Such partial  writes  can
    /// occur  for  various reasons; for example, because there was insufficient space on the disk
    /// device to write all of the requested bytes, or because a blocked write() to a socket,  pipe,  or
    /// similar  was  interrupted by a signal handler after it had transferred some, but before it had
    /// transferred all of the requested bytes.  In the event of a partial write, the caller can  make
    /// another  write() call to transfer the remaining bytes.  The subsequent call will either
    /// transfer further bytes or may result in an error (e.g., if the disk is now full).
    ///
    /// For POSIX systems, if `fd` is opened in non blocking mode, the function will
    /// return error.WouldBlock when EAGAIN is received.
    /// On Windows, if the application has a global event loop enabled, I/O Completion Ports are
    /// used to perform the I/O. `error.WouldBlock` is not possible on Windows.
    ///
    /// Linux has a limit on how many bytes may be transferred in one `write` call, which is `0x7ffff000`
    /// on both 64-bit and 32-bit systems. This is due to using a signed C int as the return value, as
    /// well as stuffing the errno codes into the last `4096` values. This is noted on the `write` man page.
    /// The limit on Darwin is `0x7fffffff`, trying to read more than that returns EINVAL.
    /// The corresponding POSIX limit is `maxInt(isize)`.
    pub fn write(fd: std.posix.fd_t, bytes: []const u8) WriteError!usize {
        if (bytes.len == 0) return 0;
        if (native_os == .windows) {
            return windows.WriteFile(fd, bytes, null);
        }

        if (native_os == .wasi and !builtin.link_libc) {
            const ciovs = [_]iovec_const{iovec_const{
                .base = bytes.ptr,
                .len = bytes.len,
            }};
            var nwritten: usize = undefined;
            switch (wasi.fd_write(fd, &ciovs, ciovs.len, &nwritten)) {
                .SUCCESS => return nwritten,
                .INTR => unreachable,
                .INVAL => unreachable,
                .FAULT => unreachable,
                .AGAIN => unreachable,
                .BADF => return error.NotOpenForWriting, // can be a race condition.
                .DESTADDRREQ => unreachable, // `connect` was never called.
                .DQUOT => return error.DiskQuota,
                .FBIG => return error.FileTooBig,
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .PERM => return error.PermissionDenied,
                .PIPE => return error.BrokenPipe,
                .NOTCAPABLE => return error.AccessDenied,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }

        const max_count = switch (native_os) {
            .linux => 0x7ffff000,
            .macos, .ios, .watchos, .tvos, .visionos => std.math.maxInt(i32),
            else => std.math.maxInt(isize),
        };
        while (true) {
            const rc = std.posix.system.write(fd, bytes.ptr, @min(bytes.len, max_count));
            switch (std.posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .INVAL => return error.InvalidArgument,
                .FAULT => unreachable,
                .SRCH => return error.ProcessNotFound,
                .AGAIN => return error.WouldBlock,
                .BADF => return error.NotOpenForWriting, // can be a race condition.
                .DESTADDRREQ => unreachable, // `connect` was never called.
                .DQUOT => return error.DiskQuota,
                .FBIG => return error.FileTooBig,
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .ACCES => return error.AccessDenied,
                .PERM => return error.PermissionDenied,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .BUSY => return error.DeviceBusy,
                .NXIO => return error.NoDevice,
                .MSGSIZE => return error.MessageTooBig,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }
};
