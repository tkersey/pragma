const std = @import("std");
const manifest = @import("manifest.zig");

const Allocator = std.mem.Allocator;
const ManagedArrayList = std.array_list.Managed;

const StreamKind = enum { stdout, stderr };

const StreamMeta = struct {
    proc_index: usize,
    kind: StreamKind,
};

const ParallelProcess = struct {
    label: []const u8,
    directive: []const u8,
    assembled: []u8,
    argv: []const []const u8,
    env_value: ?[]u8,
    child: std.process.Child,
    stdout_buf: std.ArrayList(u8) = .empty,
    stderr_buf: std.ArrayList(u8) = .empty,
    spawned: bool = false,
};

fn cleanupParallelProcess(allocator: Allocator, proc: *ParallelProcess) void {
    if (proc.spawned) {
        _ = proc.child.kill() catch {};
        _ = proc.child.wait() catch {};
        proc.spawned = false;
    }
    if (proc.child.stdout) |*file| {
        file.close();
        proc.child.stdout = null;
    }
    if (proc.child.stderr) |*file| {
        file.close();
        proc.child.stderr = null;
    }
    proc.stdout_buf.deinit(allocator);
    proc.stdout_buf = .empty;
    proc.stderr_buf.deinit(allocator);
    proc.stderr_buf = .empty;
    if (proc.assembled.len != 0) {
        allocator.free(proc.assembled);
        proc.assembled = &[_]u8{};
    }
    if (proc.argv.len != 0) {
        allocator.free(proc.argv);
        proc.argv = &[_][]const u8{};
    }
    if (proc.env_value) |value| {
        allocator.free(value);
        proc.env_value = null;
    }
}

pub fn executeParallelTasks(
    allocator: Allocator,
    helpers: anytype,
    run_ctx: anytype,
    doc: anytype,
    step: anytype,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    tasks: anytype,
    stdout_writer: manifest.OutputWriter,
    stderr_writer: manifest.OutputWriter,
) !void {
    const helper = helpers.*;
    const ctx = run_ctx;
    const posix = std.posix;

    var processes = ManagedArrayList(ParallelProcess).init(allocator);
    errdefer {
        for (processes.items) |*proc| {
            cleanupParallelProcess(allocator, proc);
        }
        processes.deinit();
    }

    for (tasks.items) |task_view| {
        var segments = [_]?[]const u8{ doc.core_prompt, step.prompt, task_view.prompt };
        const extra = try helper.buildInlinePrompt(allocator, &segments);
        defer if (extra) |value| allocator.free(value);
        const mut_extra = if (extra) |value| value else null;

        var directive_doc = try helper.loadDirectiveDocument(
            allocator,
            task_view.directive,
            cli_dir,
            env_dir,
            mut_extra,
        );

        var assembled = try helper.assemblePrompt(allocator, directive_doc.prompt, directive_doc.contract);
        errdefer allocator.free(assembled);

        switch (directive_doc.contract) {
            .custom => |value| allocator.free(value),
            else => {},
        }
        allocator.free(directive_doc.prompt);

        var cmd = try helper.buildCodexCommand(allocator, assembled);
        errdefer allocator.free(cmd.argv);
        errdefer if (cmd.env_value) |value| allocator.free(value);

        var child = std.process.Child.init(cmd.argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        var proc_entry = ParallelProcess{
            .label = task_view.task_name orelse task_view.directive,
            .directive = task_view.directive,
            .assembled = assembled,
            .argv = cmd.argv,
            .env_value = cmd.env_value,
            .child = child,
            .spawned = true,
        };

        var proc_added = false;
        errdefer if (!proc_added) cleanupParallelProcess(allocator, &proc_entry);

        try processes.append(proc_entry);
        proc_added = true;

        assembled = &[_]u8{};
        cmd.argv = &[_][]const u8{};
        cmd.env_value = null;
    }

    var pollfds = ManagedArrayList(posix.pollfd).init(allocator);
    defer pollfds.deinit();
    var metas = ManagedArrayList(StreamMeta).init(allocator);
    defer metas.deinit();

    for (processes.items, 0..) |*proc, proc_index| {
        if (proc.child.stdout) |*file| {
            try pollfds.append(.{ .fd = file.handle, .events = posix.POLL.IN, .revents = 0 });
            try metas.append(.{ .proc_index = proc_index, .kind = .stdout });
        }
        if (proc.child.stderr) |*file| {
            try pollfds.append(.{ .fd = file.handle, .events = posix.POLL.IN, .revents = 0 });
            try metas.append(.{ .proc_index = proc_index, .kind = .stderr });
        }
    }

    var tmp: [4096]u8 = undefined;
    const err_mask = posix.POLL.ERR | posix.POLL.NVAL | posix.POLL.HUP;

    while (pollfds.items.len > 0) {
        const poll_result = posix.poll(pollfds.items, -1) catch |err| return err;
        if (poll_result == 0) continue;

        var idx: usize = 0;
        while (idx < pollfds.items.len) {
            const revents = pollfds.items[idx].revents;
            if (revents == 0) {
                idx += 1;
                continue;
            }

            const meta = metas.items[idx];
            var proc = &processes.items[meta.proc_index];
            const fd = pollfds.items[idx].fd;
            var remove_entry = false;

            if (revents & posix.POLL.IN != 0) {
                const amt = posix.read(fd, tmp[0..]) catch |err| switch (err) {
                    error.BrokenPipe, error.ConnectionResetByPeer => 0,
                    else => return err,
                };
                if (amt == 0) {
                    remove_entry = true;
                } else {
                    switch (meta.kind) {
                        .stdout => try proc.stdout_buf.appendSlice(allocator, tmp[0..amt]),
                        .stderr => try proc.stderr_buf.appendSlice(allocator, tmp[0..amt]),
                    }
                }
            }

            if (revents & err_mask != 0) {
                remove_entry = true;
            }

            if (remove_entry) {
                switch (meta.kind) {
                    .stdout => if (proc.child.stdout) |*file| {
                        file.close();
                        proc.child.stdout = null;
                    },
                    .stderr => if (proc.child.stderr) |*file| {
                        file.close();
                        proc.child.stderr = null;
                    },
                }
                _ = pollfds.swapRemove(idx);
                _ = metas.swapRemove(idx);
                continue;
            } else {
                idx += 1;
            }
        }
    }

    for (processes.items) |*proc| {
        const term = try proc.child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) {
                const msg = try std.fmt.allocPrint(allocator, "pragma: parallel task {s} exited with code {d}\n", .{ proc.label, code });
                defer allocator.free(msg);
                try stderr_writer.writeAll(msg);
                return error.CodexFailed;
            },
            else => {
                const msg = try std.fmt.allocPrint(allocator, "pragma: parallel task {s} terminated unexpectedly\n", .{proc.label});
                defer allocator.free(msg);
                try stderr_writer.writeAll(msg);
                return error.CodexFailed;
            },
        }

        proc.spawned = false;

        if (proc.stderr_buf.items.len > 0) {
            try ctx.handleStderr(allocator, proc.label, proc.stderr_buf.items);
        }

        const message = try helper.extractAgentMarkdown(allocator, proc.stdout_buf.items);
        defer allocator.free(message);

        try ctx.handleStdout(allocator, proc.label, proc.stdout_buf.items);

        const header = try std.fmt.allocPrint(allocator, "--- Parallel Task: {s} (directive: {s})\n", .{ proc.label, proc.directive });
        defer allocator.free(header);
        try stdout_writer.writeAll(header);
        try stdout_writer.writeAll(message);
        try stdout_writer.writeAll("\n");

        cleanupParallelProcess(allocator, proc);
    }

    processes.deinit();
}
