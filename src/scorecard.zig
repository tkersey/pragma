const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const CommandRecord = struct {
    command: []const u8,
    status: []const u8,
    exit_code: ?i64,
    aggregated_output: []const u8,
};

const ParseOutput = struct {
    arena: std.heap.ArenaAllocator,
    plan_updates: ArrayListUnmanaged([]const u8),
    commands: ArrayListUnmanaged(CommandRecord),
    agent_messages: ArrayListUnmanaged([]const u8),
    last_agent_message: []const u8,

    pub fn init(parent_allocator: Allocator) ParseOutput {
        const arena = std.heap.ArenaAllocator.init(parent_allocator);
        return .{
            .arena = arena,
            .plan_updates = .{},
            .commands = .{},
            .agent_messages = .{},
            .last_agent_message = &.{},
        };
    }

    pub fn deinit(self: *ParseOutput) void {
        self.arena.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    const input_path = args.next() orelse {
        try printUsage();
        return;
    };

    const run_id = args.next();
    if (args.next() != null) {
        try printUsage();
        return;
    }

    var result = try parseLog(allocator, input_path);
    defer result.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const selected_run = run_id orelse input_path;
    try stdout.print("Run: {s}\n\n", .{selected_run});

    try renderSection(stdout, "Plan Updates", result.plan_updates.items);

    var tests = ArrayListUnmanaged(CommandRecord){};
    for (result.commands.items) |cmd| {
        if (isLikelyTestCommand(cmd.command)) {
            try tests.append(result.arena.allocator(), cmd);
        }
    }

    try renderCommandSection(stdout, "Tests Executed", tests.items);
    try renderCommandSection(stdout, "Commands Executed", result.commands.items);

    try stdout.writeAll("\nAgent Summary:\n");
    if (result.last_agent_message.len == 0) {
        try stdout.writeAll("- <none captured>\n");
    } else {
        try stdout.print("{s}\n", .{result.last_agent_message});
    }

    try stdout.writeAll(
        "\nScorecard Draft:\n" ++
            "TRACE: [ ] / evidence: \n" ++
            "E-SDD: [ ] / evidence: \n" ++
            "Visionary: [ ] / evidence: \n" ++
            "Prove-It: [ ] / evidence: \n" ++
            "Guilty: [ ] / evidence: \n",
    );

    try stdout.flush();
}

fn printUsage() !void {
    try std.fs.File.stderr().writeAll("usage: zig build scorecard -- <log.jsonl> [run-id]\n");
}

fn parseLog(allocator: Allocator, input_path: []const u8) !ParseOutput {
    var result = ParseOutput.init(allocator);
    errdefer result.deinit();

    const data = try readInput(allocator, input_path);
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] != '{') continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
            continue;
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .object => |obj| try handleEvent(&result, obj),
            else => continue,
        }
    }

    return result;
}

fn readInput(allocator: Allocator, input_path: []const u8) ![]u8 {
    if (std.mem.eql(u8, input_path, "-")) {
        const stdin_file = std.fs.File.stdin();
        return readStream(allocator, stdin_file);
    }

    const file = try std.fs.cwd().openFile(input_path, .{ .mode = .read_only });
    defer file.close();
    return readStream(allocator, file);
}

fn readStream(allocator: Allocator, file: std.fs.File) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    var temp: [4096]u8 = undefined;
    while (true) {
        const amt = try file.read(&temp);
        if (amt == 0) break;
        try list.appendSlice(allocator, temp[0..amt]);
    }

    return list.toOwnedSlice(allocator);
}

test "readStream handles large files without truncation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("large.log", .{ .read = true });
    defer file.close();

    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'A');

    const repeat_count: usize = 8;
    var expected_len: usize = 0;
    for (0..repeat_count) |_| {
        try file.writeAll(&chunk);
        expected_len += chunk.len;
    }

    try file.seekTo(0);
    const content = try readStream(allocator, file);
    defer allocator.free(content);

    try std.testing.expectEqual(expected_len, content.len);
    try std.testing.expectEqual(@as(u8, 'A'), content[0]);
    try std.testing.expectEqual(@as(u8, 'A'), content[content.len - 1]);
}

fn handleEvent(
    result: *ParseOutput,
    obj: std.json.ObjectMap,
) !void {
    const event_type_node = obj.get("type") orelse return;
    const event_type = switch (event_type_node) {
        .string => |value_str| value_str,
        else => return,
    };

    if (!std.mem.eql(u8, event_type, "item.completed")) return;

    const item_node = obj.get("item") orelse return;
    const item_obj = switch (item_node) {
        .object => |inner| inner,
        else => return,
    };

    const item_type_node = item_obj.get("type") orelse return;
    const item_type = switch (item_type_node) {
        .string => |value_str| value_str,
        else => return,
    };

    const arena_allocator = result.arena.allocator();

    if (containsCaseInsensitive(item_type, "plan")) {
        if (try extractPlanText(arena_allocator, item_node)) |plan_text| {
            try result.plan_updates.append(arena_allocator, plan_text);
        }
    }

    if (std.mem.eql(u8, item_type, "agent_message")) {
        const text_node = item_obj.get("text") orelse return;
        const message = switch (text_node) {
            .string => |value_str| try arena_allocator.dupe(u8, value_str),
            else => return,
        };

        try result.agent_messages.append(arena_allocator, message);
        result.last_agent_message = message;
        return;
    }

    if (std.mem.eql(u8, item_type, "command_execution")) {
        const command_node = item_obj.get("command") orelse return;
        const command = switch (command_node) {
            .string => |value_str| try arena_allocator.dupe(u8, value_str),
            else => return,
        };

        const status_node = item_obj.get("status") orelse return;
        const status = switch (status_node) {
            .string => |value_str| value_str,
            else => return,
        };
        const status_copy = try arena_allocator.dupe(u8, status);

        var exit_code: ?i64 = null;
        if (item_obj.get("exit_code")) |exit_node| {
            exit_code = switch (exit_node) {
                .integer => |value_int| value_int,
                .float => |value_float| @as(i64, @intFromFloat(value_float)),
                else => exit_code,
            };
        }

        var aggregated_output: []const u8 = &.{};
        if (item_obj.get("aggregated_output")) |output_node| {
            switch (output_node) {
                .string => |value_str| aggregated_output = try arena_allocator.dupe(u8, value_str),
                else => {},
            }
        }

        const record = CommandRecord{
            .command = command,
            .status = status_copy,
            .exit_code = exit_code,
            .aggregated_output = aggregated_output,
        };

        try result.commands.append(arena_allocator, record);
        return;
    }
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                break;
            }
        } else {
            return true;
        }
    }
    return false;
}

fn extractPlanText(arena: Allocator, item_value: std.json.Value) Allocator.Error!?[]const u8 {
    const item_obj = switch (item_value) {
        .object => |value| value,
        else => return null,
    };

    const candidate_keys = [_][]const u8{
        "text", "summary", "plan_summary", "content",
    };

    inline for (candidate_keys) |key| {
        if (item_obj.get(key)) |node| {
            switch (node) {
                .string => |value_str| {
                    const copy = try arena.dupe(u8, value_str);
                    return copy;
                },
                else => {},
            }
        }
    }

    if (item_obj.get("steps")) |steps_node| {
        if (steps_node == .array) {
            const formatted = try formatValueArray(arena, steps_node.array);
            if (formatted.len > 0) return formatted;
        }
    }

    if (item_obj.get("plan")) |plan_node| {
        return try formatValue(arena, plan_node);
    }

    return try formatValue(arena, item_value);
}

fn formatValue(arena: Allocator, value: std.json.Value) Allocator.Error![]const u8 {
    switch (value) {
        .string => |s| {
            const copy = try arena.dupe(u8, s);
            return copy;
        },
        .array => |arr| return try formatValueArray(arena, arr),
        .object => {
            return try std.json.Stringify.valueAlloc(arena, value, .{ .whitespace = .minified });
        },
        else => {
            return try std.json.Stringify.valueAlloc(arena, value, .{ .whitespace = .minified });
        },
    }
}

fn formatValueArray(arena: Allocator, arr: std.json.Array) Allocator.Error![]const u8 {
    const BufferList = std.ArrayList(u8);
    var buffer = BufferList.empty;
    for (arr.items) |elem| {
        const elem_text = try formatValue(arena, elem);
        if (elem_text.len == 0) continue;
        try buffer.appendSlice(arena, "- ");
        try buffer.appendSlice(arena, elem_text);
        try buffer.appendSlice(arena, "\n");
    }
    const slice = try buffer.toOwnedSlice(arena);
    return slice;
}

fn renderSection(
    writer: anytype,
    title: []const u8,
    entries: []const []const u8,
) !void {
    try writer.print("{s}:\n", .{title});
    if (entries.len == 0) {
        try writer.writeAll("- <none>\n\n");
        return;
    }

    for (entries) |entry| {
        var trimmed = std.mem.trim(u8, entry, " \r\n");
        if (trimmed.len == 0) {
            trimmed = "<empty>";
        }
        try writer.print("- {s}\n", .{trimmed});
    }
    try writer.writeAll("\n");
}

fn renderCommandSection(
    writer: anytype,
    title: []const u8,
    commands: []const CommandRecord,
) !void {
    try writer.print("{s}:\n", .{title});
    if (commands.len == 0) {
        try writer.writeAll("- <none>\n\n");
        return;
    }

    for (commands) |cmd| {
        try writer.print(
            "- `{s}` (status: {s}",
            .{ cmd.command, cmd.status },
        );
        if (cmd.exit_code) |code| {
            try writer.print(", exit: {d}", .{code});
        }
        try writer.writeAll(")\n");
        const trimmed_output = std.mem.trim(u8, cmd.aggregated_output, " \r\n");
        if (trimmed_output.len > 0) {
            const preview = truncateForDisplay(trimmed_output, 400);
            try writer.print("  Output: {s}\n", .{preview});
            if (trimmed_output.len > preview.len) {
                try writer.writeAll("  Output truncated...\n");
            }
        }
    }
    try writer.writeAll("\n");
}

fn truncateForDisplay(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    return text[0..limit];
}

fn isLikelyTestCommand(command: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, command, " \t");
    while (it.next()) |token| {
        if (tokenContainsTest(token)) return true;
        if (std.ascii.eqlIgnoreCase(token, "pytest")) return true;
        if (std.ascii.eqlIgnoreCase(token, "tox")) return true;
        if (std.ascii.eqlIgnoreCase(token, "rspec")) return true;
        if (std.ascii.eqlIgnoreCase(token, "ctest")) return true;
        if (std.ascii.eqlIgnoreCase(token, "mvn") and hasNextToken(&it, "test")) return true;
        if (std.ascii.eqlIgnoreCase(token, "gradle") and hasNextToken(&it, "test")) return true;
        if (std.ascii.eqlIgnoreCase(token, "cargo") and hasNextToken(&it, "test")) return true;
        if (std.ascii.eqlIgnoreCase(token, "go") and hasNextToken(&it, "test")) return true;
        if (std.ascii.eqlIgnoreCase(token, "npm") and hasNextToken(&it, "test")) return true;
        if (std.ascii.eqlIgnoreCase(token, "pnpm") and hasNextToken(&it, "test")) return true;
        if (std.ascii.eqlIgnoreCase(token, "yarn") and hasNextToken(&it, "test")) return true;
        if (std.ascii.eqlIgnoreCase(token, "zig") and hasNextToken(&it, "test")) return true;
    }
    return false;
}

fn tokenContainsTest(token: []const u8) bool {
    if (token.len < 4) return false;
    var i: usize = 0;
    while (i + 3 < token.len) : (i += 1) {
        const t = std.ascii.toLower(token[i]);
        const e = std.ascii.toLower(token[i + 1]);
        const s = std.ascii.toLower(token[i + 2]);
        const t2 = std.ascii.toLower(token[i + 3]);
        if (t == 't' and e == 'e' and s == 's' and t2 == 't') {
            const start_ok = i == 0 or !std.ascii.isAlphabetic(token[i - 1]);
            const end_ok = (i + 4 == token.len) or !std.ascii.isAlphabetic(token[i + 4]);
            if (start_ok and end_ok) return true;
        }
    }
    return false;
}

fn hasNextToken(it: *std.mem.TokenIterator(u8, .any), expected: []const u8) bool {
    const snapshot = it.*;
    defer it.* = snapshot;

    if (it.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, expected)) {
            return true;
        }
    }
    return false;
}

test "tokenContainsTest identifies exact word" {
    try std.testing.expect(tokenContainsTest("test"));
    try std.testing.expect(tokenContainsTest("test:watch"));
    try std.testing.expect(tokenContainsTest("unit-test"));
    try std.testing.expect(!tokenContainsTest("contest"));
}

test "isLikelyTestCommand detects common patterns" {
    try std.testing.expect(isLikelyTestCommand("zig build test"));
    try std.testing.expect(isLikelyTestCommand("cargo test --all"));
    try std.testing.expect(!isLikelyTestCommand("cargo build"));
}
