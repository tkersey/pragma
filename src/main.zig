const std = @import("std");

const Allocator = std.mem.Allocator;
const ManagedArrayList = std.array_list.Managed;

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
        "You are a specialized sub-agent invoked by the `pragma` CLI.\n" ++
            "Operate autonomously, follow the call-site instructions precisely, and reply in concise markdown.\n" ++
            "If more situational context is required, request it explicitly.\n\n" ++
            "<system-prompt>\n{s}\n</system-prompt>",
        .{ system_prompt },
    );
}

fn runCodex(allocator: Allocator, prompt: []const u8) ![]u8 {
    const argv = [_][]const u8{
        "codex",
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

    const stdout_bytes = try process.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try process.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr_bytes);

    _ = process.wait() catch {};

    if (stderr_bytes.len > 0) {
        _ = try std.fs.File.stderr().writeAll(stderr_bytes);
    }

    const message = try extractAgentMarkdown(allocator, stdout_bytes);
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
