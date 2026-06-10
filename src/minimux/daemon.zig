const std = @import("std");
const domain = @import("domain.zig");
const proto = @import("proto.zig");
const pty = @import("pty.zig");
const session = @import("session.zig");
const shadow = @import("shadow.zig");
const snapshot = @import("snapshot.zig");
const harness_shell = @import("harness_shell.zig");
const observe = @import("observe.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const net = std.Io.net;

const wait_idle_step_ms: u64 = 25;
const wait_idle_quiet_window_ms: u64 = 150;
const wait_idle_max_drained_commands: usize = 32;
const wait_idle_drain_limit_bytes: usize = 256 * 1024;
const max_control_request_bytes: usize = 4 * 1024 * 1024;

const ControlParams = struct {
    session: []const u8 = "",
    command: []const u8 = "",
    pane_id: []const u8 = "",
    path: []const u8 = "",
    policy: []const u8 = "",
    recording_id: []const u8 = "",
    tap_id: []const u8 = "",
    filter: []const u8 = "",
    cols: u16 = 0,
    rows: u16 = 0,
    timeout_ms: u64 = 0,
};

const ControlRequest = struct {
    method: []const u8,
    id: u64 = 0,
    jsonrpc: []const u8 = "2.0",
    params: ControlParams = .{},
};

const ShellCommandResult = struct {
    stdout: []const u8,
    exit_code: u8,

    fn deinit(result: ShellCommandResult, allocator: Allocator) void {
        allocator.free(result.stdout);
    }
};

const RuntimeProcessState = enum {
    running,
    exited,
    signaled,
    unknown,

    fn label(state: RuntimeProcessState) []const u8 {
        return switch (state) {
            .running => "running",
            .exited => "exited",
            .signaled => "signaled",
            .unknown => "unknown",
        };
    }
};

const RuntimePane = struct {
    local_id: []u8,
    pty: pty.OpenedPty,
    child: std.process.Child,
    shadow: shadow.Engine,
    process_state: RuntimeProcessState = .running,
    last_exit_code: ?u8 = null,

    fn deinit(runtime: *RuntimePane, allocator: Allocator, io: Io) void {
        forceKillChild(&runtime.child, io);
        runtime.pty.close(io);
        runtime.shadow.deinit(allocator);
        allocator.free(runtime.local_id);
    }
};

pub fn spawnPrototype(
    allocator: Allocator,
    io: Io,
    exe_path: []const u8,
    state_dir: []const u8,
    name: []const u8,
    argv: []const []const u8,
) !i64 {
    var daemon_args: std.ArrayList([]const u8) = .empty;
    defer daemon_args.deinit(allocator);

    try daemon_args.append(allocator, exe_path);
    try daemon_args.append(allocator, "__daemon");
    try daemon_args.append(allocator, "--state-dir");
    try daemon_args.append(allocator, state_dir);
    try daemon_args.append(allocator, "--name");
    try daemon_args.append(allocator, name);
    try daemon_args.append(allocator, "--");
    for (argv) |arg| try daemon_args.append(allocator, arg);

    const child = try std.process.spawn(io, .{
        .argv = daemon_args.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return @intCast(child.id.?);
}

pub fn runPrototypeLoop(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    argv: []const []const u8,
) !void {
    const control_socket = try session.controlSocketPath(allocator, state_dir, name);
    defer allocator.free(control_socket);
    Io.Dir.cwd().deleteFile(io, control_socket) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    var control_address = try net.UnixAddress.init(control_socket);
    var control_server = try control_address.listen(io, .{});
    defer control_server.deinit(io);
    defer Io.Dir.cwd().deleteFile(io, control_socket) catch {};
    try session.markControlSocketReady(allocator, io, state_dir, name);

    var session_pty = try pty.open(.{});
    defer session_pty.close(io);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .{ .file = session_pty.slave },
        .stdout = .{ .file = session_pty.slave },
        .stderr = .{ .file = session_pty.slave },
    });
    session_pty.closeSlave(io);
    defer forceKillChild(&child, io);
    var shell_process_state: RuntimeProcessState = .running;
    var shell_exit_code: ?u8 = null;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_reader = session_pty.master.readerStreaming(io, &stdout_buffer);
    const stdout = &stdout_reader.interface;

    try session_pty.master.writeStreamingAll(io, "exec 2>&1\n");

    var runtime_panes: std.ArrayList(RuntimePane) = .empty;
    defer {
        for (runtime_panes.items) |*pane_runtime| pane_runtime.deinit(allocator, io);
        runtime_panes.deinit(allocator);
    }
    var active_recordings: std.ArrayList(observe.ActiveRecording) = .empty;
    defer {
        for (active_recordings.items) |recording| recording.deinit(allocator);
        active_recordings.deinit(allocator);
    }
    var active_taps: std.ArrayList(observe.ActiveTap) = .empty;
    defer {
        for (active_taps.items) |tap| tap.deinit(allocator);
        active_taps.deinit(allocator);
    }
    var next_recording_index: usize = 1;
    var next_tap_index: usize = 1;

    while (true) {
        refreshChildExitStatus(&child, &shell_process_state, &shell_exit_code);
        // A failed request must never kill the daemon: a client that
        // disconnects mid-response (broken pipe), sends malformed JSON, or
        // overflows the request cap costs that client its response, not the
        // session its panes. The failure is logged and the loop continues.
        const control_outcome = acceptControlRequest(
            allocator,
            io,
            &control_server,
            session_pty.master,
            stdout,
            state_dir,
            name,
            &runtime_panes,
            &child,
            &shell_process_state,
            &shell_exit_code,
            &active_recordings,
            &active_taps,
            &next_recording_index,
            &next_tap_index,
        ) catch |err| blk: {
            logDaemonError(allocator, io, state_dir, name, "control request", err);
            break :blk null;
        };
        if (control_outcome) |terminate| {
            if (terminate) break;
        }
        const terminate_requested = session.takeTerminateRequest(allocator, io, state_dir, name) catch |err| blk: {
            logDaemonError(allocator, io, state_dir, name, "terminate request check", err);
            break :blk false;
        };
        if (terminate_requested) break;
        const pending = session.takePendingCommand(allocator, io, state_dir, name) catch |err| blk: {
            logDaemonError(allocator, io, state_dir, name, "pending command pickup", err);
            break :blk null;
        };
        if (pending) |queued| {
            defer queued.deinit(allocator);
            executeQueuedCommand(allocator, io, session_pty.master, stdout, state_dir, name, queued) catch |err| {
                logDaemonError(allocator, io, state_dir, name, "queued command execution", err);
            };
        }
        pumpAllRuntimePanes(allocator, io, state_dir, name, &runtime_panes, &active_recordings);
        Io.sleep(io, .fromMilliseconds(250), .awake) catch {};
    }
}

fn logDaemonError(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    context: []const u8,
    err: anyerror,
) void {
    const line = std.fmt.allocPrint(allocator, "{s} failed: {s}\n", .{ context, @errorName(err) }) catch return;
    defer allocator.free(line);
    session.appendDaemonLog(allocator, io, state_dir, name, line) catch {};
}

/// Drains background output from every runtime pane once per control tick so
/// snapshots, taps, and recordings stay current without a pane.send. Pump
/// errors must not kill the daemon: a full-disk recording shortfall surfaces
/// to the next requester that touches the recording, while the shadow VT
/// state has already absorbed the drained bytes.
fn pumpAllRuntimePanes(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    runtime_panes: *std.ArrayList(RuntimePane),
    active_recordings: *std.ArrayList(observe.ActiveRecording),
) void {
    for (runtime_panes.items) |*runtime| {
        refreshRuntimePaneExitStatus(runtime);
        _ = pumpRuntimePaneOutput(allocator, io, state_dir, name, runtime, active_recordings) catch {};
    }
}

fn acceptControlRequest(
    allocator: Allocator,
    io: Io,
    server: *net.Server,
    session_master: Io.File,
    stdout: *Io.Reader,
    state_dir: []const u8,
    name: []const u8,
    runtime_panes: *std.ArrayList(RuntimePane),
    shell_child: *std.process.Child,
    shell_process_state: *RuntimeProcessState,
    shell_exit_code: *?u8,
    active_recordings: *std.ArrayList(observe.ActiveRecording),
    active_taps: *std.ArrayList(observe.ActiveTap),
    next_recording_index: *usize,
    next_tap_index: *usize,
) !?bool {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = server.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&poll_fds, 0);
    if (ready == 0) return null;

    var stream = try server.accept(io);
    defer stream.close(io);

    var request_buffer: [8192]u8 = undefined;
    var stream_reader = stream.reader(io, &request_buffer);
    const request_text = (try proto.readJsonLine(
        allocator,
        &stream_reader.interface,
        max_control_request_bytes,
    )) orelse return null;
    defer allocator.free(request_text);
    var parsed = try std.json.parseFromSlice(ControlRequest, allocator, request_text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const request = parsed.value;

    var response_buffer: [8192]u8 = undefined;
    var stream_writer = stream.writer(io, &response_buffer);
    const writer = &stream_writer.interface;

    if (!std.mem.eql(u8, request.params.session, name)) {
        try writeControlError(writer, request.id, "error.SessionMismatch", request.params.session);
        try writer.flush();
        return false;
    }

    if (std.mem.eql(u8, request.method, "session.attach")) {
        const info = try session.inspect(allocator, io, state_dir, name);
        defer info.deinit(allocator);
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"session\":");
        try session.writeSessionInfoJson(writer, info);
        try writer.print("}},\"request_id\":\"control-socket\",\"seq\":{d}}}\n", .{request.id});
        try writer.flush();
        return false;
    }

    if (std.mem.eql(u8, request.method, "session.terminate")) {
        const info = try session.markTerminated(allocator, io, state_dir, name);
        defer info.deinit(allocator);
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"session\":");
        try session.writeSessionInfoJson(writer, info);
        try writer.print("}},\"request_id\":\"control-socket\",\"seq\":{d}}}\n", .{request.id});
        try writer.flush();
        return true;
    }

    if (std.mem.eql(u8, request.method, "agent.wait_idle")) {
        const observation = if (request.params.pane_id.len > 0) blk: {
            const pane_index = findRuntimePaneIndex(runtime_panes, request.params.pane_id) orelse {
                break :blk harness_shell.unknown(
                    request.params.timeout_ms,
                    "pane is not active in the daemon runtime",
                    "list panes or create the pane before waiting for idle",
                );
            };
            break :blk try waitForPaneIdle(
                allocator,
                io,
                state_dir,
                name,
                &runtime_panes.items[pane_index],
                active_recordings,
                request.params.timeout_ms,
            );
        } else try waitForShellIdle(
            allocator,
            io,
            session_master,
            stdout,
            state_dir,
            name,
            shell_child,
            shell_process_state,
            shell_exit_code,
            request.params.timeout_ms,
        );
        try harness_shell.writeObservationJson(writer, name, observation, "control-socket", request.id);
        try writer.flush();
        return false;
    }

    if (std.mem.eql(u8, request.method, "record.start")) {
        const policy = observe.DiskFullPolicy.parse(request.params.policy);
        var result = observe.startRecording(
            allocator,
            io,
            state_dir,
            name,
            request.params.pane_id,
            request.params.path,
            next_recording_index.*,
            policy,
        ) catch |err| switch (err) {
            error.NoSpaceLeft => {
                try observe.writeObserveError(writer, request.id, "error.RecordingDiskFull", "recording disk-full policy is stop_recording; no bytes were appended");
                try writer.flush();
                return false;
            },
            else => |e| return e,
        };
        var transferred = false;
        errdefer if (!transferred) result.deinit(allocator);
        next_recording_index.* += 1;
        try observe.writeRecordingStartJson(writer, name, result, "control-socket", request.id);
        try active_recordings.append(allocator, result.recording);
        transferred = true;
        allocator.free(result.dir_path);
        try writer.flush();
        return false;
    }

    if (std.mem.eql(u8, request.method, "record.stop")) {
        if (request.params.recording_id.len == 0) {
            try observe.writeObserveError(writer, request.id, "error.MissingRecording", "record.stop requires recording_id");
            try writer.flush();
            return false;
        }
        const stopped = observe.stopRecording(active_recordings, allocator, request.params.recording_id) orelse {
            try observe.writeObserveError(writer, request.id, "error.RecordingNotFound", request.params.recording_id);
            try writer.flush();
            return false;
        };
        defer stopped.deinit(allocator);
        try observe.writeRecordingStopJson(writer, name, stopped, "control-socket", request.id);
        try writer.flush();
        return false;
    }

    if (std.mem.eql(u8, request.method, "tap.open")) {
        var tap = try observe.openTap(allocator, io, state_dir, name, request.params.pane_id, next_tap_index.*);
        var transferred = false;
        errdefer if (!transferred) tap.deinit(allocator);
        next_tap_index.* += 1;
        try observe.writeTapOpenJson(allocator, io, writer, state_dir, name, tap.id, tap.pane_id, "control-socket", request.id);
        try active_taps.append(allocator, tap);
        transferred = true;
        try writer.flush();
        return false;
    }

    if (std.mem.eql(u8, request.method, "tap.close")) {
        if (request.params.tap_id.len == 0) {
            try observe.writeObserveError(writer, request.id, "error.MissingTap", "tap.close requires tap_id");
            try writer.flush();
            return false;
        }
        const tap = observe.closeTap(active_taps, request.params.tap_id) orelse {
            try observe.writeObserveError(writer, request.id, "error.TapNotFound", request.params.tap_id);
            try writer.flush();
            return false;
        };
        defer tap.deinit(allocator);
        try observe.writeTapCloseJson(allocator, io, writer, state_dir, name, tap, "control-socket", request.id);
        try writer.flush();
        return false;
    }

    if (std.mem.eql(u8, request.method, "pane.create")) {
        var extra_parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_text, .{});
        defer extra_parsed.deinit();
        const extra = try parsePaneCreateExtra(allocator, extra_parsed.value);
        defer extra.deinit(allocator);

        const command = std.mem.trim(u8, request.params.command, " \r\n\t");
        if (command.len == 0 and extra.argv.len == 0) {
            try writeControlError(writer, request.id, "error.InvalidPaneCommand", "pane.create");
            try writer.flush();
            return false;
        }
        const dimensions = extra.size orelse controlDimensions(request.params);
        const display_command = if (command.len > 0)
            try allocator.dupe(u8, command)
        else
            try std.mem.join(allocator, " ", extra.argv);
        defer allocator.free(display_command);

        const pane_info = session.createPane(allocator, io, state_dir, name, display_command, dimensions) catch |err| switch (err) {
            error.FileNotFound => {
                try writeControlError(writer, request.id, "error.SessionNotFound", name);
                try writer.flush();
                return false;
            },
            error.DaemonNotRunning => {
                try writeControlError(writer, request.id, "error.DaemonNotRunning", name);
                try writer.flush();
                return false;
            },
            error.InvalidPaneDimensions => {
                try writeControlError(writer, request.id, "error.InvalidPaneDimensions", "pane.create");
                try writer.flush();
                return false;
            },
            else => |e| return e,
        };
        defer pane_info.deinit(allocator);

        var pane_pty = try pty.open(dimensions);
        errdefer pane_pty.close(io);

        var env_map: ?std.process.Environ.Map = null;
        defer if (env_map) |*map| map.deinit();
        if (extra.env_keys.len > 0) {
            env_map = std.process.Environ.Map.init(allocator);
            for (extra.env_keys, extra.env_values) |key, value| try env_map.?.put(key, value);
        }
        const environ_ptr: ?*const std.process.Environ.Map = if (env_map) |*map| map else null;

        const fallback_argv = [_][]const u8{ "sh", "-lc", command };
        const spawn_argv: []const []const u8 = if (extra.argv.len > 0) extra.argv else &fallback_argv;
        var pane_child = std.process.spawn(io, .{
            .argv = spawn_argv,
            .cwd = if (extra.cwd.len > 0) .{ .path = extra.cwd } else .inherit,
            .environ_map = environ_ptr,
            .stdin = .{ .file = pane_pty.slave },
            .stdout = .{ .file = pane_pty.slave },
            .stderr = .{ .file = pane_pty.slave },
        }) catch |err| {
            pane_pty.close(io);
            const closed: ?session.PaneInfo = session.closePane(allocator, io, state_dir, name, pane_info.local_id) catch null;
            if (closed) |info| info.deinit(allocator);
            try writeControlError(writer, request.id, "error.PaneSpawnFailed", @errorName(err));
            try writer.flush();
            return false;
        };
        pane_pty.closeSlave(io);
        errdefer forceKillChild(&pane_child, io);

        try runtime_panes.append(allocator, .{
            .local_id = try allocator.dupe(u8, pane_info.local_id),
            .pty = pane_pty,
            .child = pane_child,
            .shadow = try shadow.Engine.init(allocator, dimensions),
        });

        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"pane\":");
        try session.writePaneInfoJson(writer, pane_info);
        try writer.print("}},\"request_id\":\"control-socket\",\"seq\":{d}}}\n", .{request.id});
        try writer.flush();
        return false;
    }

    if (std.mem.eql(u8, request.method, "pane.send")) {
        const command = request.params.command;
        if (command.len == 0) {
            try writeControlError(writer, request.id, "error.InvalidCommand", name);
            try writer.flush();
            return false;
        }
        const seq = try session.nextCommandSeq(allocator, io, state_dir, name);
        const queued: session.QueuedCommand = .{ .seq = seq, .command = command };
        var result: ShellCommandResult = undefined;
        if (request.params.pane_id.len > 0) {
            const pane_index = findRuntimePaneIndex(runtime_panes, request.params.pane_id) orelse {
                try writeControlError(writer, request.id, "error.PaneNotActive", request.params.pane_id);
                try writer.flush();
                return false;
            };
            result = try runPaneByteInput(allocator, io, runtime_panes.items[pane_index].pty.master, command);
            try runtime_panes.items[pane_index].shadow.feed(allocator, result.stdout);
        } else {
            result = try runShellCommand(allocator, io, session_master, stdout, queued);
        }
        defer result.deinit(allocator);
        try session.completeQueuedCommand(allocator, io, state_dir, name, queued, result.stdout, "", result.exit_code);
        if (request.params.pane_id.len > 0) {
            session.appendPaneResult(allocator, io, state_dir, name, request.params.pane_id, command, result.stdout, result.exit_code) catch |err| switch (err) {
                error.FileNotFound => {
                    try writeControlError(writer, request.id, "error.PaneNotFound", request.params.pane_id);
                    try writer.flush();
                    return false;
                },
                error.PaneClosed => {
                    try writeControlError(writer, request.id, "error.PaneClosed", request.params.pane_id);
                    try writer.flush();
                    return false;
                },
                else => |e| return e,
            };
        }
        if (result.stdout.len > 0) {
            _ = observe.appendOutputEvent(allocator, io, state_dir, name, request.params.pane_id, result.stdout, active_recordings) catch |err| switch (err) {
                error.NoSpaceLeft => {
                    try observe.writeObserveError(writer, request.id, "error.RecordingDiskFull", "recording disk-full policy error_back rejected pane output append");
                    try writer.flush();
                    return false;
                },
                else => |e| return e,
            };
        }
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"session\":");
        try proto.writeJsonString(writer, name);
        if (request.params.pane_id.len > 0) {
            try writer.writeAll(",\"pane_id\":");
            try proto.writeJsonString(writer, request.params.pane_id);
        }
        try writer.print(",\"exit_code\":{d},\"command\":", .{result.exit_code});
        try proto.writeJsonString(writer, command);
        try writer.writeAll(",\"stdout\":");
        try proto.writeJsonString(writer, result.stdout);
        try writer.writeAll(",\"stderr\":\"\"}");
        try writer.print(",\"request_id\":\"control-socket\",\"seq\":{d}}}\n", .{request.id});
        try writer.flush();
        return false;
    }

    if (std.mem.eql(u8, request.method, "pane.snapshot")) {
        if (request.params.pane_id.len == 0) {
            try writeControlError(writer, request.id, "error.MissingPane", "pane.snapshot");
            try writer.flush();
            return false;
        }
        const pane_index = findRuntimePaneIndex(runtime_panes, request.params.pane_id) orelse {
            try writeControlError(writer, request.id, "error.PaneNotActive", request.params.pane_id);
            try writer.flush();
            return false;
        };
        const runtime = &runtime_panes.items[pane_index];
        refreshRuntimePaneExitStatus(runtime);
        try snapshot.writePaneSnapshotResultJson(allocator, writer, request.id, name, request.params.pane_id, &runtime.shadow, .{
            .status = runtime.process_state.label(),
            .exit_code = runtime.last_exit_code,
        }, .{
            .state = .clean,
        });
        try writer.flush();
        return false;
    }

    if (std.mem.eql(u8, request.method, "pane.resize")) {
        if (request.params.pane_id.len == 0) {
            try writeControlError(writer, request.id, "error.MissingPane", "pane.resize");
            try writer.flush();
            return false;
        }
        const dimensions = controlDimensions(request.params);
        const pane_index = findRuntimePaneIndex(runtime_panes, request.params.pane_id) orelse {
            try writeControlError(writer, request.id, "error.PaneNotActive", request.params.pane_id);
            try writer.flush();
            return false;
        };
        pty.resize(runtime_panes.items[pane_index].pty.master, dimensions) catch |err| switch (err) {
            error.InvalidPaneDimensions => {
                try writeControlError(writer, request.id, "error.InvalidPaneDimensions", request.params.pane_id);
                try writer.flush();
                return false;
            },
            else => |e| return e,
        };
        try runtime_panes.items[pane_index].shadow.resize(allocator, dimensions);
        const pane_info = session.resizePane(allocator, io, state_dir, name, request.params.pane_id, dimensions) catch |err| switch (err) {
            error.FileNotFound => {
                try writeControlError(writer, request.id, "error.PaneNotFound", request.params.pane_id);
                try writer.flush();
                return false;
            },
            error.PaneClosed => {
                try writeControlError(writer, request.id, "error.PaneClosed", request.params.pane_id);
                try writer.flush();
                return false;
            },
            else => |e| return e,
        };
        defer pane_info.deinit(allocator);
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"pane\":");
        try session.writePaneInfoJson(writer, pane_info);
        try writer.print("}},\"request_id\":\"control-socket\",\"seq\":{d}}}\n", .{request.id});
        try writer.flush();
        return false;
    }

    if (std.mem.eql(u8, request.method, "pane.close")) {
        if (request.params.pane_id.len == 0) {
            try writeControlError(writer, request.id, "error.MissingPane", "pane.close");
            try writer.flush();
            return false;
        }
        const pane_index = findRuntimePaneIndex(runtime_panes, request.params.pane_id) orelse {
            try writeControlError(writer, request.id, "error.PaneNotActive", request.params.pane_id);
            try writer.flush();
            return false;
        };
        var runtime = runtime_panes.swapRemove(pane_index);
        runtime.deinit(allocator, io);
        const pane_info = session.closePane(allocator, io, state_dir, name, request.params.pane_id) catch |err| switch (err) {
            error.FileNotFound => {
                try writeControlError(writer, request.id, "error.PaneNotFound", request.params.pane_id);
                try writer.flush();
                return false;
            },
            else => |e| return e,
        };
        defer pane_info.deinit(allocator);
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"pane\":");
        try session.writePaneInfoJson(writer, pane_info);
        try writer.print("}},\"request_id\":\"control-socket\",\"seq\":{d}}}\n", .{request.id});
        try writer.flush();
        return false;
    }

    try writeControlError(writer, request.id, "error.UnsupportedMethod", request.method);
    try writer.flush();
    return false;
}

fn controlDimensions(params: ControlParams) domain.Dimensions {
    return .{
        .cols = if (params.cols == 0) 80 else params.cols,
        .rows = if (params.rows == 0) 24 else params.rows,
    };
}

const PaneCreateExtra = struct {
    argv: []const []const u8,
    env_keys: []const []const u8,
    env_values: []const []const u8,
    cwd: []const u8,
    size: ?domain.Dimensions,

    fn deinit(extra: PaneCreateExtra, allocator: Allocator) void {
        allocator.free(extra.argv);
        allocator.free(extra.env_keys);
        allocator.free(extra.env_values);
    }
};

/// Extracts the spec-shaped pane.create parameters (argv, env, cwd, size) from
/// the raw request. String slices borrow from the parsed JSON value, so the
/// parsed value must outlive the returned struct.
fn parsePaneCreateExtra(allocator: Allocator, root: std.json.Value) !PaneCreateExtra {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    var env_keys: std.ArrayList([]const u8) = .empty;
    errdefer env_keys.deinit(allocator);
    var env_values: std.ArrayList([]const u8) = .empty;
    errdefer env_values.deinit(allocator);
    var cwd: []const u8 = "";
    var size: ?domain.Dimensions = null;

    params: {
        if (root != .object) break :params;
        const params_value = root.object.get("params") orelse break :params;
        if (params_value != .object) break :params;
        const params = params_value.object;

        if (params.get("argv")) |argv_value| {
            if (argv_value == .array) {
                for (argv_value.array.items) |item| {
                    if (item == .string) try argv.append(allocator, item.string);
                }
            }
        }
        if (params.get("env")) |env_value| {
            if (env_value == .object) {
                var iterator = env_value.object.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        try env_keys.append(allocator, entry.key_ptr.*);
                        try env_values.append(allocator, entry.value_ptr.*.string);
                    }
                }
            }
        }
        if (params.get("cwd")) |cwd_value| {
            if (cwd_value == .string) cwd = cwd_value.string;
        }
        if (params.get("size")) |size_value| {
            if (size_value == .object) {
                const cols = dimensionFromValue(size_value.object.get("cols"));
                const rows = dimensionFromValue(size_value.object.get("rows"));
                if (cols != null and rows != null) size = .{ .cols = cols.?, .rows = rows.? };
            }
        }
    }

    return .{
        .argv = try argv.toOwnedSlice(allocator),
        .env_keys = try env_keys.toOwnedSlice(allocator),
        .env_values = try env_values.toOwnedSlice(allocator),
        .cwd = cwd,
        .size = size,
    };
}

fn dimensionFromValue(value: ?std.json.Value) ?u16 {
    const dimension = value orelse return null;
    return switch (dimension) {
        .integer => |raw| if (raw > 0 and raw <= std.math.maxInt(u16)) @intCast(raw) else null,
        else => null,
    };
}

/// Waits until the managed shell is idle: the child is running and the queued
/// command channel is drained. Queued commands are executed here because the
/// control loop is single-threaded and cannot drain them while this request is
/// being served.
fn waitForShellIdle(
    allocator: Allocator,
    io: Io,
    session_master: Io.File,
    stdout: *Io.Reader,
    state_dir: []const u8,
    name: []const u8,
    shell_child: *std.process.Child,
    shell_process_state: *RuntimeProcessState,
    shell_exit_code: *?u8,
    timeout_ms: u64,
) !harness_shell.Observation {
    if (timeout_ms == 0) {
        refreshChildExitStatus(shell_child, shell_process_state, shell_exit_code);
        return harness_shell.observe(toHarnessProcessState(shell_process_state.*), shell_exit_code.*, 0);
    }
    var executed: usize = 0;
    while (true) {
        refreshChildExitStatus(shell_child, shell_process_state, shell_exit_code);
        if (shell_process_state.* != .running) {
            return harness_shell.observe(toHarnessProcessState(shell_process_state.*), shell_exit_code.*, timeout_ms);
        }
        if (!(try session.hasPendingCommand(allocator, io, state_dir, name))) {
            return harness_shell.observe(.running, null, timeout_ms);
        }
        if (executed >= wait_idle_max_drained_commands) return harness_shell.timedOut(timeout_ms);
        if (try session.takePendingCommand(allocator, io, state_dir, name)) |queued| {
            defer queued.deinit(allocator);
            try executeQueuedCommand(allocator, io, session_master, stdout, state_dir, name, queued);
            executed += 1;
        }
    }
}

/// Waits until a runtime pane is output-quiescent: the child is running and no
/// PTY output arrived for `wait_idle_quiet_window_ms`. Drained output feeds the
/// shadow VT engine, taps, and recordings so observation does not lose bytes.
fn waitForPaneIdle(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    runtime: *RuntimePane,
    active_recordings: *std.ArrayList(observe.ActiveRecording),
    timeout_ms: u64,
) !harness_shell.Observation {
    if (timeout_ms == 0) {
        refreshRuntimePaneExitStatus(runtime);
        return harness_shell.observe(toHarnessProcessState(runtime.process_state), runtime.last_exit_code, 0);
    }
    var remaining = timeout_ms;
    var quiet_ms: u64 = 0;
    while (true) {
        refreshRuntimePaneExitStatus(runtime);
        if (runtime.process_state != .running) {
            return harness_shell.observe(toHarnessProcessState(runtime.process_state), runtime.last_exit_code, timeout_ms);
        }
        const drained = pumpRuntimePaneOutput(allocator, io, state_dir, name, runtime, active_recordings) catch |err| switch (err) {
            error.NoSpaceLeft => return harness_shell.unknown(
                timeout_ms,
                "a recording rejected drained pane output because the disk is full",
                "stop the recording or free disk space, then retry wait-idle",
            ),
            else => |e| return e,
        };
        if (drained > 0) {
            quiet_ms = 0;
        } else if (quiet_ms >= wait_idle_quiet_window_ms) {
            return harness_shell.observe(.running, null, timeout_ms);
        }
        if (remaining == 0) return harness_shell.timedOut(timeout_ms);
        const step = @min(remaining, wait_idle_step_ms);
        Io.sleep(io, .fromMilliseconds(@intCast(step)), .awake) catch {};
        remaining -= step;
        quiet_ms += step;
    }
}

/// Drains any immediately-available pane output into the shadow VT engine,
/// taps, and recordings. Returns the number of drained bytes.
fn pumpRuntimePaneOutput(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    runtime: *RuntimePane,
    active_recordings: *std.ArrayList(observe.ActiveRecording),
) !usize {
    const output = try pty.drainOutput(allocator, runtime.pty.master, 0, 0, wait_idle_drain_limit_bytes);
    defer allocator.free(output);
    if (output.len == 0) return 0;
    try runtime.shadow.feed(allocator, output);
    _ = try observe.appendOutputEvent(allocator, io, state_dir, name, runtime.local_id, output, active_recordings);
    return output.len;
}

fn findRuntimePaneIndex(runtime_panes: *std.ArrayList(RuntimePane), local_id: []const u8) ?usize {
    for (runtime_panes.items, 0..) |runtime, index| {
        if (std.mem.eql(u8, runtime.local_id, local_id)) return index;
    }
    return null;
}

fn toHarnessProcessState(state: RuntimeProcessState) harness_shell.ProcessState {
    return switch (state) {
        .running => .running,
        .exited => .exited,
        .signaled => .signaled,
        .unknown => .unknown,
    };
}

fn forceKillChild(child: *std.process.Child, io: Io) void {
    const pid = child.id orelse return;
    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    _ = child.wait(io) catch {};
}

fn refreshRuntimePaneExitStatus(runtime: *RuntimePane) void {
    refreshChildExitStatus(&runtime.child, &runtime.process_state, &runtime.last_exit_code);
}

fn refreshChildExitStatus(
    child: *std.process.Child,
    process_state: *RuntimeProcessState,
    last_exit_code: *?u8,
) void {
    if (process_state.* != .running) return;
    const pid = child.id orelse {
        process_state.* = .unknown;
        return;
    };

    var status: c_int = 0;
    while (true) {
        const waited = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        switch (std.c.errno(waited)) {
            .SUCCESS => {
                if (waited == 0) return;
                const status_bits: u32 = @bitCast(status);
                child.id = null;
                if (std.c.W.IFEXITED(status_bits)) {
                    process_state.* = .exited;
                    last_exit_code.* = std.c.W.EXITSTATUS(status_bits);
                    return;
                }
                if (std.c.W.IFSIGNALED(status_bits)) {
                    process_state.* = .signaled;
                    return;
                }
                process_state.* = .unknown;
                return;
            },
            .INTR => continue,
            .CHILD => {
                child.id = null;
                process_state.* = .unknown;
                return;
            },
            else => return,
        }
    }
}

fn writeControlError(writer: *Io.Writer, id: u64, code: []const u8, detail: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":false,\"error\":{\"code\":");
    try proto.writeJsonString(writer, code);
    try writer.writeAll(",\"message\":\"invalid control request\",\"detail\":");
    try proto.writeJsonString(writer, detail);
    try writer.print(",\"retryable\":false}},\"request_id\":\"control-socket\",\"seq\":{d}}}\n", .{id});
}

fn executeQueuedCommand(
    allocator: Allocator,
    io: Io,
    stdin: Io.File,
    stdout: *Io.Reader,
    state_dir: []const u8,
    name: []const u8,
    queued: session.QueuedCommand,
) !void {
    const result = try runShellCommand(allocator, io, stdin, stdout, queued);
    defer result.deinit(allocator);
    try session.completeQueuedCommand(
        allocator,
        io,
        state_dir,
        name,
        queued,
        result.stdout,
        "",
        result.exit_code,
    );
}

fn runShellCommand(
    allocator: Allocator,
    io: Io,
    stdin: Io.File,
    stdout: *Io.Reader,
    queued: session.QueuedCommand,
) !ShellCommandResult {
    const sentinel = try std.fmt.allocPrint(allocator, "__MINIMUX_DONE_{d}__:", .{queued.seq});
    defer allocator.free(sentinel);
    const shell_input = try std.fmt.allocPrint(
        allocator,
        "{s}\nprintf '\\n{s}%s\\n' \"$?\"\n",
        .{ queued.command, sentinel },
    );
    defer allocator.free(shell_input);

    try stdin.writeStreamingAll(io, shell_input);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var exit_code: u8 = 255;

    while (true) {
        const line = (try stdout.takeDelimiter('\n')) orelse break;
        const trimmed_line = std.mem.trim(u8, line, " \r\n\t");
        if (std.mem.startsWith(u8, trimmed_line, sentinel)) {
            const code_text = std.mem.trim(u8, trimmed_line[sentinel.len..], " \r\n\t");
            exit_code = std.fmt.parseInt(u8, code_text, 10) catch 255;
            break;
        }
        try output.appendSlice(allocator, line);
        try output.append(allocator, '\n');
    }

    return .{
        .stdout = try output.toOwnedSlice(allocator),
        .exit_code = exit_code,
    };
}

fn runPaneByteInput(
    allocator: Allocator,
    io: Io,
    master: Io.File,
    input: []const u8,
) !ShellCommandResult {
    const output = try pty.writeInputAndDrain(allocator, io, master, input);
    return .{
        .stdout = output,
        .exit_code = 0,
    };
}

test "pane create extra parses spec-shaped argv env cwd and size" {
    const allocator = std.testing.allocator;
    const request_text =
        \\{"jsonrpc":"2.0","id":9,"method":"pane.create","params":{"session":"x","argv":["sh","-c","echo hi"],"env":{"FOO":"bar","BAZ":"qux"},"cwd":"/tmp","size":{"cols":100,"rows":31}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_text, .{});
    defer parsed.deinit();
    const extra = try parsePaneCreateExtra(allocator, parsed.value);
    defer extra.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), extra.argv.len);
    try std.testing.expectEqualStrings("sh", extra.argv[0]);
    try std.testing.expectEqualStrings("echo hi", extra.argv[2]);
    try std.testing.expectEqual(@as(usize, 2), extra.env_keys.len);
    try std.testing.expectEqual(@as(usize, 2), extra.env_values.len);
    try std.testing.expectEqualStrings("/tmp", extra.cwd);
    try std.testing.expectEqual(@as(u16, 100), extra.size.?.cols);
    try std.testing.expectEqual(@as(u16, 31), extra.size.?.rows);

    var empty_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"method\":\"pane.create\"}", .{});
    defer empty_parsed.deinit();
    const empty = try parsePaneCreateExtra(allocator, empty_parsed.value);
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.argv.len);
    try std.testing.expectEqual(@as(usize, 0), empty.env_keys.len);
    try std.testing.expectEqual(@as(usize, 0), empty.cwd.len);
    try std.testing.expect(empty.size == null);
}

test "wait for pane idle reports quiescent exited and timeout states" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-wait-pane-idle-test";
    Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    try Io.Dir.cwd().createDirPath(io, state_dir ++ "/sessions/wait-pane");

    var recordings: std.ArrayList(observe.ActiveRecording) = .empty;
    defer {
        for (recordings.items) |recording| recording.deinit(allocator);
        recordings.deinit(allocator);
    }

    var quiet_pty = try pty.open(.{});
    const quiet_argv = [_][]const u8{"cat"};
    const quiet_child = try std.process.spawn(io, .{
        .argv = &quiet_argv,
        .stdin = .{ .file = quiet_pty.slave },
        .stdout = .{ .file = quiet_pty.slave },
        .stderr = .{ .file = quiet_pty.slave },
    });
    quiet_pty.closeSlave(io);
    var quiet_pane: RuntimePane = .{
        .local_id = try allocator.dupe(u8, "pane-quiet"),
        .pty = quiet_pty,
        .child = quiet_child,
        .shadow = try shadow.Engine.init(allocator, .{}),
    };
    defer quiet_pane.deinit(allocator, io);

    const zero_budget = try waitForPaneIdle(allocator, io, state_dir, "wait-pane", &quiet_pane, &recordings, 0);
    try std.testing.expectEqual(harness_shell.State.timeout, zero_budget.state);

    const idle = try waitForPaneIdle(allocator, io, state_dir, "wait-pane", &quiet_pane, &recordings, 2000);
    try std.testing.expectEqual(harness_shell.State.idle, idle.state);
    try std.testing.expect(idle.idle);

    var chatter_pty = try pty.open(.{});
    const chatter_argv = [_][]const u8{ "sh", "-c", "while true; do echo chatter; sleep 0.05; done" };
    const chatter_child = try std.process.spawn(io, .{
        .argv = &chatter_argv,
        .stdin = .{ .file = chatter_pty.slave },
        .stdout = .{ .file = chatter_pty.slave },
        .stderr = .{ .file = chatter_pty.slave },
    });
    chatter_pty.closeSlave(io);
    var chatter_pane: RuntimePane = .{
        .local_id = try allocator.dupe(u8, "pane-chatter"),
        .pty = chatter_pty,
        .child = chatter_child,
        .shadow = try shadow.Engine.init(allocator, .{}),
    };
    defer chatter_pane.deinit(allocator, io);

    const expired = try waitForPaneIdle(allocator, io, state_dir, "wait-pane", &chatter_pane, &recordings, 500);
    try std.testing.expectEqual(harness_shell.State.timeout, expired.state);
    try std.testing.expect(expired.retryable);
    try std.testing.expect(chatter_pane.shadow.nonBlankCellCount() > 0);

    var exit_pty = try pty.open(.{});
    const exit_argv = [_][]const u8{ "sh", "-c", "exit 7" };
    const exit_child = try std.process.spawn(io, .{
        .argv = &exit_argv,
        .stdin = .{ .file = exit_pty.slave },
        .stdout = .{ .file = exit_pty.slave },
        .stderr = .{ .file = exit_pty.slave },
    });
    exit_pty.closeSlave(io);
    var exit_pane: RuntimePane = .{
        .local_id = try allocator.dupe(u8, "pane-exit"),
        .pty = exit_pty,
        .child = exit_child,
        .shadow = try shadow.Engine.init(allocator, .{}),
    };
    defer exit_pane.deinit(allocator, io);

    var attempts: usize = 0;
    while (attempts < 200 and exit_pane.process_state == .running) : (attempts += 1) {
        refreshRuntimePaneExitStatus(&exit_pane);
        if (exit_pane.process_state == .running) try Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    const finished = try waitForPaneIdle(allocator, io, state_dir, "wait-pane", &exit_pane, &recordings, 2000);
    try std.testing.expectEqual(harness_shell.State.exited, finished.state);
    try std.testing.expectEqual(@as(?u8, 7), finished.exit_code);
}

test "background pump captures pane output without a send" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-pump-tick-test";
    Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    try Io.Dir.cwd().createDirPath(io, state_dir ++ "/sessions/pump-tick");

    var recordings: std.ArrayList(observe.ActiveRecording) = .empty;
    defer {
        for (recordings.items) |recording| recording.deinit(allocator);
        recordings.deinit(allocator);
    }
    var panes: std.ArrayList(RuntimePane) = .empty;
    defer {
        for (panes.items) |*pane_runtime| pane_runtime.deinit(allocator, io);
        panes.deinit(allocator);
    }

    var pane_pty = try pty.open(.{});
    const argv = [_][]const u8{ "sh", "-c", "echo pump-tick-ok; sleep 600" };
    const child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .{ .file = pane_pty.slave },
        .stdout = .{ .file = pane_pty.slave },
        .stderr = .{ .file = pane_pty.slave },
    });
    pane_pty.closeSlave(io);
    try panes.append(allocator, .{
        .local_id = try allocator.dupe(u8, "pane-1"),
        .pty = pane_pty,
        .child = child,
        .shadow = try shadow.Engine.init(allocator, .{}),
    });

    var attempts: usize = 0;
    var captured = false;
    while (attempts < 200 and !captured) : (attempts += 1) {
        pumpAllRuntimePanes(allocator, io, state_dir, "pump-tick", &panes, &recordings);
        const visible = try panes.items[0].shadow.visibleText(allocator);
        defer allocator.free(visible);
        captured = std.mem.indexOf(u8, visible, "pump-tick-ok") != null;
        if (!captured) try Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(captured);
}

test "runtime process status records exited child code without blocking" {
    const io = std.testing.io;
    const argv = [_][]const u8{ "sh", "-lc", "exit 27" };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer forceKillChild(&child, io);

    var process_state: RuntimeProcessState = .running;
    var exit_code: ?u8 = null;
    var attempts: usize = 0;
    while (attempts < 100 and process_state == .running) : (attempts += 1) {
        refreshChildExitStatus(&child, &process_state, &exit_code);
        if (process_state == .running) try Io.sleep(io, .fromMilliseconds(10), .awake);
    }

    try std.testing.expectEqual(RuntimeProcessState.exited, process_state);
    try std.testing.expectEqual(@as(?u8, 27), exit_code);
    try std.testing.expectEqualStrings("exited", process_state.label());
}
