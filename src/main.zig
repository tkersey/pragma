const std = @import("std");

const Allocator = std.mem.Allocator;
const ManagedArrayList = std.array_list.Managed;
const ArrayList = std.ArrayList;
const builtin = @import("builtin");
const ymlz = @import("ymlz");

const test_support = struct {
    pub var codex_override: ?[]const u8 = null;
};

const OutputContract = union(enum) {
    markdown,
    json,
    plain,
    custom: []const u8,
};

const DirectiveFrontmatter = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    output_contract: ?[]const u8 = null,
};

const CliInvocation = struct {
    directive: ?[]u8,
    directives_dir: ?[]u8,
    inline_prompt: ?[]u8,
    validate_directives: bool,
    manifest: ?[]u8,
};

const DirectiveDocument = struct {
    prompt: []u8,
    contract: OutputContract,
};

const ValidationIssue = struct {
    path: []u8,
    detail: []u8,
};

const ValidationStats = struct {
    total: usize = 0,
    skipped: usize = 0,
    ok: usize = 0,
};

const ManifestTask = struct {
    name: ?[]const u8 = null,
    directive: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
};

const ManifestStep = struct {
    name: ?[]const u8 = null,
    directive: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    parallel: bool = false,
    tasks: ?[]ManifestTask = null,
};

const ManifestDocument = struct {
    core_prompt: ?[]const u8 = null,
    directive: ?[]const u8 = null,
    steps: []ManifestStep = &.{},
};

const ManifestTaskView = struct {
    step_name: ?[]const u8,
    task_name: ?[]const u8,
    directive: []const u8,
    prompt: ?[]const u8,
};

const ManifestTaskCollection = struct {
    tasks: ManagedArrayList(ManifestTaskView),
    names_to_free: ManagedArrayList([]u8),
    parallel: bool,
};

const ParallelTaskContext = struct {
    allocator: Allocator,
    directive: []const u8,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    core_prompt: ?[]const u8,
    step_prompt: ?[]const u8,
    task_prompt: ?[]const u8,
    label_step: ?[]const u8,
    label_task: ?[]const u8,
    response: ?[]u8,
    err: ?anyerror = null,
};

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

fn executeManifest(
    allocator: Allocator,
    manifest_path: []const u8,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
) !void {
    const max_size: usize = 4 * 1024 * 1024;
    const manifest_bytes = try std.fs.cwd().readFileAlloc(allocator, manifest_path, max_size);
    defer allocator.free(manifest_bytes);

    var parser = try ymlz.Ymlz(ManifestDocument).init(allocator);
    const doc = parser.loadRaw(manifest_bytes) catch {
        parser.deinit(ManifestDocument{ .steps = &.{} });
        return error.InvalidDirective;
    };
    defer parser.deinit(doc);

    if (doc.steps.len == 0) {
        try std.fs.File.stderr().writeAll("pragma: manifest must define at least one step\n");
        return error.InvalidDirective;
    }

    const stdout_file = std.fs.File.stdout();
    const stderr_file = std.fs.File.stderr();

    for (doc.steps, 0..) |step, step_index| {
        const label = step.name orelse step.directive orelse doc.directive orelse "step";
        const header = try std.fmt.allocPrint(allocator, "=== Step {d}: {s}\n", .{ step_index + 1, label });
        defer allocator.free(header);
        try stdout_file.writeAll(header);

        var tasks_list = try collectManifestTasks(allocator, &doc, &step);
        defer {
            for (tasks_list.names_to_free.items) |name_copy| allocator.free(name_copy);
            tasks_list.names_to_free.deinit();
            tasks_list.tasks.deinit();
        }

        if (tasks_list.tasks.items.len == 0) {
            try stderr_file.writeAll("pragma: manifest step produced no tasks\n");
            return error.InvalidDirective;
        }

        if (tasks_list.parallel) {
            try executeParallelTasks(
                allocator,
                &doc,
                &step,
                cli_dir,
                env_dir,
                &tasks_list.tasks,
            );
        } else {
            for (tasks_list.tasks.items) |task_view| {
                try executeSerialTask(
                    allocator,
                    &doc,
                    &step,
                    cli_dir,
                    env_dir,
                    task_view,
                );
            }
        }
    }
}

fn collectManifestTasks(
    allocator: Allocator,
    doc: *const ManifestDocument,
    step: *const ManifestStep,
) !ManifestTaskCollection {
    var tasks = ManagedArrayList(ManifestTaskView).init(allocator);
    var names = ManagedArrayList([]u8).init(allocator);
    var parallel = step.parallel;

    if (step.tasks) |task_list| {
        if (step.parallel and task_list.len == 0) return error.InvalidDirective;
        if (step.parallel and task_list.len <= 1) parallel = false;
        for (task_list, 0..) |task, idx| {
            const directive = task.directive orelse step.directive orelse doc.directive orelse return error.MissingDirective;
            const name = task.name orelse step.name orelse directive;
            const resolved_name: []const u8 = if (name.len == 0) blk: {
                const generated = try std.fmt.allocPrint(allocator, "task-{d}", .{idx + 1});
                try names.append(generated);
                break :blk generated;
            } else name;

            try tasks.append(.{
                .step_name = step.name,
                .task_name = resolved_name,
                .directive = directive,
                .prompt = task.prompt,
            });
        }
    } else {
        const directive = step.directive orelse doc.directive orelse return error.MissingDirective;
        const name = step.name orelse directive;
        try tasks.append(.{
            .step_name = step.name,
            .task_name = name,
            .directive = directive,
            .prompt = step.prompt,
        });
        parallel = false;
    }

    return ManifestTaskCollection{
        .tasks = tasks,
        .names_to_free = names,
        .parallel = parallel,
    };
}

fn buildInlinePrompt(
    allocator: Allocator,
    segments: []const ?[]const u8,
) !?[]u8 {
    var buffer = ManagedArrayList(u8).init(allocator);
    defer buffer.deinit();

    var appended: bool = false;
    for (segments) |segment_opt| {
        if (segment_opt) |segment| {
            const trimmed = std.mem.trim(u8, segment, " \r\n");
            if (trimmed.len == 0) continue;
            if (appended) {
                try buffer.appendSlice("\n\n");
            }
            try buffer.appendSlice(trimmed);
            appended = true;
        }
    }

    if (!appended) return null;
    return try buffer.toOwnedSlice();
}

fn executeSerialTask(
    allocator: Allocator,
    doc: *const ManifestDocument,
    step: *const ManifestStep,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    task_view: ManifestTaskView,
) !void {
    var segments = [_]?[]const u8{ doc.core_prompt, step.prompt, task_view.prompt };
    const extra = try buildInlinePrompt(allocator, &segments);
    defer if (extra) |value| allocator.free(value);

    const mut_extra = if (extra) |value| value else null;

    const directive_doc = loadDirectiveDocument(
        allocator,
        task_view.directive,
        cli_dir,
        env_dir,
        mut_extra,
    ) catch |err| {
        const label = task_view.task_name orelse task_view.directive;
        const msg = try std.fmt.allocPrint(allocator, "pragma: step {s} failed to load directive ({s})\n", .{ label, @errorName(err) });
        defer allocator.free(msg);
        try std.fs.File.stderr().writeAll(msg);
        return err;
    };
    defer allocator.free(directive_doc.prompt);
    defer switch (directive_doc.contract) {
        .custom => |value| allocator.free(value),
        else => {},
    };

    const assembled = try assemblePrompt(allocator, directive_doc.prompt, directive_doc.contract);
    defer allocator.free(assembled);

    const response = runCodex(allocator, assembled) catch |err| {
        const label = task_view.task_name orelse task_view.directive;
        const msg = try std.fmt.allocPrint(allocator, "pragma: step {s} codex error ({s})\n", .{ label, @errorName(err) });
        defer allocator.free(msg);
        try std.fs.File.stderr().writeAll(msg);
        return err;
    };
    defer allocator.free(response);

    const label = task_view.task_name orelse task_view.directive;
    const header = try std.fmt.allocPrint(allocator, "--- Task: {s} (directive: {s})\n", .{ label, task_view.directive });
    defer allocator.free(header);
    try std.fs.File.stdout().writeAll(header);
    try std.fs.File.stdout().writeAll(response);
    try std.fs.File.stdout().writeAll("\n");
}

fn executeParallelTasks(
    allocator: Allocator,
    doc: *const ManifestDocument,
    step: *const ManifestStep,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    tasks: *ManagedArrayList(ManifestTaskView),
) !void {
    var contexts = ManagedArrayList(ParallelTaskContext).init(allocator);
    defer contexts.deinit();

    const thread_allocator: Allocator = std.heap.page_allocator;

    for (tasks.items) |task_view| {
        try contexts.append(.{
            .allocator = thread_allocator,
            .directive = task_view.directive,
            .cli_dir = cli_dir,
            .env_dir = env_dir,
            .core_prompt = doc.core_prompt,
            .step_prompt = step.prompt,
            .task_prompt = task_view.prompt,
            .label_step = step.name,
            .label_task = task_view.task_name,
            .response = null,
            .err = null,
        });
    }

    var threads = ManagedArrayList(std.Thread).init(allocator);
    defer threads.deinit();

    for (contexts.items) |*ctx| {
        const thread = try std.Thread.spawn(.{}, manifestTaskThread, .{ctx});
        try threads.append(thread);
    }

    for (threads.items) |thread| {
        thread.join();
    }

    for (contexts.items) |*ctx| {
        if (ctx.err) |err| {
            const label = ctx.label_task orelse ctx.directive;
            const msg = try std.fmt.allocPrint(allocator, "pragma: parallel task {s} failed ({s})\n", .{ label, @errorName(err) });
            defer allocator.free(msg);
            try std.fs.File.stderr().writeAll(msg);
            return err;
        }
    }

    for (contexts.items) |*ctx| {
        const label = ctx.label_task orelse ctx.directive;
        const header = try std.fmt.allocPrint(allocator, "--- Parallel Task: {s} (directive: {s})\n", .{ label, ctx.directive });
        defer allocator.free(header);
        try std.fs.File.stdout().writeAll(header);
        if (ctx.response) |resp| {
            defer ctx.allocator.free(resp);
            try std.fs.File.stdout().writeAll(resp);
        }
        try std.fs.File.stdout().writeAll("\n");
    }
}

fn manifestTaskThread(ctx: *ParallelTaskContext) void {
    var segments = [_]?[]const u8{ ctx.core_prompt, ctx.step_prompt, ctx.task_prompt };
    const extra = buildInlinePrompt(ctx.allocator, &segments) catch |err| {
        ctx.err = err;
        return;
    };
    defer if (extra) |value| ctx.allocator.free(value);

    const mut_extra = if (extra) |value| value else null;

    const directive_doc = loadDirectiveDocument(
        ctx.allocator,
        ctx.directive,
        ctx.cli_dir,
        ctx.env_dir,
        mut_extra,
    ) catch |err| {
        ctx.err = err;
        return;
    };
    defer ctx.allocator.free(directive_doc.prompt);
    defer switch (directive_doc.contract) {
        .custom => |value| ctx.allocator.free(value),
        else => {},
    };

    const assembled = assemblePrompt(ctx.allocator, directive_doc.prompt, directive_doc.contract) catch |err| {
        ctx.err = err;
        return;
    };
    defer ctx.allocator.free(assembled);

    const response = runCodex(ctx.allocator, assembled) catch |err| {
        ctx.err = err;
        return;
    };
    ctx.response = response;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    var invocation = parseCliInvocation(allocator, &args) catch |err| switch (err) {
        error.MissingDirectiveValue, error.MissingDirectivesDirValue, error.MissingDirectiveName, error.ShowUsage => {
            try printUsage();
            return;
        },
        error.MissingManifestValue => {
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
        try executeManifest(allocator, manifest_path, invocation.directives_dir, env_directives_dir);
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

    const response = try runCodex(allocator, assembled);
    defer allocator.free(response);

    const stdout_file = std.fs.File.stdout();
    try stdout_file.writeAll(response);
    try stdout_file.writeAll("\n");
}

fn printUsage() !void {
    try std.fs.File.stderr().writeAll(
        "usage: pragma [--validate-directives] [--manifest FILE] [--directive NAME] [--directives-dir DIR] [--] \"<system prompt>\"\n",
    );
}

fn parseCliInvocation(allocator: Allocator, args: *std.process.ArgIterator) !CliInvocation {
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
    };

    while (args.next()) |raw_arg| {
        if (!reading_prompt and raw_arg.len > 0 and raw_arg[0] == '-') {
            if (std.mem.eql(u8, raw_arg, "--")) {
                reading_prompt = true;
                continue;
            }
            if (std.mem.eql(u8, raw_arg, "--validate-directives")) {
                invocation.validate_directives = true;
                continue;
            }
            if (std.mem.eql(u8, raw_arg, "--manifest")) {
                const value = args.next() orelse return error.MissingManifestValue;
                if (invocation.manifest) |existing| allocator.free(existing);
                invocation.manifest = try allocator.dupe(u8, value);
                continue;
            }
            if (std.mem.startsWith(u8, raw_arg, "--manifest=")) {
                const value = raw_arg["--manifest=".len..];
                if (value.len == 0) return error.MissingManifestValue;
                if (invocation.manifest) |existing| allocator.free(existing);
                invocation.manifest = try allocator.dupe(u8, value);
                continue;
            }
            if (std.mem.eql(u8, raw_arg, "--directive")) {
                const value = args.next() orelse return error.MissingDirectiveValue;
                if (directive) |existing| allocator.free(existing);
                directive = try allocator.dupe(u8, value);
                continue;
            }
            if (std.mem.startsWith(u8, raw_arg, "--directive=")) {
                const value = raw_arg["--directive=".len..];
                if (value.len == 0) return error.MissingDirectiveName;
                if (directive) |existing| allocator.free(existing);
                directive = try allocator.dupe(u8, value);
                continue;
            }
            if (std.mem.eql(u8, raw_arg, "--directives-dir")) {
                const value = args.next() orelse return error.MissingDirectivesDirValue;
                if (directives_dir) |existing| allocator.free(existing);
                directives_dir = try allocator.dupe(u8, value);
                continue;
            }
            if (std.mem.startsWith(u8, raw_arg, "--directives-dir=")) {
                const value = raw_arg["--directives-dir=".len..];
                if (value.len == 0) return error.MissingDirectivesDirValue;
                if (directives_dir) |existing| allocator.free(existing);
                directives_dir = try allocator.dupe(u8, value);
                continue;
            }
            if (std.mem.eql(u8, raw_arg, "--help") or std.mem.eql(u8, raw_arg, "-h")) {
                return error.ShowUsage;
            }
            reading_prompt = true;
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

fn loadDirectiveDocument(
    allocator: Allocator,
    directive_name: []const u8,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    inline_extra: ?[]const u8,
) !DirectiveDocument {
    const path = try resolveDirectivePath(allocator, directive_name, cli_dir, env_dir);
    defer allocator.free(path);

    const max_size: usize = 4 * 1024 * 1024;
    const content = try std.fs.cwd().readFileAlloc(allocator, path, max_size);
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

    if (contract_override) |override| {
        setContract(&extraction.contract, allocator, override);
        contract_override = null;
    }

    return .{
        .prompt = extraction.prompt,
        .contract = extraction.contract,
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

fn gatherDirectiveDirectories(
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

fn homeDirectivesPath(allocator: Allocator) !?[]u8 {
    const home_env = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    if (home_env == null) return null;
    const home = home_env.?;
    defer allocator.free(home);

    const joined = try std.fs.path.join(allocator, &.{ home, ".pragma", "directives" });
    return joined;
}

fn validateDirectiveDir(
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

        const content = dir.readFileAlloc(allocator, entry.name, 4 * 1024 * 1024) catch {
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

fn parseDirectiveFrontmatter(allocator: Allocator, raw: []const u8) !?OutputContract {
    var parser = try ymlz.Ymlz(DirectiveFrontmatter).init(allocator);
    const metadata = parser.loadRaw(raw) catch {
        return error.InvalidDirective;
    };
    defer parser.deinit(metadata);

    if (metadata.output_contract) |value| {
        const has_newline = std.mem.indexOfScalar(u8, value, '\n') != null;
        const normalized = if (has_newline)
            std.mem.trimRight(u8, value, " \r\n")
        else
            std.mem.trim(u8, value, " \t\r\n");
        if (normalized.len == 0) return null;

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

fn extractDirectiveContract(allocator: Allocator, raw_prompt: []const u8) !DirectiveDocument {
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

test "executeManifest runs serial and parallel tasks" {
    const allocator = std.testing.allocator;
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
        \\directive: review
        \\core_prompt: |
        \\  Shared context
        \\steps:
        \\  - name: Serial Review
        \\    prompt: |
        \\      Focus on the latest changes.
        \\  - name: Parallel Checks
        \\    parallel: true
        \\    tasks:
        \\      - name: Check A
        \\        prompt: Look for syntax issues.
        \\      - name: Check B
        \\        prompt: Inspect documentation.
    ;

    {
        var file = try tmp.dir.createFile("plan.yml", .{});
        defer file.close();
        try file.writeAll(manifest_content);
    }
    const manifest_path = try tmp.dir.realpathAlloc(allocator, "plan.yml");
    defer allocator.free(manifest_path);

    {
        var file = try tmp.dir.createFile("codex-stub.sh", .{ .read = true, .mode = 0o755 });
        defer file.close();
        try file.writeAll(
            "#!/bin/sh\n" ++ "cat <<'EOF'\n" ++ "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Stub Manifest OK\"}}\n" ++ "EOF\n",
        );
    }

    const stub_path = try tmp.dir.realpathAlloc(allocator, "codex-stub.sh");
    defer allocator.free(stub_path);

    test_support.codex_override = stub_path;
    defer test_support.codex_override = null;

    try executeManifest(allocator, manifest_path, directives_path, null);
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
            "#!/bin/sh\n" ++ "cat <<'EOF'\n" ++ "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Stub OK\"}}\n" ++ "EOF\n",
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
