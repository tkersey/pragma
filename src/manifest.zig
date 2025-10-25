const std = @import("std");
const directives = @import("directives.zig");

const Allocator = std.mem.Allocator;
const ManagedArrayList = std.array_list.Managed;

pub const ManifestTask = struct {
    name: ?[]const u8 = null,
    directive: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
};

pub const ManifestStep = struct {
    name: ?[]const u8 = null,
    directive: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    parallel: bool = false,
    tasks: ?[]ManifestTask = null,
};

pub const ManifestDocument = struct {
    core_prompt: ?[]const u8 = null,
    directive: ?[]const u8 = null,
    steps: []ManifestStep = &.{},
};

pub const ManifestTaskView = struct {
    step_name: ?[]const u8,
    task_name: ?[]const u8,
    directive: []const u8,
    prompt: ?[]const u8,
};

pub const OutputWriter = struct {
    ctx: *anyopaque,
    writeFn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn writeAll(self: OutputWriter, data: []const u8) !void {
        return self.writeFn(self.ctx, data);
    }
};

const NullSink = struct {
    pub fn writeAll(self: *@This(), _: []const u8) !void {
        _ = self;
    }
};

var null_sink = NullSink{};

pub fn makeOutputWriter(writer_ptr: anytype) OutputWriter {
    const ptr_info = @typeInfo(@TypeOf(writer_ptr));
    comptime {
        if (ptr_info != .pointer) @compileError("makeOutputWriter expects a pointer to a writer");
    }
    const WriterType = ptr_info.pointer.child;
    const Adapter = struct {
        fn write(ctx: *anyopaque, data: []const u8) anyerror!void {
            const aligned_ctx: *align(@alignOf(WriterType)) anyopaque = @alignCast(ctx);
            const typed_ptr: *WriterType = @ptrCast(aligned_ctx);
            try typed_ptr.writeAll(data);
        }
    };

    return OutputWriter{
        .ctx = @ptrCast(writer_ptr),
        .writeFn = Adapter.write,
    };
}

pub fn nullOutputWriter() OutputWriter {
    return makeOutputWriter(&null_sink);
}

const ManifestTaskCollection = struct {
    tasks: ManagedArrayList(ManifestTaskView),
    names_to_free: ManagedArrayList([]u8),
    parallel: bool,
};

pub fn Dependencies(comptime RunCtxType: type) type {
    return struct {
        loadDirectiveDocument: fn (
            Allocator,
            []const u8,
            ?[]const u8,
            ?[]const u8,
            ?[]const u8,
        ) anyerror!directives.DirectiveDocument,
        assemblePrompt: fn (Allocator, []const u8, directives.OutputContract) anyerror![]u8,
        runCodex: fn (Allocator, *RunCtxType, []const u8, []const u8) anyerror![]u8,
        executeParallel: fn (
            Allocator,
            *RunCtxType,
            *const ManifestDocument,
            *const ManifestStep,
            ?[]const u8,
            ?[]const u8,
            *ManagedArrayList(ManifestTaskView),
            OutputWriter,
            OutputWriter,
        ) anyerror!void,
    };
}

pub fn executeManifest(
    comptime RunCtxType: type,
    allocator: Allocator,
    manifest_path: []const u8,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    run_ctx: *RunCtxType,
    deps: Dependencies(RunCtxType),
) !void {
    var stdout_file = std.fs.File.stdout();
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer_impl = stdout_file.writer(&stdout_buffer);
    const stdout_writer = makeOutputWriter(&stdout_writer_impl);

    var stderr_file = std.fs.File.stderr();
    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer_impl = stderr_file.writer(&stderr_buffer);
    const stderr_writer = makeOutputWriter(&stderr_writer_impl);
    try executeManifestWithWriters(
        RunCtxType,
        allocator,
        manifest_path,
        cli_dir,
        env_dir,
        run_ctx,
        deps,
        stdout_writer,
        stderr_writer,
    );
}

pub fn executeManifestWithWriters(
    comptime RunCtxType: type,
    allocator: Allocator,
    manifest_path: []const u8,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    run_ctx: *RunCtxType,
    deps: Dependencies(RunCtxType),
    stdout_writer: OutputWriter,
    stderr_writer: OutputWriter,
) !void {
    const max_size: usize = 4 * 1024 * 1024;
    const manifest_bytes = try std.fs.cwd().readFileAlloc(manifest_path, allocator, std.Io.Limit.limited(max_size));
    defer allocator.free(manifest_bytes);

    var doc = try parseManifestDocument(allocator, manifest_bytes);
    defer deinitManifestDocument(allocator, doc);

    if (doc.steps.len == 0) {
        try stderr_writer.writeAll("pragma: manifest must define at least one step\n");
        return error.InvalidDirective;
    }

    for (doc.steps, 0..) |*step, step_index| {
        const label = step.name orelse step.directive orelse doc.directive orelse "step";
        const header = try std.fmt.allocPrint(allocator, "=== Step {d}: {s}\n", .{ step_index + 1, label });
        defer allocator.free(header);
        try stdout_writer.writeAll(header);

        var tasks_list = collectManifestTasks(allocator, &doc, step) catch |err| switch (err) {
            error.SerialTasksNotAllowed => {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "pragma: manifest step {s} defines tasks but is missing `parallel: true`\n",
                    .{label},
                );
                defer allocator.free(msg);
                try stderr_writer.writeAll(msg);
                return err;
            },
            else => return err,
        };
        defer {
            for (tasks_list.names_to_free.items) |name_copy| allocator.free(name_copy);
            tasks_list.names_to_free.deinit();
            tasks_list.tasks.deinit();
        }

        if (tasks_list.tasks.items.len == 0) {
            try stderr_writer.writeAll("pragma: manifest step produced no tasks\n");
            return error.InvalidDirective;
        }

        if (tasks_list.parallel) {
            try deps.executeParallel(
                allocator,
                run_ctx,
                &doc,
                step,
                cli_dir,
                env_dir,
                &tasks_list.tasks,
                stdout_writer,
                stderr_writer,
            );
        } else {
            for (tasks_list.tasks.items) |task_view| {
                try executeSerialTask(
                    RunCtxType,
                    allocator,
                    &doc,
                    step,
                    run_ctx,
                    cli_dir,
                    env_dir,
                    task_view,
                    deps,
                    stdout_writer,
                    stderr_writer,
                );
            }
        }
    }
}

pub fn parseManifestDocument(allocator: Allocator, manifest_bytes: []const u8) !ManifestDocument {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidDirective;
    const root_obj = parsed.value.object;

    var doc = ManifestDocument{};

    if (root_obj.get("core_prompt")) |value| {
        if (value != .string) return error.InvalidDirective;
        doc.core_prompt = try allocator.dupe(u8, value.string);
    }

    if (root_obj.get("directive")) |value| {
        if (value != .string) return error.InvalidDirective;
        doc.directive = try allocator.dupe(u8, value.string);
    }

    const steps_node = root_obj.get("steps") orelse return error.InvalidDirective;
    if (steps_node != .array) return error.InvalidDirective;

    var steps = ManagedArrayList(ManifestStep).init(allocator);
    errdefer {
        for (steps.items) |step| deinitManifestStep(allocator, step);
        steps.deinit();
    }

    for (steps_node.array.items) |item| {
        const step = try parseManifestStep(allocator, item);
        errdefer deinitManifestStep(allocator, step);
        try steps.append(step);
    }

    doc.steps = try steps.toOwnedSlice();
    return doc;
}

pub fn deinitManifestDocument(allocator: Allocator, doc: ManifestDocument) void {
    if (doc.core_prompt) |value| allocator.free(value);
    if (doc.directive) |value| allocator.free(value);
    for (doc.steps) |step| {
        deinitManifestStep(allocator, step);
    }
    allocator.free(doc.steps);
}

/// Collect and normalize tasks from a manifest step for execution.
///
/// For parallel steps: Iterates through step.tasks, resolving directive/prompt
/// inheritance from step and doc levels. Task names are allocated and tracked
/// for later cleanup.
///
/// For serial steps: Creates a single task view from the step itself, using
/// step.directive or falling back to doc.directive.
///
/// Returns a ManifestTaskCollection containing the executable task views,
/// ownership information, and parallel/serial flag.
pub fn collectManifestTasks(
    allocator: Allocator,
    doc: *const ManifestDocument,
    step: *const ManifestStep,
) !ManifestTaskCollection {
    var tasks = ManagedArrayList(ManifestTaskView).init(allocator);
    errdefer tasks.deinit();

    var names = ManagedArrayList([]u8).init(allocator);
    errdefer {
        for (names.items) |name_copy| allocator.free(name_copy);
        names.deinit();
    }

    var parallel = step.parallel;

    if (!step.parallel and step.tasks != null) {
        return error.SerialTasksNotAllowed;
    }

    if (step.parallel) {
        const task_list = step.tasks orelse return error.InvalidDirective;
        if (task_list.len == 0) return error.InvalidDirective;

        for (task_list) |task| {
            const directive = task.directive orelse step.directive orelse doc.directive orelse return error.MissingDirective;
            const name = task.name orelse task.directive;
            const resolved_name = if (name) |value| blk: {
                const owned = try allocator.dupe(u8, value);
                errdefer allocator.free(owned);
                try names.append(owned);
                errdefer _ = names.pop();
                break :blk owned;
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

pub fn buildInlinePrompt(
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
    comptime RunCtxType: type,
    allocator: Allocator,
    doc: *const ManifestDocument,
    step: *const ManifestStep,
    run_ctx: *RunCtxType,
    cli_dir: ?[]const u8,
    env_dir: ?[]const u8,
    task_view: ManifestTaskView,
    deps: Dependencies(RunCtxType),
    stdout_writer: OutputWriter,
    stderr_writer: OutputWriter,
) !void {
    var segments = [_]?[]const u8{ doc.core_prompt, step.prompt, task_view.prompt };
    const extra = try buildInlinePrompt(allocator, &segments);
    defer if (extra) |value| allocator.free(value);

    const mut_extra = if (extra) |value| value else null;

    var directive_doc = deps.loadDirectiveDocument(
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

    const assembled = try deps.assemblePrompt(allocator, directive_doc.prompt, directive_doc.contract);
    defer allocator.free(assembled);

    const label = task_view.task_name orelse task_view.directive;

    const response = deps.runCodex(allocator, run_ctx, label, assembled) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "pragma: step {s} codex error ({s})\n", .{ label, @errorName(err) });
        defer allocator.free(msg);
        try stderr_writer.writeAll(msg);
        return err;
    };
    defer allocator.free(response);

    const header = try std.fmt.allocPrint(allocator, "--- Task: {s} (directive: {s})\n", .{ label, task_view.directive });
    defer allocator.free(header);
    try stdout_writer.writeAll(header);
    try stdout_writer.writeAll(response);
    try stdout_writer.writeAll("\n");
}

fn parseManifestStep(allocator: Allocator, item: std.json.Value) !ManifestStep {
    if (item != .object) return error.InvalidDirective;
    const obj = item.object;

    var step = ManifestStep{};

    if (obj.get("name")) |value| {
        if (value != .string) return error.InvalidDirective;
        step.name = try allocator.dupe(u8, value.string);
    }

    if (obj.get("directive")) |value| {
        if (value != .string) return error.InvalidDirective;
        step.directive = try allocator.dupe(u8, value.string);
    }

    if (obj.get("prompt")) |value| {
        if (value != .string) return error.InvalidDirective;
        step.prompt = try allocator.dupe(u8, value.string);
    }

    if (obj.get("parallel")) |value| {
        switch (value) {
            .bool => step.parallel = value.bool,
            else => return error.InvalidDirective,
        }
    }

    if (obj.get("tasks")) |value| {
        if (value != .array) return error.InvalidDirective;
        var tasks = ManagedArrayList(ManifestTask).init(allocator);
        errdefer {
            for (tasks.items) |task| deinitManifestTask(allocator, task);
            tasks.deinit();
        }

        for (value.array.items) |task_item| {
            const task = try parseManifestTask(allocator, task_item);
            errdefer deinitManifestTask(allocator, task);
            try tasks.append(task);
        }

        step.tasks = try tasks.toOwnedSlice();
    }

    return step;
}

fn parseManifestTask(allocator: Allocator, item: std.json.Value) !ManifestTask {
    if (item != .object) return error.InvalidDirective;
    const obj = item.object;

    var task = ManifestTask{};

    if (obj.get("name")) |value| {
        if (value != .string) return error.InvalidDirective;
        task.name = try allocator.dupe(u8, value.string);
    }

    if (obj.get("directive")) |value| {
        if (value != .string) return error.InvalidDirective;
        task.directive = try allocator.dupe(u8, value.string);
    }

    if (obj.get("prompt")) |value| {
        if (value != .string) return error.InvalidDirective;
        task.prompt = try allocator.dupe(u8, value.string);
    }

    return task;
}

fn deinitManifestStep(allocator: Allocator, step: ManifestStep) void {
    if (step.name) |value| allocator.free(value);
    if (step.directive) |value| allocator.free(value);
    if (step.prompt) |value| allocator.free(value);
    if (step.tasks) |tasks| {
        for (tasks) |task| deinitManifestTask(allocator, task);
        allocator.free(tasks);
    }
}

fn deinitManifestTask(allocator: Allocator, task: ManifestTask) void {
    if (task.name) |value| allocator.free(value);
    if (task.directive) |value| allocator.free(value);
    if (task.prompt) |value| allocator.free(value);
}

test "collectManifestTasks errors when serial step defines tasks" {
    const allocator = std.testing.allocator;
    const manifest_json =
        \\{
        \\  "directive": "review",
        \\  "steps": [
        \\    {
        \\      "name": "Serial Step",
        \\      "tasks": [
        \\        { "name": "Nested" }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var doc = try parseManifestDocument(allocator, manifest_json);
    defer deinitManifestDocument(allocator, doc);

    try std.testing.expectError(
        error.SerialTasksNotAllowed,
        collectManifestTasks(allocator, &doc, &doc.steps[0]),
    );
}
