const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const ManagedArrayList = std.array_list.Managed;
const ArrayList = std.ArrayList;

pub const test_support = struct {
    pub var codex_override: ?[]const u8 = null;
};

pub const CodexCommand = struct {
    argv: []const []const u8,
    env_value: ?[]u8,
};

const SpillKind = enum { stdout, stderr };

pub const RunContext = struct {
    spill_stdout_limit: usize,
    spill_stderr_limit: usize,
    preview_limit: usize,
    keep_artifacts: bool,
    force_keep: bool,
    retain_limit: usize,
    root_path: []u8,
    run_path: ?[]u8 = null,
    counter: usize = 0,
    prune_done: bool = false,

    pub fn init(allocator: Allocator, keep_artifacts: bool) !RunContext {
        const stdout_limit = parseSizeEnv(allocator, "PRAGMA_SPILL_STDOUT", 1024 * 1024);
        const stderr_limit = parseSizeEnv(allocator, "PRAGMA_SPILL_STDERR", 512 * 1024);
        const retain_limit = parseSizeEnv(allocator, "PRAGMA_RUN_HISTORY", 20);
        const root = try resolveArtifactsRoot(allocator);
        errdefer allocator.free(root);
        try ensureDirectoryExists(root);
        return RunContext{
            .spill_stdout_limit = stdout_limit,
            .spill_stderr_limit = stderr_limit,
            .preview_limit = 4 * 1024,
            .keep_artifacts = keep_artifacts,
            .force_keep = false,
            .retain_limit = retain_limit,
            .root_path = root,
        };
    }

    pub fn deinit(self: *RunContext, allocator: Allocator) void {
        if (self.run_path) |path| {
            if (!(self.keep_artifacts or self.force_keep)) {
                _ = std.fs.deleteTreeAbsolute(path) catch {};
            }
            allocator.free(path);
            self.run_path = null;
        }
        allocator.free(self.root_path);
        self.root_path = &.{};
    }

    fn ensureRunDir(self: *RunContext, allocator: Allocator) ![]const u8 {
        if (self.run_path) |path| return path;

        if (!self.prune_done) {
            try pruneOldRunsBeforeNew(allocator, self.root_path, self.retain_limit);
            self.prune_done = true;
        }

        var random_bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        const timestamp = std.time.timestamp();
        const hex_bytes = std.fmt.bytesToHex(random_bytes, .lower);
        const dir_name = try std.fmt.allocPrint(allocator, "{d}-{s}", .{ timestamp, hex_bytes[0..] });
        defer allocator.free(dir_name);

        var root_dir = try std.fs.openDirAbsolute(self.root_path, .{});
        defer root_dir.close();

        root_dir.makeDir(dir_name) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const run_path = try std.fs.path.join(allocator, &.{ self.root_path, dir_name });
        self.run_path = run_path;
        self.counter = 0;
        return run_path;
    }

    fn nextArtifactPath(self: *RunContext, allocator: Allocator, label: []const u8, kind: SpillKind) ![]u8 {
        const run_dir = try self.ensureRunDir(allocator);
        const slug = try slugifyLabel(allocator, label);
        defer allocator.free(slug);

        self.counter += 1;
        const kind_suffix = switch (kind) {
            .stdout => "stdout",
            .stderr => "stderr",
        };
        const file_name = try std.fmt.allocPrint(
            allocator,
            "{:0>3}-{s}.{s}.log",
            .{ self.counter, slug, kind_suffix },
        );
        defer allocator.free(file_name);

        const path = try std.fs.path.join(allocator, &.{ run_dir, file_name });
        return path;
    }

    fn writeArtifact(self: *RunContext, allocator: Allocator, label: []const u8, kind: SpillKind, content: []const u8) ![]u8 {
        const path = try self.nextArtifactPath(allocator, label, kind);
        errdefer allocator.free(path);
        var file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
        defer file.close();
        try file.writeAll(content);
        self.force_keep = true;
        return path;
    }

    pub fn handleStdout(self: *RunContext, allocator: Allocator, label: []const u8, content: []const u8) !void {
        if (self.spill_stdout_limit == 0 or content.len <= self.spill_stdout_limit) return;

        const path = try self.writeArtifact(allocator, label, .stdout, content);
        defer allocator.free(path);

        const human = try formatBytes(allocator, content.len);
        defer allocator.free(human);

        const message = try std.fmt.allocPrint(
            allocator,
            "pragma: stdout for {s} exceeded {s}; full log: {s}\n",
            .{ label, human, path },
        );
        defer allocator.free(message);
        try std.fs.File.stderr().writeAll(message);
    }

    pub fn handleStderr(self: *RunContext, allocator: Allocator, label: []const u8, content: []const u8) !void {
        if (content.len == 0) return;
        if (self.spill_stderr_limit == 0 or content.len <= self.spill_stderr_limit) {
            try std.fs.File.stderr().writeAll(content);
            return;
        }

        const preview_len = @min(self.preview_limit, content.len);
        if (preview_len > 0) {
            try std.fs.File.stderr().writeAll(content[0..preview_len]);
            if (content[preview_len - 1] != '\n') {
                try std.fs.File.stderr().writeAll("\n");
            }
        }

        const path = try self.writeArtifact(allocator, label, .stderr, content);
        defer allocator.free(path);

        const human = try formatBytes(allocator, content.len);
        defer allocator.free(human);

        const notice = try std.fmt.allocPrint(
            allocator,
            "pragma: stderr for {s} truncated to {d} byte preview ({s} total); full log: {s}\n",
            .{ label, preview_len, human, path },
        );
        defer allocator.free(notice);
        try std.fs.File.stderr().writeAll(notice);
    }
};

pub fn parseBufferLimit(value_str: []const u8, default: usize) usize {
    return std.fmt.parseInt(usize, value_str, 10) catch default;
}

pub fn buildCodexCommand(allocator: Allocator, prompt: []const u8) !CodexCommand {
    const codex_env = std.process.getEnvVarOwned(allocator, "PRAGMA_CODEX_BIN") catch null;

    const codex_exec = blk: {
        if (builtin.is_test) {
            if (test_support.codex_override) |value| break :blk value;
            if (codex_env) |value| break :blk value;
            break :blk "/bin/echo";
        }
        break :blk codex_env orelse "codex";
    };

    var argv_builder = ManagedArrayList([]const u8).init(allocator);
    defer argv_builder.deinit();

    try argv_builder.append(codex_exec);
    try argv_builder.append("--search");
    try argv_builder.append("--yolo");
    try argv_builder.append("exec");
    try argv_builder.append("--skip-git-repo-check");
    try argv_builder.append("--json");
    try argv_builder.append("-c");
    try argv_builder.append("mcp_servers={}");
    try argv_builder.append(prompt);

    const argv = try argv_builder.toOwnedSlice();

    return .{
        .argv = argv,
        .env_value = codex_env,
    };
}

pub fn runCodex(allocator: Allocator, run_ctx: *RunContext, label: []const u8, prompt: []const u8) ![]u8 {
    var cmd = try buildCodexCommand(allocator, prompt);
    defer if (cmd.env_value) |value| allocator.free(value);
    defer allocator.free(cmd.argv);

    var process = std.process.Child.init(cmd.argv, allocator);
    process.stdin_behavior = .Ignore;
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;

    try process.spawn();
    errdefer _ = process.wait() catch {};

    const max_stdout = blk: {
        const env = std.process.getEnvVarOwned(allocator, "PRAGMA_MAX_STDOUT") catch break :blk 100 * 1024 * 1024;
        defer allocator.free(env);
        break :blk parseBufferLimit(env, 100 * 1024 * 1024);
    };
    const max_stderr = blk: {
        const env = std.process.getEnvVarOwned(allocator, "PRAGMA_MAX_STDERR") catch break :blk 10 * 1024 * 1024;
        defer allocator.free(env);
        break :blk parseBufferLimit(env, 10 * 1024 * 1024);
    };

    const output = try collectChildOutput(allocator, &process, max_stdout, max_stderr);
    defer allocator.free(output.stdout);
    defer allocator.free(output.stderr);

    const term = try process.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.CodexFailed,
        else => return error.CodexFailed,
    }

    try run_ctx.handleStdout(allocator, label, output.stdout);
    try run_ctx.handleStderr(allocator, label, output.stderr);

    const message = try extractAgentMarkdown(allocator, output.stdout);
    return message;
}

pub fn extractAgentMarkdown(allocator: Allocator, stream: []const u8) ![]u8 {
    var last: ?[]u8 = null;

    var it = std.mem.splitScalar(u8, stream, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] != '{') continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
            continue;
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .object => |obj| {
                const event_type_node = obj.get("type") orelse continue;
                const event_type = switch (event_type_node) {
                    .string => |value| value,
                    else => continue,
                };
                if (!std.mem.eql(u8, event_type, "item.completed")) continue;

                const item_node = obj.get("item") orelse continue;
                const item_obj = switch (item_node) {
                    .object => |value| value,
                    else => continue,
                };

                const item_type_node = item_obj.get("type") orelse continue;
                const item_type = switch (item_type_node) {
                    .string => |value| value,
                    else => continue,
                };
                if (!std.mem.eql(u8, item_type, "agent_message")) continue;

                const text_node = item_obj.get("text") orelse continue;
                const text_value = switch (text_node) {
                    .string => |value| value,
                    else => continue,
                };
                const copy = try allocator.dupe(u8, text_value);
                if (last) |existing| {
                    allocator.free(existing);
                }
                last = copy;
            },
            else => continue,
        }
    }

    if (last) |value| {
        return value;
    }

    const fallback = std.mem.trim(u8, stream, " \r\n");
    return allocator.dupe(u8, fallback);
}

fn parseSizeEnv(allocator: Allocator, name: []const u8, default_value: usize) usize {
    const env = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(env);
    return parseBufferLimit(env, default_value);
}

fn resolveArtifactsRoot(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "PRAGMA_RUN_ROOT") catch null) |raw_value| {
        defer allocator.free(raw_value);
        if (std.fs.path.isAbsolute(raw_value)) {
            return allocator.dupe(u8, raw_value);
        } else {
            const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
            defer allocator.free(cwd);
            return std.fs.path.join(allocator, &.{ cwd, raw_value });
        }
    }

    if (std.process.getEnvVarOwned(allocator, "HOME") catch null) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".pragma", "runs" });
    }

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".pragma", "runs" });
}

fn ensureDirectoryExists(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.makeDirAbsolute(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    } else {
        std.fs.cwd().makePath(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

fn slugifyLabel(allocator: Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    var buffer = ManagedArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    var last_was_sep = false;
    var count: usize = 0;
    var it = trimmed;
    if (it.len == 0) {
        try buffer.appendSlice("task");
        return try buffer.toOwnedSlice();
    }

    while (count < 48 and it.len > 0) : (count += 1) {
        const ch = it[0];
        it = it[1..];
        if (std.ascii.isAlphanumeric(ch)) {
            try buffer.append(std.ascii.toLower(ch));
            last_was_sep = false;
            continue;
        }
        if (!last_was_sep) {
            try buffer.append('_');
            last_was_sep = true;
        }
    }

    if (buffer.items.len == 0) {
        try buffer.appendSlice("task");
    } else if (last_was_sep) {
        buffer.items[buffer.items.len - 1] = '_';
    }

    return buffer.toOwnedSlice();
}

fn formatBytes(allocator: Allocator, size: usize) ![]u8 {
    const kb = 1024;
    const mb = kb * 1024;
    if (size >= mb) {
        const whole = size / mb;
        const tenths = (size % mb) * 10 / mb;
        return std.fmt.allocPrint(allocator, "{d}.{d} MB", .{ whole, tenths });
    } else if (size >= kb) {
        const whole = size / kb;
        const tenths = (size % kb) * 10 / kb;
        return std.fmt.allocPrint(allocator, "{d}.{d} KB", .{ whole, tenths });
    }
    return std.fmt.allocPrint(allocator, "{d} B", .{size});
}

fn pruneOldRunsBeforeNew(allocator: Allocator, root_path: []const u8, retain_limit: usize) !void {
    var dir = std.fs.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var entries = ManagedArrayList([]u8).init(allocator);
    errdefer {
        for (entries.items) |item| allocator.free(item);
        entries.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const copy = try allocator.dupe(u8, entry.name);
        try entries.append(copy);
    }

    const target_existing: usize = if (retain_limit == 0) 0 else if (retain_limit > 0) retain_limit - 1 else 0;
    if (entries.items.len <= target_existing) return;

    std.sort.heap([]u8, entries.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    const to_remove = entries.items.len - target_existing;
    var idx: usize = 0;
    while (idx < to_remove) : (idx += 1) {
        const name = entries.items[idx];
        const target = try std.fs.path.join(allocator, &.{ root_path, name });
        defer allocator.free(target);
        _ = std.fs.deleteTreeAbsolute(target) catch {};
    }
}

fn collectChildOutput(
    allocator: Allocator,
    child: *std.process.Child,
    max_stdout: usize,
    max_stderr: usize,
) !struct {
    stdout: []u8,
    stderr: []u8,
} {
    const PollStreams = enum { stdout, stderr };

    var stdout_list: ArrayList(u8) = .empty;
    defer stdout_list.deinit(allocator);
    var stderr_list: ArrayList(u8) = .empty;
    defer stderr_list.deinit(allocator);

    const stdout_file = child.stdout orelse return error.StdoutNotPiped;
    const stderr_file = child.stderr orelse return error.StderrNotPiped;

    var poller = std.Io.poll(allocator, PollStreams, .{
        .stdout = stdout_file,
        .stderr = stderr_file,
    });
    defer poller.deinit();

    const stdout_reader = poller.reader(.stdout);
    stdout_reader.buffer = stdout_list.allocatedSlice();
    stdout_reader.seek = 0;
    stdout_reader.end = stdout_list.items.len;

    const stderr_reader = poller.reader(.stderr);
    stderr_reader.buffer = stderr_list.allocatedSlice();
    stderr_reader.seek = 0;
    stderr_reader.end = stderr_list.items.len;

    while (try poller.poll()) {
        if (stdout_reader.bufferedLen() > max_stdout) return error.StdoutStreamTooLong;
        if (stderr_reader.bufferedLen() > max_stderr) return error.StderrStreamTooLong;
    }

    const stdout_buffer = stdout_reader.buffer;
    const stdout_end = stdout_reader.end;
    const stderr_buffer = stderr_reader.buffer;
    const stderr_end = stderr_reader.end;

    stdout_reader.buffer = &.{};
    stderr_reader.buffer = &.{};

    stdout_list = .{
        .items = stdout_buffer[0..stdout_end],
        .capacity = stdout_buffer.len,
    };
    stderr_list = .{
        .items = stderr_buffer[0..stderr_end],
        .capacity = stderr_buffer.len,
    };

    return .{
        .stdout = try stdout_list.toOwnedSlice(allocator),
        .stderr = try stderr_list.toOwnedSlice(allocator),
    };
}

// Tests

test "extractAgentMarkdown: valid JSON with agent_message" {
    const allocator = std.testing.allocator;
    const json_stream =
        \\{"type":"item.completed","item":{"type":"agent_message","text":"Hello World"}}
    ;

    const result = try extractAgentMarkdown(allocator, json_stream);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello World", result);
}

test "extractAgentMarkdown: multiple messages returns last" {
    const allocator = std.testing.allocator;
    const json_stream =
        \\{"type":"item.completed","item":{"type":"agent_message","text":"First"}}
        \\{"type":"item.completed","item":{"type":"agent_message","text":"Second"}}
        \\{"type":"item.completed","item":{"type":"agent_message","text":"Third"}}
    ;

    const result = try extractAgentMarkdown(allocator, json_stream);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Third", result);
}

test "extractAgentMarkdown: empty stream returns empty" {
    const allocator = std.testing.allocator;
    const json_stream = "";

    const result = try extractAgentMarkdown(allocator, json_stream);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "extractAgentMarkdown: whitespace only returns empty" {
    const allocator = std.testing.allocator;
    const json_stream = "   \n\n  \r\n   ";

    const result = try extractAgentMarkdown(allocator, json_stream);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "extractAgentMarkdown: malformed JSON skipped, uses fallback" {
    const allocator = std.testing.allocator;
    const json_stream = "not valid json\nmore invalid\nplain text output";

    const result = try extractAgentMarkdown(allocator, json_stream);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("not valid json\nmore invalid\nplain text output", result);
}

test "extractAgentMarkdown: wrong event type uses fallback" {
    const allocator = std.testing.allocator;
    const json_stream =
        \\{"type":"other.event","item":{"type":"agent_message","text":"Should ignore"}}
        \\fallback text
    ;

    const result = try extractAgentMarkdown(allocator, json_stream);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"type\":\"other.event\",\"item\":{\"type\":\"agent_message\",\"text\":\"Should ignore\"}}\nfallback text", result);
}

test "extractAgentMarkdown: wrong item type uses fallback" {
    const allocator = std.testing.allocator;
    const json_stream =
        \\{"type":"item.completed","item":{"type":"other_type","text":"Should ignore"}}
        \\fallback
    ;

    const result = try extractAgentMarkdown(allocator, json_stream);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"type\":\"item.completed\",\"item\":{\"type\":\"other_type\",\"text\":\"Should ignore\"}}\nfallback", result);
}

test "extractAgentMarkdown: mixed valid and invalid JSON" {
    const allocator = std.testing.allocator;
    const json_stream =
        \\invalid line
        \\{"type":"item.completed","item":{"type":"agent_message","text":"Valid"}}
        \\more invalid
    ;

    const result = try extractAgentMarkdown(allocator, json_stream);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Valid", result);
}

test "parseBufferLimit: valid positive number" {
    const result = parseBufferLimit("1024", 512);
    try std.testing.expectEqual(@as(usize, 1024), result);
}

test "parseBufferLimit: large number" {
    const result = parseBufferLimit("104857600", 1024);
    try std.testing.expectEqual(@as(usize, 104857600), result);
}

test "parseBufferLimit: zero is valid" {
    const result = parseBufferLimit("0", 1024);
    try std.testing.expectEqual(@as(usize, 0), result);
}

test "parseBufferLimit: invalid string returns default" {
    const result = parseBufferLimit("not-a-number", 512);
    try std.testing.expectEqual(@as(usize, 512), result);
}

test "parseBufferLimit: empty string returns default" {
    const result = parseBufferLimit("", 1024);
    try std.testing.expectEqual(@as(usize, 1024), result);
}

test "parseBufferLimit: negative number returns default" {
    const result = parseBufferLimit("-100", 1024);
    try std.testing.expectEqual(@as(usize, 1024), result);
}

test "parseBufferLimit: mixed alphanumeric returns default" {
    const result = parseBufferLimit("123abc", 2048);
    try std.testing.expectEqual(@as(usize, 2048), result);
}

test "RunContext spills stdout to disk when over limit" {
    const allocator = std.testing.allocator;
    var ctx = try RunContext.init(allocator, false);
    defer {
        ctx.force_keep = false;
        ctx.deinit(allocator);
    }

    ctx.spill_stdout_limit = 32;
    ctx.preview_limit = 0;

    const label = "spill-test";
    const data = "A" ** 128;

    try ctx.handleStdout(allocator, label, data);

    try std.testing.expect(ctx.run_path != null);

    const run_dir = ctx.run_path.?;
    var dir = try std.fs.openDirAbsolute(run_dir, .{ .iterate = true });
    defer dir.close();

    var found = false;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".stdout.log")) continue;
        found = true;
        const file_path = try std.fs.path.join(allocator, &.{ run_dir, entry.name });
        defer allocator.free(file_path);
        const contents = try std.fs.cwd().readFileAlloc(file_path, allocator, std.Io.Limit.unlimited);
        defer allocator.free(contents);
        try std.testing.expectEqualStrings(data, contents);
    }
    try std.testing.expect(found);
}

test "RunContext spills stderr to disk when over limit" {
    const allocator = std.testing.allocator;
    var ctx = try RunContext.init(allocator, false);
    defer {
        ctx.force_keep = false;
        ctx.deinit(allocator);
    }

    ctx.spill_stderr_limit = 16;
    ctx.preview_limit = 0;

    const label = "stderr-spill";
    const data = "B" ** 128;

    try ctx.handleStderr(allocator, label, data);

    try std.testing.expect(ctx.run_path != null);

    const run_dir = ctx.run_path.?;
    var dir = try std.fs.openDirAbsolute(run_dir, .{ .iterate = true });
    defer dir.close();

    var found = false;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".stderr.log")) continue;
        found = true;
        const file_path = try std.fs.path.join(allocator, &.{ run_dir, entry.name });
        defer allocator.free(file_path);
        const contents = try std.fs.cwd().readFileAlloc(file_path, allocator, std.Io.Limit.unlimited);
        defer allocator.free(contents);
        try std.testing.expectEqualStrings(data, contents);
    }
    try std.testing.expect(found);
}

test "runCodex honors PRAGMA_CODEX_BIN stub" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var file = try tmp.dir.createFile("codex-stub.sh", .{ .read = true, .mode = 0o755 });
        defer file.close();
        try file.writeAll(
            "#!/bin/sh\n" ++
                "echo '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Stub OK\"}}'\n",
        );
    }

    const script_path = try tmp.dir.realpathAlloc(allocator, "codex-stub.sh");
    defer allocator.free(script_path);

    test_support.codex_override = script_path;
    defer test_support.codex_override = null;

    var ctx = try RunContext.init(allocator, false);
    defer ctx.deinit(allocator);

    const prompt = "Analyze";
    const output = try runCodex(allocator, &ctx, "test", prompt);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("Stub OK", output);
}
