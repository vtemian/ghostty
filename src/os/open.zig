const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const apprt = @import("../apprt.zig");
const compat_env = @import("../lib/compat/env.zig");

const log = std.log.scoped(.@"os-open");

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored. The allocator is used to buffer the
/// log output and may allocate from another thread.
///
/// This function is purposely simple for the sake of providing
/// some portable way to open URLs. If you are implementing an
/// apprt for Ghostty, you should consider doing something special-cased
/// for your platform.
pub fn open(
    alloc: Allocator,
    kind: apprt.action.OpenUrl.Kind,
    url: []const u8,
) !void {
    var spawn_opts: std.process.SpawnOptions = switch (builtin.os.tag) {
        .linux, .freebsd => .{ .argv = &.{ "xdg-open", url } },
        .windows => .{ .argv = &.{ "rundll32", "url.dll,FileProtocolHandler", url } },
        .macos => .{
            switch (kind) {
                .text => .{ .argv = &.{ "open", "-t", url } },
                .html, .unknown => .{ .argv = &.{ "open", url } },
            },
        },

        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };
    spawn_opts.stdout = .pipe;
    spawn_opts.stderr = .pipe;

    var env = try compat_env.getEnvMap(alloc);
    defer env.deinit();
    if (comptime build_config.snap) {
        // In the snap on Linux the launcher exports LD_LIBRARY_PATH pointing at
        // the snap's bundled libraries. Leaking this into child process can
        // can be problematic, so let's drop it from the env
        env.orderedRemove("LD_LIBRARY_PATH");
    }

    const env_block: std.process.Environ.Block = switch (builtin.os.tag) {
        .linux, .freebsd, .macos => try env.createPosixBlock(alloc, .{}),
        .windows => try env.createWindowsBlock(alloc, .{}),
        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };

    var threaded: std.Io.Threaded = .init(alloc, .{ .environ = .{ .block = env_block } });
    const io = threaded.io();
    // Spawn the process on our same thread so we can detect failure
    // quickly.
    const exe = try std.process.spawn(io, spawn_opts);

    // Create a thread that handles collecting output and reaping
    // the process. This is done in a separate thread because SOME
    // open implementations block and some do not. It's easier to just
    // spawn a thread to handle this so that we never block.
    const thread = try std.Thread.spawn(.{}, openThread, .{ io, alloc, exe });
    thread.detach();
}

fn openThread(io: std.Io, alloc: Allocator, exe_: std.process.Child) !void {
    // 50 KiB is the default value used by std.process.Child.run and should
    // be enough to get the output we care about.
    const output_max_size = 50 * 1024;

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    defer {
        stdout.deinit(alloc);
        stderr.deinit(alloc);
    }

    try collectOutput(io, alloc, exe_.stdout.?, &stdout, exe_.stderr.?, &stderr, output_max_size);

    // Copy the exe so it is non-const. This is necessary because wait()
    // requires a mutable reference and we can't have one as a thread
    // param.
    var exe = exe_;
    _ = try exe.wait(io);

    // If we have any stderr output we log it. This makes it easier for
    // users to debug why some open commands may not work as expected.
    if (stderr.items.len > 0) log.warn("wait stderr={s}", .{stderr.items});
}

const CollectError = error{OutputTooLong} || std.mem.Allocator.Error || std.Io.File.ReadStreamingError;

fn collectOutput(
    io: std.Io,
    alloc: std.mem.Allocator,
    stdout_file: std.Io.File,
    stdout_output: *std.ArrayList(u8),
    stderr_file: std.Io.File,
    stderr_output: *std.ArrayList(u8),
    limit: usize,
) CollectError!void {
    var stdout_bytes_read: usize = 0;
    var stdout_buf: [1024]u8 = undefined;
    var stderr_bytes_read: usize = 0;
    var stderr_buf: [1024]u8 = undefined;
    var storage: [2]std.Io.Operation.Storage = undefined;
    var done: [storage.len]bool = .{ false, false };
    var batch: std.Io.Batch = .init(&storage);

    _ = batch.add(.{ .file_read_streaming = .{
        .file = stdout_file,
        .data = &.{&stdout_buf},
    } });
    _ = batch.add(.{ .file_read_streaming = .{
        .file = stderr_file,
        .data = &.{&stderr_buf},
    } });

    while (true) {
        try batch.awaitAsync(io);

        while (batch.next()) |completion| {
            const bytes_read, const buf, const output = switch (completion.index) {
                0 => .{ &stdout_bytes_read, stdout_buf, stdout_output },
                1 => .{ &stderr_bytes_read, stderr_buf, stderr_output },
                else => unreachable,
            };
            const size = completion.result.file_read_streaming catch |err| size: {
                switch (err) {
                    error.EndOfStream => done[completion.index] = true,
                    else => return err,
                }
                done[completion.index] = true;
                var finished = true;
                for (done) |d| {
                    if (!d) finished = false;
                }
                if (finished) return;
                break :size 0;
            };

            bytes_read.* += size;
            if (bytes_read.* > limit) return error.OutputTooLong;
            try output.appendSlice(alloc, buf[0..size]);
        }
    }
}
