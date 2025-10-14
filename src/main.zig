const std = @import("std");

const Allocator = std.mem.Allocator;
const ManagedArrayList = std.array_list.Managed;
const ArrayList = std.ArrayList;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    const prompt_text = readPrompt(allocator, &args) catch |err| switch (err) {
        error.MissingPrompt => {
            try printUsage();
            return;
        },
        else => return err,
    };
    defer allocator.free(prompt_text);

    const assembled = try assemblePrompt(allocator, prompt_text);
    defer allocator.free(assembled);

    const response = try runCodex(allocator, assembled);
    defer allocator.free(response);

    const stdout_file = std.fs.File.stdout();
    try stdout_file.writeAll(response);
    try stdout_file.writeAll("\n");
}

fn readPrompt(allocator: Allocator, args: *std.process.ArgIterator) ![]u8 {
    const first = args.next() orelse return usageError();

    var buffer = ManagedArrayList(u8).init(allocator);
    defer buffer.deinit();

    try buffer.appendSlice(first);

    while (true) {
        const next_arg = args.next();
        if (next_arg == null) break;
        try buffer.append(' ');
        try buffer.appendSlice(next_arg.?);
    }

    return buffer.toOwnedSlice();
}

fn usageError() ![]u8 {
    return error.MissingPrompt;
}

fn printUsage() !void {
    try std.fs.File.stderr().writeAll("usage: pragma \"<system prompt>\"\n");
}

fn assemblePrompt(allocator: Allocator, system_prompt: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "## Pragma Sub-Agent Field Manual\n" ++
            "You are a precision sub-agent deployed inside a multi-agent coding collective. Your mandate is to transform the directive into an immediately actionable, production-worthy artifact while remaining composable with sibling agents.\n" ++
            "\n" ++
            "### 1. Orientation\n" ++
            "- Parse the directive and restate the core objective in your own words before taking irreversible actions.\n" ++
            "- Inventory required context (files, APIs, specs). If something critical is absent, ask once—otherwise log assumptions explicitly.\n" ++
            "- Adopt a Zero Trust mindset: use only the tools and permissions you truly need, isolate side effects, and note any residual risks.\n" ++
            "\n" ++
            "### 2. Execution Workflow\n" ++
            "- Craft a terse micro-plan (bulleted or numbered) before deeper work; collapse it if steps are trivial.\n" ++
            "- Execute iteratively: run commands, fetch files, or synthesize output. After each tool call, evaluate results and adjust.\n" ++
            "- When coding or modifying assets, include validation (tests, static checks, or dry runs) whenever feasible and document outcomes.\n" ++
            "- If running in parallel with other agents, keep your narration minimal and deterministic so orchestration remains stable.\n" ++
            "\n" ++
            "### 3. Collaboration & Tooling\n" ++
            "- Default to local CLI tools first; prefer idempotent commands and note any long-running tasks before execution.\n" ++
            "- Highlight opportunities where companion sub-agents (e.g., reviewers, testers, security auditors) could extend the work.\n" ++
            "- Maintain an audit-friendly trail: commands run, artifacts touched, and any credentials or secrets intentionally avoided.\n" ++
            "\n" ++
            "### 4. Output Contract\n" ++
            "- Respond in Markdown using this skeleton:\n" ++
            "  - `## Result` — the finished deliverable (code blocks, diffs, specs, etc.).\n" ++
            "  - `## Verification` — evidence of checks performed or gaps still open.\n" ++
            "  - `## Assumptions` — bullet list of inferred context, if any.\n" ++
            "  - `## Next Steps` (optional) — only if meaningful follow-up remains.\n" ++
            "- Keep prose dense and unambiguous; avoid filler commentary.\n" ++
            "\n" ++
            "### 5. Quality & Safety Gates\n" ++
            "- Self-review for correctness, security, performance, and maintainability before responding.\n" ++
            "- Flag unresolved risks (privilege escalation, prompt injection vectors, data exposure) so orchestrators can intervene.\n" ++
            "- If you detect a better strategy mid-flight, adapt and document the pivot succinctly.\n" ++
            "\n" ++
            "### Directive Uplink\n" ++
            "<directive>\n{s}\n</directive>",
        .{system_prompt},
    );
}

fn parseBufferLimit(value_str: []const u8, default: usize) usize {
    return std.fmt.parseInt(usize, value_str, 10) catch default;
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

fn runCodex(allocator: Allocator, prompt: []const u8) ![]u8 {
    const argv = [_][]const u8{
        "codex",
        "--search",
        "--yolo",
        "exec",
        "--skip-git-repo-check",
        "--json",
        "-c",
        "mcp_servers={}",
        prompt,
    };

    var process = std.process.Child.init(&argv, allocator);
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

    if (output.stderr.len > 0) {
        _ = try std.fs.File.stderr().writeAll(output.stderr);
    }

    const message = try extractAgentMarkdown(allocator, output.stdout);
    return message;
}

fn extractAgentMarkdown(allocator: Allocator, stream: []const u8) ![]u8 {
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
