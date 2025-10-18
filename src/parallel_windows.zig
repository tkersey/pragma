const std = @import("std");
const manifest = @import("manifest.zig");

const Allocator = std.mem.Allocator;
const ManagedArrayList = std.array_list.Managed;

fn ParallelTaskContext(comptime HelpersType: type, comptime RunCtxType: type) type {
    return struct {
        allocator: Allocator,
        helpers: *const HelpersType,
        run_ctx: RunCtxType,
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
    const helpers_ptr = helpers;
    const HelpersType = @TypeOf(helpers_ptr.*);
    const Context = ParallelTaskContext(HelpersType, @TypeOf(run_ctx));

    var contexts = ManagedArrayList(Context).init(allocator);
    errdefer {
        for (contexts.items) |*ctx| {
            if (ctx.response) |resp| {
                ctx.allocator.free(resp);
                ctx.response = null;
            }
        }
        contexts.deinit();
    }

    const thread_allocator: Allocator = std.heap.page_allocator;

    for (tasks.items) |task_view| {
        try contexts.append(.{
            .allocator = thread_allocator,
            .helpers = helpers_ptr,
            .run_ctx = run_ctx,
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
    errdefer {
        for (threads.items) |thread| {
            thread.join();
        }
        threads.deinit();
    }

    for (contexts.items) |*ctx| {
        const thread = try std.Thread.spawn(.{}, manifestTaskThread, .{ctx});
        try threads.append(thread);
    }

    for (threads.items) |thread| {
        thread.join();
    }

    for (contexts.items) |*ctx| {
        if (ctx.err) |err| {
            for (contexts.items) |*cleanup_ctx| {
                if (cleanup_ctx.response) |resp| {
                    cleanup_ctx.allocator.free(resp);
                    cleanup_ctx.response = null;
                }
            }
            const label = ctx.label_task orelse ctx.directive;
            const msg = try std.fmt.allocPrint(allocator, "pragma: parallel task {s} failed ({s})\n", .{ label, @errorName(err) });
            defer allocator.free(msg);
            try stderr_writer.writeAll(msg);
            return err;
        }
    }

    for (contexts.items) |*ctx| {
        const label = ctx.label_task orelse ctx.directive;
        const header = try std.fmt.allocPrint(allocator, "--- Parallel Task: {s} (directive: {s})\n", .{ label, ctx.directive });
        defer allocator.free(header);
        try stdout_writer.writeAll(header);
        if (ctx.response) |resp| {
            defer {
                ctx.allocator.free(resp);
                ctx.response = null;
            }
            try stdout_writer.writeAll(resp);
        }
        try stdout_writer.writeAll("\n");
    }

    threads.deinit();
    contexts.deinit();
}

fn manifestTaskThread(ctx: anytype) void {
    const ptr_type = @typeInfo(@TypeOf(ctx));
    comptime {
        if (ptr_type != .Pointer) @compileError("manifestTaskThread expects pointer context");
    }

    const context = ctx;
    const helper = context.helpers;
    const run_ctx = context.run_ctx;

    var segments = [_]?[]const u8{ context.core_prompt, context.step_prompt, context.task_prompt };
    const extra = helper.buildInlinePrompt(context.allocator, &segments) catch |err| {
        context.err = err;
        return;
    };
    defer if (extra) |value| context.allocator.free(value);

    const mut_extra = if (extra) |value| value else null;

    const directive_doc = helper.loadDirectiveDocument(
        context.allocator,
        context.directive,
        context.cli_dir,
        context.env_dir,
        mut_extra,
    ) catch |err| {
        context.err = err;
        return;
    };
    defer context.allocator.free(directive_doc.prompt);
    defer switch (directive_doc.contract) {
        .custom => |value| context.allocator.free(value),
        else => {},
    };

    const assembled = helper.assemblePrompt(context.allocator, directive_doc.prompt, directive_doc.contract) catch |err| {
        context.err = err;
        return;
    };
    defer context.allocator.free(assembled);

    const label = context.label_task orelse context.directive;
    const response = helper.runCodex(context.allocator, run_ctx, label, assembled) catch |err| {
        context.err = err;
        return;
    };
    context.response = response;
}
