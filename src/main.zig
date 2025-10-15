const std = @import("std");

const Allocator = std.mem.Allocator;
const ManagedArrayList = std.array_list.Managed;
const ArrayList = std.ArrayList;
const builtin = @import("builtin");

const test_support = struct {
    pub var codex_override: ?[]const u8 = null;
};

const OutputContract = union(enum) {
    markdown,
    json,
    plain,
    custom: []const u8,
};

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

    const extraction = try extractDirectiveContract(allocator, prompt_text);
    allocator.free(prompt_text);
    defer allocator.free(extraction.prompt);
    defer switch (extraction.contract) {
        .custom => |value| allocator.free(value),
        else => {},
    };

    const assembled = try assemblePrompt(allocator, extraction.prompt, extraction.contract);
    defer allocator.free(assembled);

    const response = try runCodex(allocator, assembled);
    defer allocator.free(response);

    const stdout_file = std.fs.File.stdout();
    try stdout_file.writeAll(response);
    try stdout_file.writeAll("\n");
}

fn printUsage() !void {
    try std.fs.File.stderr().writeAll(
        "usage: pragma \"<system prompt>\"\n",
    );
}

fn readPrompt(allocator: Allocator, args: *std.process.ArgIterator) ![]u8 {
    const first = args.next() orelse return error.MissingPrompt;

    var buffer = ManagedArrayList(u8).init(allocator);
    defer buffer.deinit();

    try buffer.appendSlice(first);

    while (args.next()) |segment| {
        try buffer.append(' ');
        try buffer.appendSlice(segment);
    }

    return buffer.toOwnedSlice();
}

fn assemblePrompt(
    allocator: Allocator,
    system_prompt: []const u8,
    contract: OutputContract,
) ![]u8 {
    const output_contract = renderOutputContract(contract);

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
            "{s}\n" ++
            "\n" ++
            "### 5. Quality & Safety Gates\n" ++
            "- Self-review for correctness, security, performance, and maintainability before responding.\n" ++
            "- Flag unresolved risks (privilege escalation, prompt injection vectors, data exposure) so orchestrators can intervene.\n" ++
            "- If you detect a better strategy mid-flight, adapt and document the pivot succinctly.\n" ++
            "\n" ++
            "### Directive Uplink\n" ++
            "<directive>\n{s}\n</directive>",
        .{output_contract, system_prompt},
    );
}

fn renderOutputContract(contract: OutputContract) []const u8 {
    const markdown = "- Respond in Markdown using this skeleton:\n"
        ++ "  - `## Result` — the finished deliverable (code blocks, diffs, specs, etc.).\n"
        ++ "  - `## Verification` — evidence of checks performed or gaps still open.\n"
        ++ "  - `## Assumptions` — bullet list of inferred context, if any.\n"
        ++ "  - `## Next Steps` (optional) — only if meaningful follow-up remains.\n"
        ++ "- Keep prose dense and unambiguous; avoid filler commentary.\n";

    const json = "- Respond with a single JSON object encoded as UTF-8.\n"
        ++ "  - Include `result`, `verification`, and `assumptions` keys; each may contain nested structures as needed.\n"
        ++ "  - Provide `next_steps` if meaningful actions remain, otherwise omit the field.\n"
        ++ "- Do not emit any prose outside the JSON payload.\n";

    const plain = "- Respond as concise plain text paragraphs.\n"
        ++ "- Cover results, validation evidence, assumptions, and next steps in distinct paragraphs separated by blank lines.\n"
        ++ "- Avoid markdown syntax unless explicitly requested inside the directive.\n";

    return switch (contract) {
        .markdown => markdown,
        .json => json,
        .plain => plain,
        .custom => |value| value,
    };
}

fn extractDirectiveContract(allocator: Allocator, raw_prompt: []const u8) !struct {
    prompt: []u8,
    contract: OutputContract,
} {
    var contract: OutputContract = .markdown;
    var kept_lines = ManagedArrayList([]const u8).init(allocator);
    defer kept_lines.deinit();

    var block_lines = ManagedArrayList([]const u8).init(allocator);
    defer block_lines.deinit();

    var in_block = false;
    var block_start_line: []const u8 = &.{};

    var lines = std.mem.splitScalar(u8, raw_prompt, '\n');
    while (lines.next()) |line_with_nl| {
        const line = trimTrailingCr(line_with_nl);
        const trimmed = std.mem.trim(u8, line, " \t");

        if (in_block) {
            if (std.mem.eql(u8, trimmed, "pragma-output-contract>>>")) {
                in_block = false;

                const custom_slice = try joinLines(allocator, block_lines.items);
                if (custom_slice.len > 0) {
                    setContract(&contract, allocator, OutputContract{ .custom = custom_slice });
                } else {
                    allocator.free(custom_slice);
                }
                block_lines.clearRetainingCapacity();
                continue;
            }

            try block_lines.append(line);
            continue;
        }

        if (std.mem.eql(u8, trimmed, "<<<pragma-output-contract")) {
            in_block = true;
            block_start_line = line;
            block_lines.clearRetainingCapacity();
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "pragma-output-contract:")) {
            const value_slice = std.mem.trim(u8, trimmed["pragma-output-contract:".len..], " \t");
            if (value_slice.len > 0) {
                const copy = try allocator.dupe(u8, value_slice);
                setContract(&contract, allocator, OutputContract{ .custom = copy });
            } else {
                try kept_lines.append(line);
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "pragma-output-format:")) {
            const value_slice = std.mem.trim(u8, trimmed["pragma-output-format:".len..], " \t");
            if (value_slice.len == 0) {
                try kept_lines.append(line);
                continue;
            }

            if (parseOutputFormatValue(value_slice)) |fmt| {
                setContract(&contract, allocator, fmt);
                continue;
            }

            try kept_lines.append(line);
            continue;
        }

        try kept_lines.append(line);
    }

    if (in_block) {
        try kept_lines.append(block_start_line);
        for (block_lines.items) |block_line| {
            try kept_lines.append(block_line);
        }
    }

    const sanitized = try joinLines(allocator, kept_lines.items);
    return .{
        .prompt = sanitized,
        .contract = contract,
    };
}

fn trimTrailingCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

fn joinLines(allocator: Allocator, lines: []const []const u8) ![]u8 {
    if (lines.len == 0) return allocator.dupe(u8, "");

    var buffer = ManagedArrayList(u8).init(allocator);
    defer buffer.deinit();

    for (lines, 0..) |line, idx| {
        try buffer.appendSlice(line);
        if (idx + 1 < lines.len) {
            try buffer.append('\n');
        }
    }

    return buffer.toOwnedSlice();
}

fn parseOutputFormatValue(value: []const u8) ?OutputContract {
    if (std.ascii.eqlIgnoreCase(value, "markdown")) return OutputContract.markdown;
    if (std.ascii.eqlIgnoreCase(value, "json")) return OutputContract.json;
    if (std.ascii.eqlIgnoreCase(value, "plain")) return OutputContract.plain;
    return null;
}

fn setContract(contract_ptr: *OutputContract, allocator: Allocator, new_contract: OutputContract) void {
    switch (contract_ptr.*) {
        .custom => |existing| allocator.free(existing),
        else => {},
    }

    contract_ptr.* = switch (new_contract) {
        .custom => |value| OutputContract{ .custom = value },
        .markdown => OutputContract.markdown,
        .json => OutputContract.json,
        .plain => OutputContract.plain,
    };
}

test "extractDirectiveContract defaults to markdown with untouched prompt" {
    const allocator = std.testing.allocator;
    const raw = "Analyze repo state.";
    const result = try extractDirectiveContract(allocator, raw);
    defer allocator.free(result.prompt);
    defer switch (result.contract) {
        .custom => |value| allocator.free(value),
        else => {},
    };

    try std.testing.expectEqualStrings(raw, result.prompt);
    try std.testing.expect(result.contract == .markdown);
}

test "extractDirectiveContract parses format directive" {
    const allocator = std.testing.allocator;
    const raw =
        \\pragma-output-format: json
        \\Return snapshot.
    ;
    const result = try extractDirectiveContract(allocator, raw);
    defer allocator.free(result.prompt);
    defer switch (result.contract) {
        .custom => |value| allocator.free(value),
        else => {},
    };

    try std.testing.expectEqualStrings("Return snapshot.", result.prompt);
    try std.testing.expect(result.contract == .json);
}

test "extractDirectiveContract parses custom block" {
    const allocator = std.testing.allocator;
    const raw =
        \\<<<pragma-output-contract
        \\Emit YAML with keys result, verification.
        \\pragma-output-contract>>>
        \\Do the thing.
    ;
    const result = try extractDirectiveContract(allocator, raw);
    defer allocator.free(result.prompt);
    defer switch (result.contract) {
        .custom => |value| allocator.free(value),
        else => {},
    };

    try std.testing.expectEqualStrings("Do the thing.", result.prompt);
    try std.testing.expect(result.contract == .custom);
    try std.testing.expectEqualStrings("Emit YAML with keys result, verification.", result.contract.custom);
}

test "extractDirectiveContract custom block overrides format line" {
    const allocator = std.testing.allocator;
    const raw =
        \\pragma-output-format: json
        \\<<<pragma-output-contract
        \\Emit XML with sections result, verification.
        \\pragma-output-contract>>>
        \\Deliver report.
    ;
    const result = try extractDirectiveContract(allocator, raw);
    defer allocator.free(result.prompt);
    defer switch (result.contract) {
        .custom => |value| allocator.free(value),
        else => {},
    };

    try std.testing.expectEqualStrings("Deliver report.", result.prompt);
    try std.testing.expect(result.contract == .custom);
    try std.testing.expectEqualStrings("Emit XML with sections result, verification.", result.contract.custom);
}

test "extractDirectiveContract leaves unmatched block intact" {
    const allocator = std.testing.allocator;
    const raw =
        \\<<<pragma-output-contract
        \\Incomplete
        \\message.
    ;
    const result = try extractDirectiveContract(allocator, raw);
    defer allocator.free(result.prompt);
    defer switch (result.contract) {
        .custom => |value| allocator.free(value),
        else => {},
    };

    try std.testing.expectEqualStrings(raw, result.prompt);
    try std.testing.expect(result.contract == .markdown);
}

test "assemblePrompt injects json contract instructions" {
    const allocator = std.testing.allocator;
    const prompt = "Do something";
    const assembled = try assemblePrompt(allocator, prompt, OutputContract.json);
    defer allocator.free(assembled);

    try std.testing.expect(std.mem.containsAtLeast(u8, assembled, 1, "Respond with a single JSON object"));
    try std.testing.expect(std.mem.containsAtLeast(u8, assembled, 1, prompt));
}

test "runCodex honors PRAGMA_CODEX_BIN stub" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script_name = "codex-stub.sh";
    {
        var file = try tmp.dir.createFile(script_name, .{ .read = true, .mode = 0o755 });
        defer file.close();
        try file.writeAll(
            "#!/bin/sh\n"
            ++ "cat <<'EOF'\n"
            ++ "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Stub OK\"}}\n"
            ++ "EOF\n",
        );
    }

    const script_path = try tmp.dir.realpathAlloc(allocator, script_name);
    defer allocator.free(script_path);

    test_support.codex_override = script_path;
    defer test_support.codex_override = null;

    const response = try runCodex(allocator, "Hello");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("Stub OK", response);
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
    const codex_env = std.process.getEnvVarOwned(allocator, "PRAGMA_CODEX_BIN") catch null;
    defer if (codex_env) |value| allocator.free(value);

    const codex_exec = blk: {
        if (builtin.is_test) {
            if (test_support.codex_override) |value| break :blk value;
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
    defer allocator.free(argv);

    var process = std.process.Child.init(argv, allocator);
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
