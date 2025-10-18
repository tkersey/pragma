const std = @import("std");

const Allocator = std.mem.Allocator;
const ManagedArrayList = std.array_list.Managed;

pub const OutputContract = union(enum) {
    markdown,
    json,
    plain,
    custom: []const u8,
};

pub const DirectiveDocument = struct {
    prompt: []u8,
    contract: OutputContract,
};

pub const ValidationIssue = struct {
    path: []u8,
    detail: []u8,
};

pub const ValidationStats = struct {
    total: usize = 0,
    skipped: usize = 0,
    ok: usize = 0,
};

pub fn loadDirectiveDocument(
    allocator: Allocator,
    directive_name: []const u8,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    inline_extra: ?[]const u8,
) !DirectiveDocument {
    const path = try resolveDirectivePath(allocator, directive_name, cli_dir, env_dir);
    defer allocator.free(path);

    const max_size: usize = 4 * 1024 * 1024;
    const content = try std.fs.cwd().readFileAlloc(path, allocator, std.Io.Limit.limited(max_size));
    defer allocator.free(content);

    const sections = try splitDirectiveDocument(content);

    var contract_override: ?OutputContract = null;
    defer if (contract_override) |override| {
        switch (override) {
            .custom => |value| allocator.free(value),
            else => {},
        }
    };

    if (sections.frontmatter) |frontmatter| {
        contract_override = try parseDirectiveFrontmatter(allocator, frontmatter);
    }

    var prompt_input: []const u8 = sections.body;
    var combined_owned: ?[]u8 = null;
    defer if (combined_owned) |value| allocator.free(value);

    if (inline_extra) |extra| {
        if (extra.len > 0) {
            combined_owned = try joinDirectiveAndInline(allocator, sections.body, extra);
            prompt_input = combined_owned.?;
        }
    }

    var extraction = try extractDirectiveContract(allocator, prompt_input);
    errdefer allocator.free(extraction.prompt);
    errdefer switch (extraction.contract) {
        .custom => |value| allocator.free(value),
        else => {},
    };

    if (contract_override) |override| {
        setContract(&extraction.contract, allocator, override);
        contract_override = null;
    }

    return .{
        .prompt = extraction.prompt,
        .contract = extraction.contract,
    };
}

pub fn gatherDirectiveDirectories(
    allocator: Allocator,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    include_defaults: bool,
) !ManagedArrayList([]u8) {
    var list = ManagedArrayList([]u8).init(allocator);

    if (cli_dir) |dir| try appendUniqueDir(allocator, &list, dir);
    if (env_dir) |dir| try appendUniqueDir(allocator, &list, dir);

    if (include_defaults) {
        if (try homeDirectivesPath(allocator)) |home_path| {
            defer allocator.free(home_path);
            try appendUniqueDir(allocator, &list, home_path);
        }

        try appendUniqueDir(allocator, &list, ".pragma/directives");
        try appendUniqueDir(allocator, &list, "directives");
    }

    return list;
}

pub fn validateDirectiveDir(
    allocator: Allocator,
    dir_path: []const u8,
    skip_prefix: []const u8,
    issues: *ManagedArrayList(ValidationIssue),
    stats: *ValidationStats,
) !void {
    var dir = (if (std.fs.path.isAbsolute(dir_path))
        std.fs.openDirAbsolute(dir_path, .{ .iterate = true })
    else
        std.fs.cwd().openDir(dir_path, .{ .iterate = true })) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;

        const ext = std.fs.path.extension(entry.name);
        if (!std.mem.eql(u8, ext, ".md") and !std.mem.eql(u8, ext, ".markdown")) continue;

        const base_len = entry.name.len - ext.len;
        const base = entry.name[0..base_len];
        if (std.ascii.startsWithIgnoreCase(base, skip_prefix)) {
            stats.skipped += 1;
            continue;
        }

        stats.total += 1;

        const content = dir.readFileAlloc(entry.name, allocator, std.Io.Limit.limited(4 * 1024 * 1024)) catch {
            try recordIssue(allocator, issues, dir_path, entry.name, "failed to read file");
            continue;
        };
        defer allocator.free(content);

        const trimmed = std.mem.trim(u8, content, " \r\n");
        if (trimmed.len == 0) {
            try recordIssue(allocator, issues, dir_path, entry.name, "body is empty");
            continue;
        }

        const sections = splitDirectiveDocument(content) catch |err| switch (err) {
            error.InvalidDirective => {
                try recordIssue(allocator, issues, dir_path, entry.name, "malformed frontmatter block");
                continue;
            },
            else => return err,
        };

        if (sections.frontmatter) |front| {
            const contract_override = parseDirectiveFrontmatter(allocator, front) catch {
                try recordIssue(allocator, issues, dir_path, entry.name, "invalid YAML frontmatter");
                continue;
            };
            defer if (contract_override) |value| switch (value) {
                .custom => |text| allocator.free(text),
                else => {},
            };
        }

        const doc_result = extractDirectiveContract(allocator, sections.body) catch {
            try recordIssue(allocator, issues, dir_path, entry.name, "invalid inline pragma directives");
            continue;
        };
        defer allocator.free(doc_result.prompt);
        defer switch (doc_result.contract) {
            .custom => |value| allocator.free(value),
            else => {},
        };

        if (std.mem.trim(u8, doc_result.prompt, " \r\n").len == 0) {
            try recordIssue(allocator, issues, dir_path, entry.name, "directive body reduced to empty after sanitization");
            continue;
        }

        stats.ok += 1;
    }
}

/// Parse and extract output contract directives from raw prompt text.
///
/// Recognizes two directive formats:
/// 1. Inline: `pragma-output-format: json|markdown|plain`
/// 2. Block: `<<<pragma-output-contract` ... `pragma-output-contract>>>`
/// 3. Inline custom: `pragma-output-contract: <custom text>`
///
/// All recognized directives are removed from the returned prompt.
/// Unclosed block directives are left in the prompt text.
///
/// Returns a DirectiveDocument containing the sanitized prompt and parsed contract.
pub fn extractDirectiveContract(allocator: Allocator, raw_prompt: []const u8) !DirectiveDocument {
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
    return DirectiveDocument{
        .prompt = sanitized,
        .contract = contract,
    };
}

fn resolveDirectivePath(
    allocator: Allocator,
    directive_name: []const u8,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
) ![]u8 {
    if (looksLikePath(directive_name)) {
        return resolveProvidedPath(allocator, directive_name);
    }

    if (cli_dir) |dir| {
        if (try findDirectiveInDir(allocator, dir, directive_name)) |path| {
            return path;
        }
    }

    if (env_dir) |dir| {
        if (try findDirectiveInDir(allocator, dir, directive_name)) |path| {
            return path;
        }
    }

    if (try findDirectiveInHome(allocator, directive_name)) |path| {
        return path;
    }

    const defaults = [_][]const u8{
        ".pragma/directives",
        "directives",
    };

    for (defaults) |dir| {
        if (try findDirectiveInDir(allocator, dir, directive_name)) |path| {
            return path;
        }
    }

    return error.DirectiveNotFound;
}

fn resolveProvidedPath(allocator: Allocator, raw: []const u8) ![]u8 {
    std.fs.cwd().access(raw, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.DirectiveNotFound,
        else => return err,
    };
    return allocator.dupe(u8, raw);
}

fn looksLikePath(identifier: []const u8) bool {
    if (std.mem.indexOfScalar(u8, identifier, '/') != null) return true;
    if (std.mem.indexOfScalar(u8, identifier, '\\') != null) return true;
    if (std.mem.endsWith(u8, identifier, ".md")) return true;
    if (std.mem.endsWith(u8, identifier, ".markdown")) return true;
    return false;
}

fn findDirectiveInDir(
    allocator: Allocator,
    dir: []const u8,
    name: []const u8,
) !?[]u8 {
    const exts = [_][]const u8{ ".md", ".markdown" };
    for (exts) |ext| {
        const file_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, ext });
        defer allocator.free(file_name);

        const candidate = try std.fs.path.join(allocator, &.{ dir, file_name });
        defer allocator.free(candidate);

        std.fs.cwd().access(candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        const copy = try allocator.dupe(u8, candidate);
        return copy;
    }

    return null;
}

fn findDirectiveInHome(
    allocator: Allocator,
    name: []const u8,
) !?[]u8 {
    const home_dir = try homeDirectivesPath(allocator) orelse return null;
    defer allocator.free(home_dir);
    return try findDirectiveInDir(allocator, home_dir, name);
}

fn homeDirectivesPath(allocator: Allocator) !?[]u8 {
    const home_env = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    if (home_env == null) return null;
    const home = home_env.?;
    defer allocator.free(home);

    const joined = try std.fs.path.join(allocator, &.{ home, ".pragma", "directives" });
    return joined;
}

fn appendUniqueDir(
    allocator: Allocator,
    list: *ManagedArrayList([]u8),
    dir: []const u8,
) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, dir)) return;
    }

    const copy = try allocator.dupe(u8, dir);
    try list.append(copy);
}

fn recordIssue(
    allocator: Allocator,
    issues: *ManagedArrayList(ValidationIssue),
    dir_path: []const u8,
    file_name: []const u8,
    message: []const u8,
) !void {
    const combined = try std.fs.path.join(allocator, &.{ dir_path, file_name });
    defer allocator.free(combined);
    const path_copy = try allocator.dupe(u8, combined);
    const detail_copy = try allocator.dupe(u8, message);
    try issues.append(.{ .path = path_copy, .detail = detail_copy });
}

fn splitDirectiveDocument(content: []const u8) !struct {
    frontmatter: ?[]const u8,
    body: []const u8,
} {
    if (!std.mem.startsWith(u8, content, "---")) {
        return .{ .frontmatter = null, .body = content };
    }

    var cursor: usize = "---".len;
    if (cursor >= content.len) return error.InvalidDirective;

    if (content[cursor] == '\r') {
        cursor += 1;
    }
    if (cursor >= content.len or content[cursor] != '\n') {
        return error.InvalidDirective;
    }
    cursor += 1;
    const meta_start = cursor;

    while (cursor <= content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, cursor, '\n') orelse content.len;
        var line = content[cursor..line_end];
        line = trimTrailingCr(line);
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.eql(u8, trimmed, "---")) {
            const meta_slice = std.mem.trimRight(u8, content[meta_start..cursor], " \r\n");
            const body_start = if (line_end == content.len) content.len else line_end + 1;
            const body_slice = content[body_start..];
            return .{ .frontmatter = meta_slice, .body = body_slice };
        }

        if (line_end == content.len) break;
        cursor = line_end + 1;
    }

    return error.InvalidDirective;
}

/// Parse YAML frontmatter for the `output_contract` key.
///
/// Supports three value formats:
/// 1. Simple: `output_contract: json` → returns OutputContract.json
/// 2. Quoted: `output_contract: "markdown"` → returns OutputContract.markdown
/// 3. Block scalar: `output_contract: |` → returns OutputContract.custom with multi-line text
///
/// Block scalars use YAML's `|` or `>` syntax where subsequent indented lines
/// form the contract text until a non-indented line or end of input.
///
/// Returns null if no `output_contract` key found.
fn parseDirectiveFrontmatter(allocator: Allocator, raw: []const u8) !?OutputContract {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);

    var splitter = std.mem.splitScalar(u8, raw, '\n');
    while (splitter.next()) |line| {
        try lines.append(allocator, line);
    }

    var idx: usize = 0;
    while (idx < lines.items.len) {
        const trimmed_line = std.mem.trim(u8, lines.items[idx], " \t\r");
        if (trimmed_line.len == 0 or trimmed_line[0] == '#') {
            idx += 1;
            continue;
        }

        const colon_index = std.mem.indexOfScalar(u8, trimmed_line, ':') orelse {
            idx += 1;
            continue;
        };

        const key = std.mem.trim(u8, trimmed_line[0..colon_index], " \t");
        var rest = std.mem.trim(u8, trimmed_line[colon_index + 1 ..], " \t");

        if (!std.mem.eql(u8, key, "output_contract")) {
            idx += 1;
            continue;
        }

        if (rest.len > 0 and (rest[0] == '|' or rest[0] == '>')) {
            idx += 1;
            var buffer = std.ArrayList(u8).empty;
            defer buffer.deinit(allocator);

            while (idx < lines.items.len) {
                const original = std.mem.trimRight(u8, lines.items[idx], "\r");

                if (original.len == 0) {
                    if (buffer.items.len > 0) try buffer.append(allocator, '\n');
                    idx += 1;
                    continue;
                }

                if (original[0] != ' ' and original[0] != '\t') break;

                const content = std.mem.trimLeft(u8, original, " \t");
                if (buffer.items.len > 0) try buffer.append(allocator, '\n');
                try buffer.appendSlice(allocator, content);
                idx += 1;
            }

            const block_text = try buffer.toOwnedSlice(allocator);
            return OutputContract{ .custom = block_text };
        }

        if (rest.len == 0) {
            idx += 1;
            continue;
        }

        const normalized = std.mem.trim(u8, rest, "\"");
        if (parseOutputFormatValue(normalized)) |fmt| {
            return fmt;
        }

        const copy = try allocator.dupe(u8, normalized);
        return OutputContract{ .custom = copy };
    }

    return null;
}

fn joinDirectiveAndInline(
    allocator: Allocator,
    directive_body: []const u8,
    inline_extra: []const u8,
) ![]u8 {
    var buffer = ManagedArrayList(u8).init(allocator);
    defer buffer.deinit();

    if (directive_body.len > 0) {
        try buffer.appendSlice(directive_body);
        if (directive_body.len >= 2 and std.mem.eql(u8, directive_body[directive_body.len - 2 ..], "\n\n")) {
            // already has blank line suffix
        } else if (directive_body[directive_body.len - 1] == '\n') {
            try buffer.append('\n');
        } else {
            try buffer.appendSlice("\n\n");
        }
    }

    if (inline_extra.len > 0) {
        try buffer.appendSlice(inline_extra);
    }

    return buffer.toOwnedSlice();
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

test "splitDirectiveDocument finds frontmatter and body" {
    const doc =
        \\---
        \\output_contract: json
        \\---
        \\Do the thing.
    ;
    const sections = try splitDirectiveDocument(doc);
    try std.testing.expect(sections.frontmatter != null);
    try std.testing.expectEqualStrings("output_contract: json", sections.frontmatter.?);
    try std.testing.expectEqualStrings("Do the thing.", std.mem.trim(u8, sections.body, " \r\n"));
}

test "parseDirectiveFrontmatter handles output contract" {
    const allocator = std.testing.allocator;
    const meta =
        \\output_contract: plain
    ;
    const contract = try parseDirectiveFrontmatter(allocator, meta);
    try std.testing.expect(contract != null);
    try std.testing.expect(contract.? == .plain);
}

test "parseDirectiveFrontmatter handles custom block" {
    const allocator = std.testing.allocator;
    const meta =
        \\output_contract: |
        \\  Emit XML output.
    ;
    var contract = try parseDirectiveFrontmatter(allocator, meta);
    defer if (contract) |*value| switch (value.*) {
        .custom => |custom| allocator.free(custom),
        else => {},
    };
    try std.testing.expect(contract != null);
    try std.testing.expect(contract.? == .custom);
    try std.testing.expectEqualStrings("Emit XML output.", contract.?.custom);
}

test "loadDirectiveDocument reads file and merges inline prompt" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("directives");
    {
        var file = try tmp.dir.createFile("directives/review.md", .{});
        defer file.close();
        try file.writeAll(
            "---\n" ++ "output_contract: json\n" ++ "---\n" ++ "You are a reviewer.\n",
        );
    }

    const directives_path = try tmp.dir.realpathAlloc(allocator, "directives");
    defer allocator.free(directives_path);

    const extra = "Assess the latest commit.";
    const doc = try loadDirectiveDocument(allocator, "review", directives_path, null, extra);
    defer allocator.free(doc.prompt);
    defer switch (doc.contract) {
        .custom => |value| allocator.free(value),
        else => {},
    };

    try std.testing.expect(doc.contract == .json);
    try std.testing.expect(std.mem.indexOfScalar(u8, doc.prompt, '\n') != null);
    try std.testing.expect(std.mem.containsAtLeast(u8, doc.prompt, 1, "You are a reviewer."));
    try std.testing.expect(std.mem.containsAtLeast(u8, doc.prompt, 1, extra));
}

test "validateDirectiveDir reports malformed files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("directives");
    {
        var file = try tmp.dir.createFile("directives/good.md", .{});
        defer file.close();
        try file.writeAll(
            "---\n" ++ "output_contract: markdown\n" ++ "---\n" ++ "Provide a summary.\n",
        );
    }
    {
        var file = try tmp.dir.createFile("directives/bad.md", .{});
        defer file.close();
        try file.writeAll(
            "---\n" ++ "output_contract: json\n" ++ "missing terminator\n" ++ "Provide detail.\n",
        );
    }
    {
        var file = try tmp.dir.createFile("directives/codex-special.md", .{});
        defer file.close();
        try file.writeAll("Some content\n");
    }

    const dir_path = try tmp.dir.realpathAlloc(allocator, "directives");
    defer allocator.free(dir_path);

    var issues = ManagedArrayList(ValidationIssue).init(allocator);
    defer {
        for (issues.items) |issue| {
            allocator.free(issue.path);
            allocator.free(issue.detail);
        }
        issues.deinit();
    }

    var stats = ValidationStats{};
    try validateDirectiveDir(allocator, dir_path, "codex", &issues, &stats);

    try std.testing.expect(stats.total == 2);
    try std.testing.expect(stats.ok == 1);
    try std.testing.expect(stats.skipped == 1);
    try std.testing.expect(issues.items.len == 1);
    try std.testing.expect(std.mem.containsAtLeast(u8, issues.items[0].path, 1, "bad.md"));
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
