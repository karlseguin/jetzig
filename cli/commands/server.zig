const std = @import("std");
const args = @import("args");
const util = @import("../util.zig");

pub const watch_changes_pause_duration = 1 * 1000 * 1000 * 1000;

/// Command line options for the `update` command.
pub const Options = struct {
    reload: bool = true,

    pub const meta = .{
        .full_text =
        \\Launches a development server.
        \\
        \\The development server reloads when files in `src/` are updated.
        \\
        \\To disable this behaviour, pass `--reload=false`
        \\
        \\Example:
        \\
        \\  jetzig server
        \\  jetzig server --reload=false
        ,
        .option_docs = .{
            .reload = "Enable or disable automatic reload on update (default: true)",
        },
    };
};

/// Run the `jetzig server` command.
pub fn run(
    allocator: std.mem.Allocator,
    options: Options,
    writer: anytype,
    positionals: [][]const u8,
    other_options: struct { help: bool },
) !void {
    if (other_options.help) {
        try args.printHelp(Options, "jetzig server", writer);
        return;
    }

    if (positionals.len > 0) {
        std.debug.print("The `server` command does not accept positional arguments.", .{});
        return error.JetzigCommandError;
    }

    var cwd = try util.detectJetzigProjectDir();
    defer cwd.close();

    const realpath = try std.fs.realpathAlloc(allocator, ".");
    defer allocator.free(realpath);

    var mtime = try totalMtime(allocator, cwd, "src");

    std.debug.print(
        "Launching development server. [reload:{s}]\n",
        .{
            if (options.reload) "enabled" else "disabled",
        },
    );

    while (true) {
        try util.runCommand(
            allocator,
            realpath,
            &[_][]const u8{ "zig", "build", "-Djetzig_runner=true", "install" },
        );

        const exe_path = try locateExecutable(allocator, cwd);
        if (exe_path == null) {
            std.debug.print("Unable to locate compiled executable. Exiting.\n", .{});
            std.os.exit(1);
        }

        const argv = &[_][]const u8{exe_path.?};
        defer allocator.free(exe_path.?);

        var process = std.process.Child.init(argv, allocator);
        process.stdin_behavior = .Inherit;
        process.stdout_behavior = .Inherit;
        process.stderr_behavior = .Inherit;
        process.cwd = realpath;

        var stdout_buf = std.ArrayList(u8).init(allocator);
        defer stdout_buf.deinit();

        var stderr_buf = std.ArrayList(u8).init(allocator);
        defer stderr_buf.deinit();

        try process.spawn();

        if (!options.reload) {
            const term = try process.wait();
            std.os.exit(term.Exited);
        }

        while (true) {
            if (process.term) |_| {
                _ = try process.wait();
                std.debug.print("Server exited, restarting...\n", .{});
            }

            std.time.sleep(watch_changes_pause_duration);

            const new_mtime = try totalMtime(allocator, cwd, "src");

            if (new_mtime > mtime) {
                std.debug.print("Changes detected, restarting server...\n", .{});
                _ = try process.kill();
                mtime = new_mtime;
                break;
            }
        }
    }
}

fn totalMtime(allocator: std.mem.Allocator, cwd: std.fs.Dir, sub_path: []const u8) !i128 {
    var dir = try cwd.openDir(sub_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var sum: i128 = 0;

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const extension = std.fs.path.extension(entry.path);

        if (std.mem.eql(u8, extension, ".zig") or std.mem.eql(u8, extension, ".zmpl")) {
            const stat = try dir.statFile(entry.path);
            sum += stat.mtime;
        }
    }

    return sum;
}

fn locateExecutable(allocator: std.mem.Allocator, dir: std.fs.Dir) !?[]const u8 {
    const file = dir.openFile(".jetzig", .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return null,
            else => return err,
        }
    };
    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    const exe_name = util.strip(content);

    // XXX: Will fail if user sets a custom install path.
    var bin_dir = try dir.openDir("zig-out/bin", .{ .iterate = true });
    defer bin_dir.close();

    var walker = try bin_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.path, exe_name)) {
            return try bin_dir.realpathAlloc(allocator, entry.path);
        }
    }

    return null;
}