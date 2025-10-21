const std = @import("std");
const directives = @import("directives.zig");
const manifest = @import("manifest.zig");
const codex = @import("codex.zig");

const Allocator = std.mem.Allocator;
const ManagedArrayList = std.array_list.Managed;
const ArrayList = std.ArrayList;
const builtin = @import("builtin");
const parallel_module = if (builtin.os.tag == .windows)
    @import("parallel_windows.zig")
else
    @import("parallel_posix.zig");

const OutputContract = directives.OutputContract;
const DirectiveDocument = directives.DirectiveDocument;
const ValidationIssue = directives.ValidationIssue;
const ValidationStats = directives.ValidationStats;
const loadDirectiveDocument = directives.loadDirectiveDocument;
const gatherDirectiveDirectories = directives.gatherDirectiveDirectories;
const validateDirectiveDir = directives.validateDirectiveDir;
const extractDirectiveContract = directives.extractDirectiveContract;
pub const ManifestTask = manifest.ManifestTask;
pub const ManifestStep = manifest.ManifestStep;
pub const ManifestDocument = manifest.ManifestDocument;
pub const ManifestTaskView = manifest.ManifestTaskView;
const CodexCommand = codex.CodexCommand;
const RunContext = codex.RunContext;
const buildCodexCommand = codex.buildCodexCommand;
const runCodex = codex.runCodex;
const extractAgentMarkdown = codex.extractAgentMarkdown;

const CliInvocation = struct {
    directive: ?[]u8,
    directives_dir: ?[]u8,
    inline_prompt: ?[]u8,
    validate_directives: bool,
    manifest: ?[]u8,
    keep_run_artifacts: bool,
};

const ParallelHelpers = struct {
    buildInlinePrompt: fn (Allocator, []const ?[]const u8) anyerror!?[]u8,
    loadDirectiveDocument: fn (Allocator, []const u8, ?[]const u8, ?[]const u8, ?[]const u8) anyerror!DirectiveDocument,
    assemblePrompt: fn (Allocator, []const u8, OutputContract) anyerror![]u8,
    buildCodexCommand: fn (Allocator, []const u8) anyerror!CodexCommand,
    runCodex: fn (Allocator, *RunContext, []const u8, []const u8) anyerror![]u8,
    extractAgentMarkdown: fn (Allocator, []const u8) anyerror![]u8,
};

const parallel_helpers = ParallelHelpers{
    .buildInlinePrompt = manifest.buildInlinePrompt,
    .loadDirectiveDocument = loadDirectiveDocument,
    .assemblePrompt = assemblePrompt,
    .buildCodexCommand = buildCodexCommand,
    .runCodex = runCodex,
    .extractAgentMarkdown = extractAgentMarkdown,
};

fn parseBoolEnv(allocator: Allocator, name: []const u8, default_value: bool) bool {
    const env = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(env);
    if (env.len == 0) return default_value;
    if (std.ascii.eqlIgnoreCase(env, "1") or std.ascii.eqlIgnoreCase(env, "true") or std.ascii.eqlIgnoreCase(env, "yes")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(env, "0") or std.ascii.eqlIgnoreCase(env, "false") or std.ascii.eqlIgnoreCase(env, "no")) {
        return false;
    }
    return default_value;
}

fn runDirectiveValidation(
    allocator: Allocator,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
) !void {
    var directories = try gatherDirectiveDirectories(allocator, cli_dir, env_dir, true);
    defer {
        for (directories.items) |dir_path| allocator.free(dir_path);
        directories.deinit();
    }

    if (directories.items.len == 0) {
        const line = try std.fmt.allocPrint(allocator, "pragma: no directive directories discovered\n", .{});
        defer allocator.free(line);
        try std.fs.File.stdout().writeAll(line);
        return;
    }

    var issues = ManagedArrayList(ValidationIssue).init(allocator);
    defer {
        for (issues.items) |issue| {
            allocator.free(issue.path);
            allocator.free(issue.detail);
        }
        issues.deinit();
    }

    var stats = ValidationStats{};
    for (directories.items) |dir_path| {
        try validateDirectiveDir(allocator, dir_path, "codex", &issues, &stats);
    }

    if (issues.items.len > 0) {
        for (issues.items) |issue| {
            const line = try std.fmt.allocPrint(allocator, "{s}: {s}\n", .{ issue.path, issue.detail });
            defer allocator.free(line);
            try std.fs.File.stderr().writeAll(line);
        }
        const summary = try std.fmt.allocPrint(
            allocator,
            "pragma: validation failed — {d} issue(s) across {d} directive(s)\n",
            .{ issues.items.len, stats.total },
        );
        defer allocator.free(summary);
        try std.fs.File.stderr().writeAll(summary);
        return error.ValidationFailed;
    }

    const summary = try std.fmt.allocPrint(
        allocator,
        "Validated {d}/{d} directive(s); skipped {d} (prefix match).\n",
        .{ stats.ok, stats.total, stats.skipped },
    );
    defer allocator.free(summary);
    try std.fs.File.stdout().writeAll(summary);
}

fn executeParallelTasks(
    allocator: Allocator,
    run_ctx: *RunContext,
    doc: *const ManifestDocument,
    step: *const ManifestStep,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    tasks: *ManagedArrayList(ManifestTaskView),
    stdout_writer: manifest.OutputWriter,
    stderr_writer: manifest.OutputWriter,
) !void {
    const disable_parallel = builtin.is_test or parseBoolEnv(allocator, "PRAGMA_DISABLE_PARALLEL", false);
    if (disable_parallel) {
        return runTasksSequential(allocator, &parallel_helpers, run_ctx, doc, step, cli_dir, env_dir, tasks, stdout_writer, stderr_writer);
    }
    return parallel_module.executeParallelTasks(allocator, &parallel_helpers, run_ctx, doc, step, cli_dir, env_dir, tasks, stdout_writer, stderr_writer);
}

fn runTasksSequential(
    allocator: Allocator,
    helpers_ptr: anytype,
    run_ctx: anytype,
    doc: *const ManifestDocument,
    step: *const ManifestStep,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    tasks: *ManagedArrayList(ManifestTaskView),
    stdout_writer: manifest.OutputWriter,
    stderr_writer: manifest.OutputWriter,
) !void {
    const helpers = helpers_ptr.*;
    for (tasks.items) |task_view| {
        var segments = [_]?[]const u8{ doc.core_prompt, step.prompt, task_view.prompt };
        const extra = try helpers.buildInlinePrompt(allocator, &segments);
        defer if (extra) |value| allocator.free(value);
        const mut_extra = if (extra) |value| value else null;

        var directive_doc = helpers.loadDirectiveDocument(
            allocator,
            task_view.directive,
            cli_dir,
            env_dir,
            mut_extra,
        ) catch |err| {
            const label = task_view.task_name orelse task_view.directive;
            const msg = try std.fmt.allocPrint(allocator, "pragma: step {s} failed to load directive ({s})\n", .{ label, @errorName(err) });
            defer allocator.free(msg);
            try stderr_writer.writeAll(msg);
            return err;
        };
        defer allocator.free(directive_doc.prompt);
        defer switch (directive_doc.contract) {
            .custom => |value| allocator.free(value),
            else => {},
        };

        const assembled = try helpers.assemblePrompt(allocator, directive_doc.prompt, directive_doc.contract);
        defer allocator.free(assembled);

        const label = task_view.task_name orelse task_view.directive;

        const response = helpers.runCodex(allocator, run_ctx, label, assembled) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "pragma: step {s} codex error ({s})\n", .{ label, @errorName(err) });
            defer allocator.free(msg);
            try stderr_writer.writeAll(msg);
            return err;
        };
        defer allocator.free(response);

        const message = helpers.extractAgentMarkdown(allocator, response) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "pragma: step {s} output parse error ({s})\n", .{ label, @errorName(err) });
            defer allocator.free(msg);
            try stderr_writer.writeAll(msg);
            return err;
        };
        defer allocator.free(message);

        const header = try std.fmt.allocPrint(allocator, "--- Task: {s} (directive: {s})\n", .{ label, task_view.directive });
        defer allocator.free(header);
        try stdout_writer.writeAll(header);
        try stdout_writer.writeAll(message);
        try stdout_writer.writeAll("\n");
    }
}

fn testRunCodexStub(
    allocator: Allocator,
    run_ctx: *TestRunContext,
    label: []const u8,
    prompt: []const u8,
) ![]u8 {
    _ = prompt;

    const stub = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Stub Manifest OK\"}}\n";
    try run_ctx.handleStdout(allocator, label, stub);
    return allocator.dupe(u8, "Stub Manifest OK");
}

fn testLoadDirectiveStub(
    allocator: Allocator,
    directive_name: []const u8,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    inline_extra: ?[]const u8,
) !DirectiveDocument {
    _ = cli_dir;
    _ = env_dir;
    _ = inline_extra;

    const prompt = try std.fmt.allocPrint(allocator, "Directive {s}", .{directive_name});
    errdefer allocator.free(prompt);

    return DirectiveDocument{
        .prompt = prompt,
        .contract = OutputContract.markdown,
    };
}

fn testAssemblePromptStub(
    allocator: Allocator,
    prompt: []const u8,
    contract: OutputContract,
) ![]u8 {
    _ = contract;
    return allocator.dupe(u8, prompt);
}

fn testExecuteParallelStub(
    allocator: Allocator,
    run_ctx: *TestRunContext,
    doc: *const ManifestDocument,
    step: *const ManifestStep,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    tasks: *ManagedArrayList(ManifestTaskView),
    stdout_writer: manifest.OutputWriter,
    stderr_writer: manifest.OutputWriter,
) !void {
    const Helpers = struct {
        buildInlinePrompt: *const fn (Allocator, []const ?[]const u8) anyerror!?[]u8,
        loadDirectiveDocument: *const fn (Allocator, []const u8, ?[]const u8, ?[]const u8, ?[]const u8) anyerror!DirectiveDocument,
        assemblePrompt: *const fn (Allocator, []const u8, OutputContract) anyerror![]u8,
        runCodex: *const fn (Allocator, *TestRunContext, []const u8, []const u8) anyerror![]u8,
        extractAgentMarkdown: *const fn (Allocator, []const u8) anyerror![]u8,
    };

    var helpers = Helpers{
        .buildInlinePrompt = manifest.buildInlinePrompt,
        .loadDirectiveDocument = testLoadDirectiveStub,
        .assemblePrompt = testAssemblePromptStub,
        .runCodex = testRunCodexStub,
        .extractAgentMarkdown = extractAgentMarkdown,
    };

    try runTasksSequential(allocator, &helpers, run_ctx, doc, step, cli_dir, env_dir, tasks, stdout_writer, stderr_writer);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    var unknown_flag: ?[]u8 = null;
    defer if (unknown_flag) |value| allocator.free(value);

    var invocation = parseCliInvocation(allocator, &args, &unknown_flag) catch |err| switch (err) {
        error.MissingDirectiveValue, error.MissingDirectivesDirValue, error.MissingDirectiveName, error.ShowUsage => {
            try printUsage();
            return;
        },
        error.MissingManifestValue => {
            try printUsage();
            return;
        },
        error.UnknownFlag => {
            const flag = unknown_flag orelse "";
            const message = try std.fmt.allocPrint(allocator, "pragma: unknown flag {s}\n", .{flag});
            defer allocator.free(message);
            try std.fs.File.stderr().writeAll(message);
            try printUsage();
            return;
        },
        else => return err,
    };
    defer if (invocation.directive) |value| allocator.free(value);
    defer if (invocation.directives_dir) |value| allocator.free(value);
    defer if (invocation.inline_prompt) |value| allocator.free(value);
    defer if (invocation.manifest) |value| allocator.free(value);

    const env_directives_dir = std.process.getEnvVarOwned(allocator, "PRAGMA_DIRECTIVES_DIR") catch null;
    defer if (env_directives_dir) |value| allocator.free(value);

    const keep_env = parseBoolEnv(allocator, "PRAGMA_KEEP_RUN", false);

    if (invocation.validate_directives) {
        runDirectiveValidation(
            allocator,
            invocation.directives_dir,
            env_directives_dir,
        ) catch |err| switch (err) {
            error.ValidationFailed => return,
            else => return err,
        };
        return;
    }

    if (invocation.manifest) |manifest_path| {
        if (invocation.directive != null or invocation.inline_prompt != null) {
            try std.fs.File.stderr().writeAll("pragma: --manifest cannot be combined with inline prompts or --directive\n");
            return;
        }
        var run_ctx = try RunContext.init(allocator, keep_env or invocation.keep_run_artifacts);
        defer run_ctx.deinit(allocator);
        const deps = manifest.Dependencies(RunContext){
            .loadDirectiveDocument = loadDirectiveDocument,
            .assemblePrompt = assemblePrompt,
            .runCodex = runCodex,
            .executeParallel = executeParallelTasks,
        };
        try manifest.executeManifest(
            RunContext,
            allocator,
            manifest_path,
            invocation.directives_dir,
            env_directives_dir,
            &run_ctx,
            deps,
        );
        return;
    }

    var extraction: DirectiveDocument = undefined;
    if (invocation.directive) |directive_name| {
        const inline_extra: ?[]const u8 = if (invocation.inline_prompt) |value| value else null;
        extraction = loadDirectiveDocument(
            allocator,
            directive_name,
            invocation.directives_dir,
            env_directives_dir,
            inline_extra,
        ) catch |err| switch (err) {
            error.DirectiveNotFound => {
                try std.fs.File.stderr().writeAll("pragma: directive not found\n");
                return;
            },
            error.InvalidDirective => {
                try std.fs.File.stderr().writeAll("pragma: directive is malformed\n");
                return;
            },
            else => return err,
        };
        if (invocation.inline_prompt) |value| {
            allocator.free(value);
            invocation.inline_prompt = null;
        }
    } else {
        const raw_prompt = invocation.inline_prompt orelse {
            try printUsage();
            return;
        };
        extraction = try extractDirectiveContract(allocator, raw_prompt);
        allocator.free(raw_prompt);
        invocation.inline_prompt = null;
    }
    defer allocator.free(extraction.prompt);
    defer switch (extraction.contract) {
        .custom => |value| allocator.free(value),
        else => {},
    };

    const assembled = try assemblePrompt(allocator, extraction.prompt, extraction.contract);
    defer allocator.free(assembled);

    var run_ctx = try RunContext.init(allocator, keep_env or invocation.keep_run_artifacts);
    defer run_ctx.deinit(allocator);

    const run_label: []const u8 = if (invocation.directive) |value| value else "prompt";

    const response = try runCodex(allocator, &run_ctx, run_label, assembled);
    defer allocator.free(response);

    const stdout_file = std.fs.File.stdout();
    try stdout_file.writeAll(response);
    try stdout_file.writeAll("\n");
}

fn printUsage() !void {
    try std.fs.File.stderr().writeAll(
        "usage: pragma [--validate-directives] [--manifest FILE] [--directive NAME] [--directives-dir DIR] [--keep-run-artifacts] [--] \"<system prompt>\"\n",
    );
}

/// Helper to parse flag that takes a string value (supports both --flag value and --flag=value syntax)
fn parseStringFlag(
    allocator: Allocator,
    raw_arg: []const u8,
    flag_name: []const u8,
    args: *std.process.ArgIterator,
    target: *?[]u8,
    missing_error: anyerror,
) !bool {
    const eq_prefix = std.fmt.allocPrint(allocator, "--{s}=", .{flag_name}) catch return false;
    defer allocator.free(eq_prefix);
    const space_prefix = std.fmt.allocPrint(allocator, "--{s}", .{flag_name}) catch return false;
    defer allocator.free(space_prefix);

    if (std.mem.startsWith(u8, raw_arg, eq_prefix)) {
        const value = raw_arg[eq_prefix.len..];
        if (value.len == 0) return missing_error;
        if (target.*) |existing| allocator.free(existing);
        target.* = try allocator.dupe(u8, value);
        return true;
    }

    if (std.mem.eql(u8, raw_arg, space_prefix)) {
        const value = args.next() orelse return missing_error;
        if (target.*) |existing| allocator.free(existing);
        target.* = try allocator.dupe(u8, value);
        return true;
    }

    return false;
}

fn parseCliInvocation(
    allocator: Allocator,
    args: *std.process.ArgIterator,
    unknown_flag_out: *?[]u8,
) !CliInvocation {
    if (unknown_flag_out.*) |existing| {
        allocator.free(existing);
        unknown_flag_out.* = null;
    }

    var directive: ?[]u8 = null;
    var directives_dir: ?[]u8 = null;
    var prompt_buffer = ManagedArrayList(u8).init(allocator);
    defer prompt_buffer.deinit();

    var reading_prompt = false;
    var invocation = CliInvocation{
        .directive = null,
        .directives_dir = null,
        .inline_prompt = null,
        .validate_directives = false,
        .manifest = null,
        .keep_run_artifacts = false,
    };

    while (args.next()) |raw_arg| {
        if (!reading_prompt and raw_arg.len > 0 and raw_arg[0] == '-') {
            // Simple delimiter to start reading prompt
            if (std.mem.eql(u8, raw_arg, "--")) {
                reading_prompt = true;
                continue;
            }

            // Boolean flags
            if (std.mem.eql(u8, raw_arg, "--validate-directives")) {
                invocation.validate_directives = true;
                continue;
            }
            if (std.mem.eql(u8, raw_arg, "--keep-run-artifacts")) {
                invocation.keep_run_artifacts = true;
                continue;
            }
            if (std.mem.eql(u8, raw_arg, "--help") or std.mem.eql(u8, raw_arg, "-h")) {
                return error.ShowUsage;
            }

            // String value flags (handles both --flag value and --flag=value)
            if (try parseStringFlag(allocator, raw_arg, "manifest", args, &invocation.manifest, error.MissingManifestValue)) continue;
            if (try parseStringFlag(allocator, raw_arg, "directive", args, &directive, error.MissingDirectiveValue)) continue;
            if (try parseStringFlag(allocator, raw_arg, "directives-dir", args, &directives_dir, error.MissingDirectivesDirValue)) continue;

            // Unknown flag - bubble up for caller to handle
            const copy = try allocator.dupe(u8, raw_arg);
            if (unknown_flag_out.*) |existing| allocator.free(existing);
            unknown_flag_out.* = copy;
            return error.UnknownFlag;
        }

        if (reading_prompt and raw_arg.len == 0) continue;

        if (prompt_buffer.items.len > 0) try prompt_buffer.append(' ');
        try prompt_buffer.appendSlice(raw_arg);
    }

    const inline_prompt = if (prompt_buffer.items.len == 0) null else try prompt_buffer.toOwnedSlice();

    invocation.directive = directive;
    invocation.directives_dir = directives_dir;
    invocation.inline_prompt = inline_prompt;
    return invocation;
}

/// Assemble the complete sub-agent prompt with field manual and output contract.
///
/// Takes a user-provided system prompt (directive) and wraps it in the Pragma
/// Sub-Agent Field Manual that provides:
/// - Orientation guidelines for understanding the task
/// - Execution workflow (plan → execute → validate)
/// - Collaboration and tooling best practices
/// - Output contract matching the specified format
/// - Quality and safety gates
///
/// The assembled prompt enforces consistent sub-agent behavior across all invocations.
pub fn assemblePrompt(
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
        .{ output_contract, system_prompt },
    );
}

fn renderOutputContract(contract: OutputContract) []const u8 {
    const markdown = "- Respond in Markdown using this skeleton:\n" ++ "  - `## Result` — the finished deliverable (code blocks, diffs, specs, etc.).\n" ++ "  - `## Verification` — evidence of checks performed or gaps still open.\n" ++ "  - `## Assumptions` — bullet list of inferred context, if any.\n" ++ "  - `## Next Steps` (optional) — only if meaningful follow-up remains.\n" ++ "- Keep prose dense and unambiguous; avoid filler commentary.\n";

    const json = "- Respond with a single JSON object encoded as UTF-8.\n" ++ "  - Include `result`, `verification`, and `assumptions` keys; each may contain nested structures as needed.\n" ++ "  - Provide `next_steps` if meaningful actions remain, otherwise omit the field.\n" ++ "- Do not emit any prose outside the JSON payload.\n";

    const plain = "- Respond as concise plain text paragraphs.\n" ++ "- Cover results, validation evidence, assumptions, and next steps in distinct paragraphs separated by blank lines.\n" ++ "- Avoid markdown syntax unless explicitly requested inside the directive.\n";

    return switch (contract) {
        .markdown => markdown,
        .json => json,
        .plain => plain,
        .custom => |value| value,
    };
}

const TestLogEntry = struct {
    label: []u8,
    content: []u8,
};

const TestRunContext = struct {
    allocator: Allocator,
    stdout_entries: ManagedArrayList(TestLogEntry),
    stderr_entries: ManagedArrayList(TestLogEntry),

    fn init(allocator: Allocator) TestRunContext {
        return .{
            .allocator = allocator,
            .stdout_entries = ManagedArrayList(TestLogEntry).init(allocator),
            .stderr_entries = ManagedArrayList(TestLogEntry).init(allocator),
        };
    }

    fn deinit(self: *TestRunContext) void {
        const allocator = self.allocator;
        for (self.stdout_entries.items) |entry| {
            allocator.free(entry.label);
            allocator.free(entry.content);
        }
        self.stdout_entries.deinit();

        for (self.stderr_entries.items) |entry| {
            allocator.free(entry.label);
            allocator.free(entry.content);
        }
        self.stderr_entries.deinit();
    }

    pub fn handleStdout(self: *TestRunContext, allocator: Allocator, label: []const u8, content: []const u8) !void {
        const label_copy = try allocator.dupe(u8, label);
        errdefer allocator.free(label_copy);
        const content_copy = try allocator.dupe(u8, content);
        errdefer allocator.free(content_copy);
        try self.stdout_entries.append(.{ .label = label_copy, .content = content_copy });
    }

    pub fn handleStderr(self: *TestRunContext, allocator: Allocator, label: []const u8, content: []const u8) !void {
        const label_copy = try allocator.dupe(u8, label);
        errdefer allocator.free(label_copy);
        const content_copy = try allocator.dupe(u8, content);
        errdefer allocator.free(content_copy);
        try self.stderr_entries.append(.{ .label = label_copy, .content = content_copy });
    }
};

test "executeManifest runs serial and parallel tasks" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest_content =
        \\{
        \\  "directive": "review",
        \\  "core_prompt": "Shared context",
        \\  "steps": [
        \\    {
        \\      "name": "Serial Review",
        \\      "prompt": "Focus on the latest changes."
        \\    },
        \\    {
        \\      "name": "Parallel Checks",
        \\      "parallel": true,
        \\      "tasks": [
        \\        {
        \\          "name": "Check A",
        \\          "prompt": "Look for syntax issues."
        \\        },
        \\        {
        \\          "name": "Check B",
        \\          "prompt": "Inspect documentation."
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    {
        var file = try tmp.dir.createFile("plan.json", .{});
        defer file.close();
        try file.writeAll(manifest_content);
    }
    const manifest_path = try tmp.dir.realpathAlloc(allocator, "plan.json");
    defer allocator.free(manifest_path);

    var run_ctx = TestRunContext.init(allocator);
    defer run_ctx.deinit();

    const StubDeps = struct {
        fn run(test_allocator: Allocator, ctx: *TestRunContext, label: []const u8, prompt: []const u8) ![]u8 {
            return testRunCodexStub(test_allocator, ctx, label, prompt);
        }

        fn parallel(
            test_allocator: Allocator,
            ctx: *TestRunContext,
            doc: *const ManifestDocument,
            step: *const ManifestStep,
            cli_dir: ?[]const u8,
            env_dir: ?[]const u8,
            tasks: *ManagedArrayList(ManifestTaskView),
            stdout_writer: manifest.OutputWriter,
            stderr_writer: manifest.OutputWriter,
        ) !void {
            return testExecuteParallelStub(test_allocator, ctx, doc, step, cli_dir, env_dir, tasks, stdout_writer, stderr_writer);
        }
    };

    const deps = manifest.Dependencies(TestRunContext){
        .loadDirectiveDocument = testLoadDirectiveStub,
        .assemblePrompt = testAssemblePromptStub,
        .runCodex = StubDeps.run,
        .executeParallel = StubDeps.parallel,
    };
    const stdout_writer = manifest.nullOutputWriter();
    const stderr_writer = manifest.nullOutputWriter();

    try manifest.executeManifestWithWriters(
        TestRunContext,
        allocator,
        manifest_path,
        null,
        null,
        &run_ctx,
        deps,
        stdout_writer,
        stderr_writer,
    );

    try std.testing.expectEqual(@as(usize, 3), run_ctx.stdout_entries.items.len);
    try std.testing.expectEqualStrings("Serial Review", run_ctx.stdout_entries.items[0].label);
    try std.testing.expect(std.mem.containsAtLeast(u8, run_ctx.stdout_entries.items[0].content, 1, "\"Stub Manifest OK\""));
    try std.testing.expectEqualStrings("Check A", run_ctx.stdout_entries.items[1].label);
    try std.testing.expectEqualStrings("Check B", run_ctx.stdout_entries.items[2].label);
}

test "executeManifest runs serial and parallel tasks (real codex)" {
    const allocator = std.testing.allocator;

    const real_env = std.process.getEnvVarOwned(allocator, "PRAGMA_TEST_REAL_CODEX") catch null;
    defer if (real_env) |value| allocator.free(value);
    if (real_env == null) return;

    const allow_real_env = std.process.getEnvVarOwned(allocator, "PRAGMA_ALLOW_REAL_CODEX_TESTS") catch null;
    defer if (allow_real_env) |value| allocator.free(value);

    const allow_real = blk: {
        if (allow_real_env) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len == 0) break :blk false;
            if (std.ascii.eqlIgnoreCase(trimmed, "1") or std.ascii.eqlIgnoreCase(trimmed, "true") or std.ascii.eqlIgnoreCase(trimmed, "yes")) break :blk true;
            break :blk false;
        }
        break :blk false;
    };

    if (!allow_real) return;

    const codex_env = std.process.getEnvVarOwned(allocator, "PRAGMA_CODEX_BIN") catch null;
    defer if (codex_env) |value| allocator.free(value);
    if (codex_env == null or codex_env.?.len == 0) return;

    const saved_override = codex.test_support.codex_override;
    defer codex.test_support.codex_override = saved_override;
    codex.test_support.codex_override = null;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("directives");
    {
        var file = try tmp.dir.createFile("directives/review.md", .{});
        defer file.close();
        try file.writeAll(
            "---\n" ++
                "output_contract: markdown\n" ++
                "---\n" ++
                "Respond concisely.\n",
        );
    }

    const directives_path = try tmp.dir.realpathAlloc(allocator, "directives");
    defer allocator.free(directives_path);

    const manifest_content =
        \\{
        \\  "directive": "review",
        \\  "core_prompt": "Shared context",
        \\  "steps": [
        \\    {
        \\      "name": "Serial Review",
        \\      "prompt": "Focus on the latest changes."
        \\    },
        \\    {
        \\      "name": "Parallel Checks",
        \\      "parallel": true,
        \\      "tasks": [
        \\        {
        \\          "name": "Check A",
        \\          "prompt": "Look for syntax issues."
        \\        },
        \\        {
        \\          "name": "Check B",
        \\          "prompt": "Inspect documentation."
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    {
        var file = try tmp.dir.createFile("plan.json", .{});
        defer file.close();
        try file.writeAll(manifest_content);
    }
    const manifest_path = try tmp.dir.realpathAlloc(allocator, "plan.json");
    defer allocator.free(manifest_path);

    var run_ctx = try RunContext.init(allocator, false);
    defer run_ctx.deinit(allocator);

    const deps = manifest.Dependencies(RunContext){
        .loadDirectiveDocument = loadDirectiveDocument,
        .assemblePrompt = assemblePrompt,
        .runCodex = runCodex,
        .executeParallel = executeParallelTasks,
    };
    const stdout_writer = manifest.nullOutputWriter();
    const stderr_writer = manifest.nullOutputWriter();

    try manifest.executeManifestWithWriters(
        RunContext,
        allocator,
        manifest_path,
        directives_path,
        null,
        &run_ctx,
        deps,
        stdout_writer,
        stderr_writer,
    );
}

test "assemblePrompt injects json contract instructions" {
    const allocator = std.testing.allocator;
    const prompt = "Do something";
    const assembled = try assemblePrompt(allocator, prompt, OutputContract.json);
    defer allocator.free(assembled);

    try std.testing.expect(std.mem.containsAtLeast(u8, assembled, 1, "Respond with a single JSON object"));
    try std.testing.expect(std.mem.containsAtLeast(u8, assembled, 1, prompt));
}
