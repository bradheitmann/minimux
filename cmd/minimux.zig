const std = @import("std");
const Io = std.Io;
const minimux = @import("minimux");
const net = std.Io.net;

const CliError = error{
    UnknownCommand,
    MissingArgument,
    InvalidArgument,
};

const ControlRequestOptions = struct {
    command: []const u8 = "",
    pane_id: []const u8 = "",
    dimensions: ?minimux.domain.Dimensions = null,
    timeout_ms: ?u64 = null,
    path: []const u8 = "",
    policy: []const u8 = "",
    recording_id: []const u8 = "",
    tap_id: []const u8 = "",
    filter: []const u8 = "",
    argv: []const []const u8 = &.{},
    env_pairs: []const []const u8 = &.{},
    cwd: []const u8 = "",
};

const ControlTarget = struct {
    session: []const u8,
    pane_id: []const u8,

    fn deinit(target: ControlTarget, allocator: std.mem.Allocator) void {
        allocator.free(target.session);
        allocator.free(target.pane_id);
    }
};

pub fn main(init: std.process.Init) void {
    mainInner(init) catch |err| switch (err) {
        CliError.UnknownCommand, CliError.MissingArgument, CliError.InvalidArgument => std.process.exit(2),
        else => {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };
}

fn mainInner(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    const state_dir = init.environ_map.get("MINIMUX_STATE_DIR") orelse ".minimux-state";
    const current_session = init.environ_map.get("MX_SESSION") orelse "";
    const command = if (args.len > 1) args[1] else "--help";
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        try writeHelp(stdout);
        return;
    }

    if (std.mem.eql(u8, command, "__daemon")) {
        try runDaemon(io, args);
        return;
    }

    if (std.mem.eql(u8, command, "--json")) {
        const method = if (args.len > 2) args[2] else "system.health";
        if (std.mem.eql(u8, method, "system.health")) {
            try writeHealthJson(stdout);
            return;
        }
        try writeJsonError(stdout, "error.UnsupportedMethod", method);
        return CliError.UnknownCommand;
    }

    if (std.mem.eql(u8, command, "system.health")) {
        try writeHealthJson(stdout);
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
        try runSession(arena, io, stdout, args, state_dir);
        return;
    }

    if (std.mem.eql(u8, command, "create")) {
        try createSession(arena, io, stdout, args, state_dir);
        return;
    }

    if (std.mem.eql(u8, command, "kill")) {
        try killSession(arena, io, stdout, args, state_dir);
        return;
    }

    if (std.mem.eql(u8, command, "pane")) {
        try paneCommand(arena, io, stdout, args, state_dir, current_session);
        return;
    }

    if (std.mem.eql(u8, command, "send")) {
        try sendToSession(arena, io, stdout, args, state_dir);
        return;
    }

    if (std.mem.eql(u8, command, "wait-idle")) {
        try waitIdle(arena, io, stdout, args, state_dir);
        return;
    }

    if (std.mem.eql(u8, command, "agent")) {
        try agentCommand(arena, io, stdout, args, state_dir, current_session);
        return;
    }

    if (std.mem.eql(u8, command, "record")) {
        try recordCommand(arena, io, stdout, args, state_dir, current_session);
        return;
    }

    if (std.mem.eql(u8, command, "tap")) {
        try tapCommand(arena, io, stdout, args, state_dir, current_session);
        return;
    }

    if (std.mem.eql(u8, command, "transport")) {
        try transportCommand(arena, stdout, args);
        return;
    }

    if (std.mem.eql(u8, command, "snapshot")) {
        try snapshotSession(arena, io, stdout, args, state_dir);
        return;
    }

    if (std.mem.eql(u8, command, "list")) {
        try listSessions(arena, io, stdout, state_dir);
        return;
    }

    if (std.mem.eql(u8, command, "attach")) {
        try attachSession(arena, io, stdout, args, state_dir);
        return;
    }

    if (std.mem.eql(u8, command, "terminate")) {
        try terminateSession(arena, io, stdout, args, state_dir);
        return;
    }

    try stderr.print("error.UnsupportedCommand: {s} is not implemented in the scaffold - run `minimux --help`.\n", .{command});
    return CliError.UnknownCommand;
}

fn writeHelp(writer: *Io.Writer) !void {
    try writer.print(
        \\minimux {s}
        \\
        \\Usage:
        \\  minimux --help
        \\  minimux --json system.health
        \\  minimux system.health
        \\  minimux create x
        \\  minimux kill x
        \\  minimux run --name x -- bash
        \\  minimux send x "echo hi<CR>"
        \\  minimux wait-idle x --timeout-ms 5000
        \\  minimux agent wait-idle x:pane-1 --timeout-ms 5000 --json
        \\  minimux record start x:pane-1 --path /private/session.cast --on-full error_back --json
        \\  minimux record stop x rec-1 --json
        \\  minimux tap open x:pane-1 --json
        \\  minimux tap close x tap-1 --json
        \\  minimux transport self-test --json
        \\  minimux snapshot x --json
        \\  minimux list --json
        \\  minimux attach x --json
        \\  minimux terminate x --json
        \\  minimux pane create --session x --cmd bash --json
        \\  minimux pane create --session x --cwd /tmp --env KEY=value --json -- sh -c 'echo hi'
        \\  minimux pane send x:pane-1 "echo hi<CR>"
        \\  minimux pane send x:pane-1 --stdin
        \\  minimux pane resize x:pane-1 --cols 100 --rows 30 --json
        \\  minimux pane list --session x --json
        \\  minimux pane snapshot x:pane-1 --json
        \\  minimux pane close x:pane-1 --json
        \\
        \\Environment:
        \\  MINIMUX_STATE_DIR overrides the local prototype state directory.
        \\  MX_SESSION provides session context for pane commands.
        \\
    , .{minimux.version});
}

pub fn writeHealthJson(writer: *Io.Writer) !void {
    try writer.print(
        \\{{"jsonrpc":"2.0","ok":true,"result":{{"status":"{s}","product":"{s}","version":"{s}"}},"request_id":"local-cli","seq":0}}
        \\
    , .{ minimux.status, minimux.product_name, minimux.version });
}

pub fn writeJsonError(writer: *Io.Writer, code: []const u8, detail: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":false,\"error\":{\"code\":");
    try minimux.proto.writeJsonString(writer, code);
    try writer.writeAll(",\"message\":");
    try minimux.proto.writeJsonString(writer, errorMessageForCode(code));
    try writer.writeAll(",\"detail\":");
    try minimux.proto.writeJsonString(writer, detail);
    try writer.writeAll(",\"retryable\":false},\"request_id\":\"local-cli\",\"seq\":0}\n");
}

pub fn errorMessageForCode(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "error.UnsupportedMethod")) return "unsupported JSON-RPC method";
    if (std.mem.eql(u8, code, "error.UnsupportedCommand")) return "unsupported CLI command";
    if (std.mem.eql(u8, code, "error.UnsupportedAgentMethod")) return "unsupported agent method";
    if (std.mem.eql(u8, code, "error.UnsupportedRecordMethod")) return "unsupported recording method";
    if (std.mem.eql(u8, code, "error.UnsupportedTapMethod")) return "unsupported tap method";
    if (std.mem.eql(u8, code, "error.UnsupportedTransportMethod")) return "unsupported transport method";
    if (std.mem.eql(u8, code, "error.UnsupportedPaneMethod")) return "unsupported pane method";
    if (std.mem.eql(u8, code, "error.DaemonNotRunning")) return "daemon is not running for the requested session";
    if (std.mem.eql(u8, code, "error.SessionNotFound")) return "session was not found";
    if (std.mem.eql(u8, code, "error.PaneNotFound")) return "pane was not found";
    if (std.mem.eql(u8, code, "error.PaneClosed")) return "pane is closed";
    if (std.mem.eql(u8, code, "error.MissingSession")) return "session name is required";
    if (std.mem.eql(u8, code, "error.MissingInput")) return "pane input is required";
    if (std.mem.eql(u8, code, "error.EmptySessionName")) return "session name cannot be empty";
    if (std.mem.eql(u8, code, "error.InvalidSessionName")) return "session name is invalid";
    if (std.mem.eql(u8, code, "error.SessionNameTooLong")) return "session name is too long";
    if (std.mem.eql(u8, code, "error.EmptyPaneId")) return "pane id cannot be empty";
    if (std.mem.eql(u8, code, "error.InvalidPaneId")) return "pane id is invalid";
    if (std.mem.eql(u8, code, "error.PaneIdTooLong")) return "pane id is too long";
    if (std.mem.eql(u8, code, "error.InvalidPaneDimensions")) return "pane dimensions are invalid";
    return "request failed";
}

fn runDaemon(io: Io, args: []const []const u8) !void {
    const daemon_args = parseDaemonArgs(args);
    if (daemon_args.name.len == 0 or daemon_args.argv.len == 0) return CliError.MissingArgument;
    try minimux.daemon.runPrototypeLoop(std.heap.smp_allocator, io, daemon_args.state_dir, daemon_args.name, daemon_args.argv);
}

fn runSession(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
) !void {
    if (args.len < 6 or !std.mem.eql(u8, args[2], "--name")) return CliError.MissingArgument;
    const name = args[3];
    const command_start: usize = if (std.mem.eql(u8, args[4], "--")) 5 else 4;
    if (command_start >= args.len) return CliError.MissingArgument;
    const command_argv = args[command_start..];

    try minimux.domain.validateSessionName(name);
    const daemon_pid = try minimux.daemon.spawnPrototype(allocator, io, args[0], state_dir, name, command_argv);
    try minimux.session.create(allocator, io, state_dir, name, daemon_pid, command_argv);
    try minimux.session.waitForControlSocket(allocator, io, state_dir, name, 2000);

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"session\":");
    try minimux.proto.writeJsonString(writer, name);
    try writer.print(",\"daemon_pid\":{d},\"state\":\"running\",\"argv\":", .{daemon_pid});
    try minimux.proto.writeStringArray(writer, command_argv);
    try writer.writeAll(",\"recovery\":{\"state\":\"clean\",\"notifications\":[]}},\"request_id\":\"local-cli\",\"seq\":1}\n");
}

fn createSession(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
) !void {
    if (args.len < 3) return CliError.MissingArgument;
    const command_argv = [_][]const u8{"bash"};
    try minimux.domain.validateSessionName(args[2]);
    const daemon_pid = try minimux.daemon.spawnPrototype(allocator, io, args[0], state_dir, args[2], &command_argv);
    try minimux.session.create(allocator, io, state_dir, args[2], daemon_pid, &command_argv);
    try minimux.session.waitForControlSocket(allocator, io, state_dir, args[2], 2000);

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"session\":");
    try minimux.proto.writeJsonString(writer, args[2]);
    try writer.print(",\"daemon_pid\":{d},\"state\":\"running\",\"argv\":[\"bash\"]", .{daemon_pid});
    try writer.writeAll("},\"request_id\":\"local-cli\",\"seq\":1}\n");
}

fn killSession(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
) !void {
    if (args.len < 3) return CliError.MissingArgument;
    const response = sendControlRequest(allocator, io, state_dir, args[2], 7, "session.terminate", .{}) catch |err| switch (err) {
        error.DaemonNotRunning => {
            try writeJsonError(writer, "error.DaemonNotRunning", args[2]);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer allocator.free(response);
    try writer.writeAll(response);
}

fn agentCommand(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
    current_session: []const u8,
) !void {
    if (args.len < 4) return CliError.MissingArgument;
    const subcommand = args[2];
    if (!std.mem.eql(u8, subcommand, "wait-idle")) {
        try writeRpcError(writer, 30, "error.UnsupportedAgentMethod", subcommand);
        return CliError.UnknownCommand;
    }
    const target = try parseControlTarget(allocator, args[3], current_session);
    defer target.deinit(allocator);
    const timeout_ms = parseTimeoutMsFrom(args, 4) orelse 5000;
    const response = sendControlRequest(allocator, io, state_dir, target.session, 30, "agent.wait_idle", .{
        .pane_id = target.pane_id,
        .timeout_ms = timeout_ms,
    }) catch |err| switch (err) {
        error.DaemonNotRunning => {
            try writeRpcError(writer, 30, "error.DaemonNotRunning", target.session);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer allocator.free(response);
    try writer.writeAll(response);
}

fn recordCommand(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
    current_session: []const u8,
) !void {
    if (args.len < 4) return CliError.MissingArgument;
    const subcommand = args[2];
    if (std.mem.eql(u8, subcommand, "start")) {
        const target = try parseControlTarget(allocator, args[3], current_session);
        defer target.deinit(allocator);
        const path = optionValue(args, "--path") orelse optionValue(args, "--output") orelse "";
        const policy = optionValue(args, "--on-full") orelse optionValue(args, "--policy") orelse "error_back";
        const response = sendControlRequest(allocator, io, state_dir, target.session, 31, "record.start", .{
            .pane_id = target.pane_id,
            .path = path,
            .policy = policy,
        }) catch |err| switch (err) {
            error.DaemonNotRunning => {
                try writeRpcError(writer, 31, "error.DaemonNotRunning", target.session);
                return CliError.InvalidArgument;
            },
            else => |e| return e,
        };
        defer allocator.free(response);
        try writer.writeAll(response);
        return;
    }
    if (std.mem.eql(u8, subcommand, "stop")) {
        if (args.len < 5) return CliError.MissingArgument;
        const response = sendControlRequest(allocator, io, state_dir, args[3], 32, "record.stop", .{
            .recording_id = args[4],
        }) catch |err| switch (err) {
            error.DaemonNotRunning => {
                try writeRpcError(writer, 32, "error.DaemonNotRunning", args[3]);
                return CliError.InvalidArgument;
            },
            else => |e| return e,
        };
        defer allocator.free(response);
        try writer.writeAll(response);
        return;
    }
    try writeRpcError(writer, 31, "error.UnsupportedRecordMethod", subcommand);
    return CliError.UnknownCommand;
}

fn tapCommand(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
    current_session: []const u8,
) !void {
    if (args.len < 4) return CliError.MissingArgument;
    const subcommand = args[2];
    if (std.mem.eql(u8, subcommand, "open")) {
        const target = try parseControlTarget(allocator, args[3], current_session);
        defer target.deinit(allocator);
        const response = sendControlRequest(allocator, io, state_dir, target.session, 33, "tap.open", .{
            .pane_id = target.pane_id,
            .filter = optionValue(args, "--filter") orelse "",
        }) catch |err| switch (err) {
            error.DaemonNotRunning => {
                try writeRpcError(writer, 33, "error.DaemonNotRunning", target.session);
                return CliError.InvalidArgument;
            },
            else => |e| return e,
        };
        defer allocator.free(response);
        try writer.writeAll(response);
        return;
    }
    if (std.mem.eql(u8, subcommand, "close")) {
        if (args.len < 5) return CliError.MissingArgument;
        const response = sendControlRequest(allocator, io, state_dir, args[3], 34, "tap.close", .{
            .tap_id = args[4],
        }) catch |err| switch (err) {
            error.DaemonNotRunning => {
                try writeRpcError(writer, 34, "error.DaemonNotRunning", args[3]);
                return CliError.InvalidArgument;
            },
            else => |e| return e,
        };
        defer allocator.free(response);
        try writer.writeAll(response);
        return;
    }
    try writeRpcError(writer, 33, "error.UnsupportedTapMethod", subcommand);
    return CliError.UnknownCommand;
}

fn transportCommand(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 3) return CliError.MissingArgument;
    const subcommand = args[2];
    if (!std.mem.eql(u8, subcommand, "self-test")) {
        try writeRpcError(writer, 40, "error.UnsupportedTransportMethod", subcommand);
        return CliError.UnknownCommand;
    }
    const report = try minimux.transport.runSelfTest(allocator);
    if (!hasFlag(args, "--json")) {
        try writer.writeAll("transport self-test PASS\n");
        return;
    }
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"cipher\":");
    try minimux.proto.writeJsonString(writer, report.cipher);
    try writer.writeAll(",\"kdf\":");
    try minimux.proto.writeJsonString(writer, report.kdf);
    try writer.print(",\"connection_id_bits\":{d}", .{report.connection_id_bits});
    try writer.print(
        ",\"request_tunneled\":{},\"response_tunneled\":{},\"wrong_psk_failed\":{},\"replay_failed\":{},\"truncated_frame_failed\":{},\"sequence_skip_failed\":{},\"no_plaintext_fallback\":{}",
        .{
            report.request_tunneled,
            report.response_tunneled,
            report.wrong_psk_failed,
            report.replay_failed,
            report.truncated_frame_failed,
            report.sequence_skip_failed,
            report.no_plaintext_fallback,
        },
    );
    try writer.writeAll("},\"request_id\":\"local-cli\",\"seq\":40}\n");
}

fn sendToSession(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
) !void {
    if (args.len < 4) return CliError.MissingArgument;
    const name = args[2];
    const normalized = try std.mem.replaceOwned(u8, allocator, args[3], "<CR>", "\n");
    const command = std.mem.trim(u8, normalized, " \r\n\t");
    if (command.len == 0) return CliError.InvalidArgument;

    const response = sendControlRequest(allocator, io, state_dir, name, 2, "pane.send", .{ .command = command }) catch |err| switch (err) {
        error.DaemonNotRunning => {
            try writeJsonError(writer, "error.DaemonNotRunning", name);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer allocator.free(response);
    try writer.writeAll(response);
}

fn waitIdle(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
) !void {
    if (args.len < 3) return CliError.MissingArgument;
    const name = args[2];
    const timeout_ms = parseTimeoutMs(args) orelse 5000;
    const info = minimux.session.inspect(allocator, io, state_dir, name) catch |err| switch (err) {
        error.FileNotFound => {
            const observation = minimux.harness_shell.unknown(
                timeout_ms,
                "session metadata was not found",
                "create the session before waiting for idle",
            );
            try minimux.harness_shell.writeObservationJson(writer, name, observation, "local-cli", 3);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer info.deinit(allocator);

    if (!info.daemon_alive) {
        const observation = if (std.mem.eql(u8, info.lifecycle_state, "terminated"))
            minimux.harness_shell.exited(
                timeout_ms,
                "session lifecycle state is terminated",
                "start a new session before sending input",
            )
        else
            minimux.harness_shell.unknown(
                timeout_ms,
                "daemon control socket is unavailable",
                "run snapshot to inspect recovery state before sending input",
            );
        try minimux.harness_shell.writeObservationJson(writer, name, observation, "local-cli", 3);
        if (!observation.ok()) return CliError.InvalidArgument;
        return;
    }

    const response = try sendControlRequest(allocator, io, state_dir, name, 3, "agent.wait_idle", .{
        .timeout_ms = timeout_ms,
    });
    defer allocator.free(response);
    try writer.writeAll(response);
}

fn snapshotSession(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
) !void {
    if (args.len < 3) return CliError.MissingArgument;
    const name = args[2];
    const snap = try minimux.session.snapshot(allocator, io, state_dir, name);
    defer minimux.session.destroySnapshot(allocator, snap);

    const pty = minimux.pty.defaultPrototypePty();
    const recovery_state = minimux.domain.recoveryLabel(snap.recovery_state);
    const child_status = if (snap.daemon_alive) "running" else "dead";

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"session\":");
    try minimux.proto.writeJsonString(writer, name);
    try writer.print(
        ",\"dimensions\":{{\"cols\":{d},\"rows\":{d}}},\"cursor\":{{\"x\":0,\"y\":0}},\"visible_text\":",
        .{ pty.dimensions.cols, pty.dimensions.rows },
    );
    try minimux.proto.writeJsonString(writer, snap.visible_text);
    try writer.writeAll(",\"scrollback_excerpt\":");
    try minimux.proto.writeJsonString(writer, snap.visible_text);
    try writer.print(
        ",\"process\":{{\"daemon_pid\":{d},\"daemon_alive\":{},\"child_status\":\"{s}\"}},\"recovery\":{{\"state\":\"{s}\",\"notifications\":",
        .{ snap.daemon_pid, snap.daemon_alive, child_status, recovery_state },
    );
    if (snap.recovery_state == .recovered) {
        try writer.writeAll("[\"SESSION_RECOVERED\"]");
    } else {
        try writer.writeAll("[]");
    }
    try writer.print("}},\"command_count\":{d}", .{snap.command_count});
    try writer.writeAll("},\"request_id\":\"local-cli\",\"seq\":4}\n");
}

fn listSessions(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    state_dir: []const u8,
) !void {
    const sessions = try minimux.session.listSessions(allocator, io, state_dir);
    defer sessions.deinit(allocator);

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"sessions\":[");
    for (sessions.items, 0..) |info, index| {
        var unavailable_info: ?minimux.session.SessionInfo = null;
        defer if (unavailable_info) |value| value.deinit(allocator);

        if (info.daemon_alive) {
            const response = sendControlRequest(allocator, io, state_dir, info.name, 5, "session.attach", .{}) catch |err| switch (err) {
                error.DaemonNotRunning => blk: {
                    unavailable_info = try minimux.session.markUnavailable(allocator, io, state_dir, info.name);
                    break :blk null;
                },
                else => |e| return e,
            };
            if (response) |socket_response| allocator.free(socket_response);
        }
        if (index != 0) try writer.writeAll(",");
        const output_info = unavailable_info orelse info;
        try minimux.session.writeSessionInfoJson(writer, output_info);
    }
    try writer.writeAll("]},\"request_id\":\"local-cli\",\"seq\":5}\n");
}

fn attachSession(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
) !void {
    if (args.len < 3) return CliError.MissingArgument;
    _ = minimux.session.inspect(allocator, io, state_dir, args[2]) catch |err| switch (err) {
        error.FileNotFound => {
            try writeJsonError(writer, "error.SessionNotFound", args[2]);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    const response = sendControlRequest(allocator, io, state_dir, args[2], 6, "session.attach", .{}) catch |err| switch (err) {
        error.DaemonNotRunning => {
            try writeJsonError(writer, "error.DaemonNotRunning", args[2]);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer allocator.free(response);
    try writer.writeAll(response);
}

fn terminateSession(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
) !void {
    if (args.len < 3) return CliError.MissingArgument;
    _ = minimux.session.inspect(allocator, io, state_dir, args[2]) catch |err| switch (err) {
        error.FileNotFound => {
            try writeJsonError(writer, "error.SessionNotFound", args[2]);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    const response = sendControlRequest(allocator, io, state_dir, args[2], 7, "session.terminate", .{}) catch |err| switch (err) {
        error.DaemonNotRunning => {
            try writeJsonError(writer, "error.DaemonNotRunning", args[2]);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer allocator.free(response);
    try writer.writeAll(response);
}

fn writeSessionInfoJson(writer: *Io.Writer, info: minimux.session.SessionInfo) !void {
    try minimux.session.writeSessionInfoJson(writer, info);
}

fn paneCommand(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
    current_session: []const u8,
) !void {
    if (args.len < 3) return CliError.MissingArgument;
    const subcommand = args[2];
    if (std.mem.eql(u8, subcommand, "create")) return paneCreate(allocator, io, writer, args, state_dir, current_session);
    if (std.mem.eql(u8, subcommand, "send")) return paneSend(allocator, io, writer, args, state_dir, current_session);
    if (std.mem.eql(u8, subcommand, "resize")) return paneResize(allocator, io, writer, args, state_dir, current_session);
    if (std.mem.eql(u8, subcommand, "list")) return paneList(allocator, io, writer, args, state_dir, current_session);
    if (std.mem.eql(u8, subcommand, "close")) return paneClose(allocator, io, writer, args, state_dir, current_session);
    if (std.mem.eql(u8, subcommand, "snapshot")) return paneSnapshot(allocator, io, writer, args, state_dir, current_session);
    try writeRpcError(writer, 20, "error.UnsupportedPaneMethod", subcommand);
    return CliError.UnknownCommand;
}

fn paneCreate(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
    current_session: []const u8,
) !void {
    const flag_args = argsBeforeSeparator(args);
    const session_name = optionValue(flag_args, "--session") orelse current_session;
    if (session_name.len == 0) {
        try writeRpcError(writer, 21, "error.MissingSession", "pane.create");
        return CliError.InvalidArgument;
    }
    minimux.domain.validateSessionName(session_name) catch |err| {
        try writeRpcError(writer, 21, errorCode(err), session_name);
        return CliError.InvalidArgument;
    };
    const pane_argv = argvAfterSeparator(args);
    const command = if (pane_argv.len > 0) "" else optionValue(flag_args, "--cmd") orelse "bash";
    const env_pairs = try collectOptionValues(allocator, flag_args, "--env");
    defer allocator.free(env_pairs);
    const cwd = optionValue(flag_args, "--cwd") orelse "";
    const dimensions = parseDimensions(flag_args) catch |err| {
        try writeRpcError(writer, 21, errorCode(err), "pane.create");
        return CliError.InvalidArgument;
    };
    const response = sendControlRequest(allocator, io, state_dir, session_name, 21, "pane.create", .{
        .command = command,
        .dimensions = dimensions,
        .argv = pane_argv,
        .env_pairs = env_pairs,
        .cwd = cwd,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try writeRpcError(writer, 21, "error.SessionNotFound", session_name);
            return CliError.InvalidArgument;
        },
        error.DaemonNotRunning => {
            try writeRpcError(writer, 21, "error.DaemonNotRunning", session_name);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer allocator.free(response);
    try writer.writeAll(response);
}

fn paneSend(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
    current_session: []const u8,
) !void {
    if (args.len < 4) return CliError.MissingArgument;
    const ref = minimux.pty.parsePaneRef(allocator, args[3], current_session) catch |err| {
        try writeRpcError(writer, 22, errorCode(err), args[3]);
        return CliError.InvalidArgument;
    };
    defer ref.deinit(allocator);

    var input_owned: ?[]u8 = null;
    defer if (input_owned) |input| allocator.free(input);
    const raw_input = if (hasFlag(args, "--stdin")) blk: {
        input_owned = try readStdin(allocator, io);
        break :blk input_owned.?;
    } else if (args.len >= 5) args[4] else "";
    if (raw_input.len == 0) {
        try writeRpcError(writer, 22, "error.MissingInput", args[3]);
        return CliError.InvalidArgument;
    }
    const decoded = try minimux.pty.decodeControlTokens(allocator, raw_input);
    defer allocator.free(decoded);

    var pane = minimux.session.inspectPane(allocator, io, state_dir, ref.session, ref.local_id) catch |err| switch (err) {
        error.FileNotFound => {
            try writeRpcError(writer, 22, "error.PaneNotFound", args[3]);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer pane.deinit(allocator);
    if (!std.mem.eql(u8, pane.state, minimux.pty.PaneState.open.label())) {
        try writeRpcError(writer, 22, "error.PaneClosed", args[3]);
        return CliError.InvalidArgument;
    }

    const response = sendControlRequest(allocator, io, state_dir, ref.session, 22, "pane.send", .{
        .command = decoded,
        .pane_id = ref.local_id,
    }) catch |err| switch (err) {
        error.DaemonNotRunning => {
            try writeRpcError(writer, 22, "error.DaemonNotRunning", ref.session);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer allocator.free(response);
    try writer.writeAll(response);
}

fn paneResize(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
    current_session: []const u8,
) !void {
    if (args.len < 4) return CliError.MissingArgument;
    const ref = minimux.pty.parsePaneRef(allocator, args[3], current_session) catch |err| {
        try writeRpcError(writer, 23, errorCode(err), args[3]);
        return CliError.InvalidArgument;
    };
    defer ref.deinit(allocator);
    const dimensions = parseDimensions(args) catch |err| {
        try writeRpcError(writer, 23, errorCode(err), args[3]);
        return CliError.InvalidArgument;
    };
    const response = sendControlRequest(allocator, io, state_dir, ref.session, 23, "pane.resize", .{
        .pane_id = ref.local_id,
        .dimensions = dimensions,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try writeRpcError(writer, 23, "error.SessionNotFound", ref.session);
            return CliError.InvalidArgument;
        },
        error.DaemonNotRunning => {
            try writeRpcError(writer, 23, "error.DaemonNotRunning", ref.session);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer allocator.free(response);
    try writer.writeAll(response);
}

fn paneList(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
    current_session: []const u8,
) !void {
    const session_name = optionValue(args, "--session") orelse current_session;
    if (session_name.len == 0) {
        try writeRpcError(writer, 24, "error.MissingSession", "pane.list");
        return CliError.InvalidArgument;
    }
    minimux.domain.validateSessionName(session_name) catch |err| {
        try writeRpcError(writer, 24, errorCode(err), session_name);
        return CliError.InvalidArgument;
    };
    const info = minimux.session.inspect(allocator, io, state_dir, session_name) catch |err| switch (err) {
        error.FileNotFound => {
            try writeRpcError(writer, 24, "error.SessionNotFound", session_name);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer info.deinit(allocator);
    const panes = try minimux.session.listPanes(allocator, io, state_dir, session_name);
    defer panes.deinit(allocator);
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"panes\":[");
    for (panes.items, 0..) |pane, index| {
        if (index != 0) try writer.writeAll(",");
        try minimux.session.writePaneInfoJson(writer, pane);
    }
    try writer.writeAll("]},\"request_id\":\"local-cli\",\"seq\":24}\n");
}

fn paneClose(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
    current_session: []const u8,
) !void {
    if (args.len < 4) return CliError.MissingArgument;
    const ref = minimux.pty.parsePaneRef(allocator, args[3], current_session) catch |err| {
        try writeRpcError(writer, 25, errorCode(err), args[3]);
        return CliError.InvalidArgument;
    };
    defer ref.deinit(allocator);
    const response = sendControlRequest(allocator, io, state_dir, ref.session, 25, "pane.close", .{
        .pane_id = ref.local_id,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try writeRpcError(writer, 25, "error.SessionNotFound", ref.session);
            return CliError.InvalidArgument;
        },
        error.DaemonNotRunning => {
            try writeRpcError(writer, 25, "error.DaemonNotRunning", ref.session);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer allocator.free(response);
    try writer.writeAll(response);
}

fn paneSnapshot(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
    state_dir: []const u8,
    current_session: []const u8,
) !void {
    if (args.len < 4) return CliError.MissingArgument;
    const ref = minimux.pty.parsePaneRef(allocator, args[3], current_session) catch |err| {
        try writeRpcError(writer, 26, errorCode(err), args[3]);
        return CliError.InvalidArgument;
    };
    defer ref.deinit(allocator);
    const pane = minimux.session.inspectPane(allocator, io, state_dir, ref.session, ref.local_id) catch |err| switch (err) {
        error.FileNotFound => {
            try writeRpcError(writer, 26, "error.PaneNotFound", args[3]);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer pane.deinit(allocator);
    const response = sendControlRequest(allocator, io, state_dir, ref.session, 26, "pane.snapshot", .{
        .pane_id = ref.local_id,
    }) catch |err| switch (err) {
        error.DaemonNotRunning => {
            try writeRpcError(writer, 26, "error.DaemonNotRunning", ref.session);
            return CliError.InvalidArgument;
        },
        else => |e| return e,
    };
    defer allocator.free(response);
    try writer.writeAll(response);
}

fn sendControlRequest(
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    seq: u64,
    method: []const u8,
    options: ControlRequestOptions,
) ![]u8 {
    const info = try minimux.session.inspect(allocator, io, state_dir, name);
    defer info.deinit(allocator);
    if (!info.daemon_alive) return error.DaemonNotRunning;

    var address = try net.UnixAddress.init(info.control_socket);
    var stream = address.connect(io) catch return error.DaemonNotRunning;
    defer stream.close(io);

    var request_writer_alloc: Io.Writer.Allocating = .init(allocator);
    defer request_writer_alloc.deinit();
    const request_writer = &request_writer_alloc.writer;
    try request_writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try request_writer.print("{d}", .{seq});
    try request_writer.writeAll(",\"method\":");
    try minimux.proto.writeJsonString(request_writer, method);
    try request_writer.writeAll(",\"params\":{\"session\":");
    try minimux.proto.writeJsonString(request_writer, name);
    if (options.command.len > 0) {
        try request_writer.writeAll(",\"command\":");
        try minimux.proto.writeJsonString(request_writer, options.command);
    }
    if (options.pane_id.len > 0) {
        try request_writer.writeAll(",\"pane_id\":");
        try minimux.proto.writeJsonString(request_writer, options.pane_id);
    }
    if (options.dimensions) |dims| {
        try request_writer.print(",\"cols\":{d},\"rows\":{d}", .{ dims.cols, dims.rows });
    }
    if (options.timeout_ms) |timeout_ms| try request_writer.print(",\"timeout_ms\":{d}", .{timeout_ms});
    if (options.path.len > 0) {
        try request_writer.writeAll(",\"path\":");
        try minimux.proto.writeJsonString(request_writer, options.path);
    }
    if (options.policy.len > 0) {
        try request_writer.writeAll(",\"policy\":");
        try minimux.proto.writeJsonString(request_writer, options.policy);
    }
    if (options.recording_id.len > 0) {
        try request_writer.writeAll(",\"recording_id\":");
        try minimux.proto.writeJsonString(request_writer, options.recording_id);
    }
    if (options.tap_id.len > 0) {
        try request_writer.writeAll(",\"tap_id\":");
        try minimux.proto.writeJsonString(request_writer, options.tap_id);
    }
    if (options.filter.len > 0) {
        try request_writer.writeAll(",\"filter\":");
        try minimux.proto.writeJsonString(request_writer, options.filter);
    }
    if (options.argv.len > 0) {
        try request_writer.writeAll(",\"argv\":");
        try minimux.proto.writeStringArray(request_writer, options.argv);
    }
    if (options.cwd.len > 0) {
        try request_writer.writeAll(",\"cwd\":");
        try minimux.proto.writeJsonString(request_writer, options.cwd);
    }
    if (options.env_pairs.len > 0) {
        try request_writer.writeAll(",\"env\":{");
        var first_pair = true;
        for (options.env_pairs) |pair| {
            const separator = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (separator == 0) continue;
            if (!first_pair) try request_writer.writeAll(",");
            first_pair = false;
            try minimux.proto.writeJsonString(request_writer, pair[0..separator]);
            try request_writer.writeAll(":");
            try minimux.proto.writeJsonString(request_writer, pair[separator + 1 ..]);
        }
        try request_writer.writeAll("}");
    }
    try request_writer.writeAll("}}\n");

    var stream_write_buffer: [8192]u8 = undefined;
    var stream_writer = stream.writer(io, &stream_write_buffer);
    try stream_writer.interface.writeAll(request_writer_alloc.written());
    try stream_writer.interface.flush();

    var stream_read_buffer: [65536]u8 = undefined;
    var stream_reader = stream.reader(io, &stream_read_buffer);
    const response = (try stream_reader.interface.takeDelimiter('\n')) orelse return error.DaemonNotRunning;
    return allocator.dupe(u8, response);
}

pub fn writeRpcError(writer: *Io.Writer, seq: u64, code: []const u8, detail: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":false,\"error\":{\"code\":");
    try minimux.proto.writeJsonString(writer, code);
    try writer.writeAll(",\"message\":");
    try minimux.proto.writeJsonString(writer, errorMessageForCode(code));
    try writer.writeAll(",\"detail\":");
    try minimux.proto.writeJsonString(writer, detail);
    try writer.print(",\"retryable\":false}},\"request_id\":\"local-cli\",\"seq\":{d}}}\n", .{seq});
}

fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptySessionName => "error.MissingSession",
        error.InvalidSessionName => "error.InvalidSessionName",
        error.SessionNameTooLong => "error.SessionNameTooLong",
        error.EmptyPaneId => "error.EmptyPaneId",
        error.InvalidPaneId => "error.InvalidPaneId",
        error.PaneIdTooLong => "error.PaneIdTooLong",
        error.InvalidPaneDimensions, error.InvalidCharacter, error.Overflow => "error.InvalidPaneDimensions",
        else => @errorName(err),
    };
}

fn optionValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index + 1 < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], name)) return args[index + 1];
    }
    return null;
}

fn collectOptionValues(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    name: []const u8,
) ![]const []const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    errdefer values.deinit(allocator);
    var index: usize = 0;
    while (index + 1 < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--")) break;
        if (std.mem.eql(u8, args[index], name)) try values.append(allocator, args[index + 1]);
    }
    return values.toOwnedSlice(allocator);
}

fn argvAfterSeparator(args: []const []const u8) []const []const u8 {
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--")) return args[index + 1 ..];
    }
    return &.{};
}

fn argsBeforeSeparator(args: []const []const u8) []const []const u8 {
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--")) return args[0..index];
    }
    return args;
}

fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn parseDimensions(args: []const []const u8) !minimux.domain.Dimensions {
    const cols_text = optionValue(args, "--cols") orelse "80";
    const rows_text = optionValue(args, "--rows") orelse "24";
    const cols = try std.fmt.parseInt(u16, cols_text, 10);
    const rows = try std.fmt.parseInt(u16, rows_text, 10);
    if (cols == 0 or rows == 0) return error.InvalidPaneDimensions;
    return .{ .cols = cols, .rows = rows };
}

fn readStdin(allocator: std.mem.Allocator, io: Io) ![]u8 {
    var reader_buffer: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().readerStreaming(io, &reader_buffer);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const count = try stdin_reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        try output.appendSlice(allocator, chunk[0..count]);
        if (output.items.len > 1024 * 1024) return error.InputTooLarge;
    }
    return output.toOwnedSlice(allocator);
}

fn parseTimeoutMs(args: []const []const u8) ?u64 {
    return parseTimeoutMsFrom(args, 3);
}

fn parseTimeoutMsFrom(args: []const []const u8, start_index: usize) ?u64 {
    var index: usize = start_index;
    while (index + 1 < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--timeout-ms")) {
            return std.fmt.parseInt(u64, args[index + 1], 10) catch null;
        }
    }
    return null;
}

fn parseControlTarget(
    allocator: std.mem.Allocator,
    target: []const u8,
    current_session: []const u8,
) !ControlTarget {
    if (std.mem.indexOfScalar(u8, target, ':') != null or
        (current_session.len > 0 and std.mem.startsWith(u8, target, "pane-")))
    {
        const ref = try minimux.pty.parsePaneRef(allocator, target, current_session);
        return .{
            .session = ref.session,
            .pane_id = ref.local_id,
        };
    }
    try minimux.domain.validateSessionName(target);
    return .{
        .session = try allocator.dupe(u8, target),
        .pane_id = try allocator.dupe(u8, ""),
    };
}

fn parseDaemonArgs(args: []const []const u8) struct { state_dir: []const u8, name: []const u8, argv: []const []const u8 } {
    var state_dir: []const u8 = ".minimux-state";
    var name: []const u8 = "";
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--")) {
            return .{ .state_dir = state_dir, .name = name, .argv = args[index + 1 ..] };
        }
        if (index + 1 >= args.len) break;
        if (std.mem.eql(u8, args[index], "--state-dir")) state_dir = args[index + 1];
        if (std.mem.eql(u8, args[index], "--name")) name = args[index + 1];
    }
    return .{ .state_dir = state_dir, .name = name, .argv = &.{} };
}

test "scaffold exposes system health" {
    try std.testing.expect(minimux.hasPublicMethod("system.health"));
}

test "control socket transport rejects missing listener" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-control-missing-test";
    Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    const argv = [_][]const u8{"bash"};
    try minimux.session.create(allocator, io, state_dir, "socket-missing", @intCast(std.posix.system.getpid()), &argv);
    try std.testing.expectError(
        error.DaemonNotRunning,
        sendControlRequest(allocator, io, state_dir, "socket-missing", 1, "session.attach", .{}),
    );
}

test "list marks socket-missing live session unavailable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-list-socket-missing-test";
    Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    const argv = [_][]const u8{"bash"};
    try minimux.session.create(allocator, io, state_dir, "socket-missing-list", @intCast(std.posix.system.getpid()), &argv);

    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try listSessions(allocator, io, &output.writer, state_dir);

    const text = output.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"socket-missing-list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"daemon_alive\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"state\":\"unavailable\"") != null);
}
