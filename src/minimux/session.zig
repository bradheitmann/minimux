const std = @import("std");
const domain = @import("domain.zig");
const journal = @import("journal.zig");
const pty = @import("pty.zig");
const recovery = @import("recovery.zig");
const snapshot_store = @import("snapshot_store.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Snapshot = struct {
    name: []const u8,
    daemon_pid: i64,
    daemon_alive: bool,
    command_count: usize,
    visible_text: []const u8,
    recovery_state: domain.RecoveryState,
};

pub const CommandResult = struct {
    seq: usize,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,

    pub fn deinit(result: CommandResult, allocator: Allocator) void {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
};

pub const QueuedCommand = struct {
    seq: usize,
    command: []const u8,

    pub fn deinit(queued: QueuedCommand, allocator: Allocator) void {
        allocator.free(queued.command);
    }
};

pub const SessionInfo = struct {
    name: []const u8,
    daemon_pid: i64,
    daemon_alive: bool,
    command_count: usize,
    control_socket: []const u8,
    log_path: []const u8,
    lifecycle_state: []const u8,

    pub fn deinit(info: SessionInfo, allocator: Allocator) void {
        allocator.free(info.name);
        allocator.free(info.control_socket);
        allocator.free(info.log_path);
        allocator.free(info.lifecycle_state);
    }
};

pub const SessionList = struct {
    items: []SessionInfo,

    pub fn deinit(session_list: SessionList, allocator: Allocator) void {
        for (session_list.items) |info| info.deinit(allocator);
        allocator.free(session_list.items);
    }
};

pub const PaneInfo = struct {
    session: []const u8,
    local_id: []const u8,
    state: []const u8,
    command: []const u8,
    dimensions: domain.Dimensions,
    input_count: usize,

    pub fn deinit(info: PaneInfo, allocator: Allocator) void {
        allocator.free(info.session);
        allocator.free(info.local_id);
        allocator.free(info.state);
        allocator.free(info.command);
    }
};

pub const PaneList = struct {
    items: []PaneInfo,

    pub fn deinit(pane_list: PaneList, allocator: Allocator) void {
        for (pane_list.items) |info| info.deinit(allocator);
        allocator.free(pane_list.items);
    }
};

pub fn writeSessionInfoJson(writer: *Io.Writer, info: SessionInfo) !void {
    try writer.writeAll("{\"name\":");
    try @import("proto.zig").writeJsonString(writer, info.name);
    try writer.print(",\"daemon_pid\":{d},\"daemon_alive\":{},\"command_count\":{d},\"state\":", .{
        info.daemon_pid,
        info.daemon_alive,
        info.command_count,
    });
    try @import("proto.zig").writeJsonString(writer, info.lifecycle_state);
    try writer.writeAll(",\"control_socket\":");
    try @import("proto.zig").writeJsonString(writer, info.control_socket);
    try writer.writeAll(",\"log_path\":");
    try @import("proto.zig").writeJsonString(writer, info.log_path);
    try writer.writeAll("}");
}

pub fn writePaneInfoJson(writer: *Io.Writer, info: PaneInfo) !void {
    const proto = @import("proto.zig");
    try writer.writeAll("{\"pane_id\":");
    try pty.writePaneId(writer, info.session, info.local_id);
    try writer.writeAll(",\"session\":");
    try proto.writeJsonString(writer, info.session);
    try writer.writeAll(",\"local_id\":");
    try proto.writeJsonString(writer, info.local_id);
    try writer.writeAll(",\"state\":");
    try proto.writeJsonString(writer, info.state);
    try writer.writeAll(",\"command\":");
    try proto.writeJsonString(writer, info.command);
    try writer.print(",\"dimensions\":{{\"cols\":{d},\"rows\":{d}}},\"input_count\":{d}}}", .{
        info.dimensions.cols,
        info.dimensions.rows,
        info.input_count,
    });
}

pub fn create(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    daemon_pid: i64,
    argv: []const []const u8,
) !void {
    try domain.validateSessionName(name);
    try ensureSessionDir(allocator, io, state_dir, name);

    const pid_text = try std.fmt.allocPrint(allocator, "{d}\n", .{daemon_pid});
    defer allocator.free(pid_text);
    try writeSessionFile(allocator, io, state_dir, name, "daemon.pid", pid_text);

    const argv_text = try joinArgv(allocator, argv);
    defer allocator.free(argv_text);
    try writeSessionFile(allocator, io, state_dir, name, "argv.txt", argv_text);

    try writeSessionFile(allocator, io, state_dir, name, "visible.txt", "");
    try writeSessionFile(allocator, io, state_dir, name, "commands.count", "0\n");
    try writeSessionFile(allocator, io, state_dir, name, "recovery.state", "clean\n");
    try writeSessionFile(allocator, io, state_dir, name, "lifecycle.state", "running\n");
    try writeSessionFile(allocator, io, state_dir, name, "daemon.log", "session created\n");
    _ = try journal.appendLine(allocator, io, state_dir, name, "{\"kind\":\"session_created\",\"seq\":0}\n", 1, 0);
    try snapshot_store.writeSnapshot(allocator, io, state_dir, name, .{
        .daemon_pid = daemon_pid,
        .command_count = 0,
        .recovery_state = .clean,
        .visible_text = "",
    });
    const socket_path = try controlSocketPath(allocator, state_dir, name);
    defer allocator.free(socket_path);
    try writeSessionFile(allocator, io, state_dir, name, "control.path", socket_path);
    const daemon_log_path = try logPath(allocator, state_dir, name);
    defer allocator.free(daemon_log_path);
    try writeSessionFile(allocator, io, state_dir, name, "log.path", daemon_log_path);
    try ensureSessionDir(allocator, io, state_dir, name);
    const results_dir = try sessionPath(allocator, state_dir, name, "results");
    defer allocator.free(results_dir);
    try Io.Dir.cwd().createDirPath(io, results_dir);
    const panes_dir = try sessionPath(allocator, state_dir, name, "panes");
    defer allocator.free(panes_dir);
    try Io.Dir.cwd().createDirPath(io, panes_dir);
}

pub fn listSessions(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
) !SessionList {
    const sessions_root = try std.fmt.allocPrint(allocator, "{s}/sessions", .{state_dir});
    defer allocator.free(sessions_root);

    var dir = Io.Dir.cwd().openDir(io, sessions_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .items = try allocator.alloc(SessionInfo, 0) },
        else => |e| return e,
    };
    defer dir.close(io);

    var infos: std.ArrayList(SessionInfo) = .empty;
    errdefer {
        for (infos.items) |info| info.deinit(allocator);
        infos.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        domain.validateSessionName(entry.name) catch continue;
        const info = inspect(allocator, io, state_dir, entry.name) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        try infos.append(allocator, info);
    }

    return .{ .items = try infos.toOwnedSlice(allocator) };
}

pub fn inspect(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) !SessionInfo {
    try domain.validateSessionName(name);
    const pid_text = try readSessionFile(allocator, io, state_dir, name, "daemon.pid");
    defer allocator.free(pid_text);
    const pid = try std.fmt.parseInt(i64, std.mem.trim(u8, pid_text, " \r\n\t"), 10);

    const lifecycle_text = try readSessionFileOptional(allocator, io, state_dir, name, "lifecycle.state");
    defer allocator.free(lifecycle_text);
    const lifecycle_trimmed = std.mem.trim(u8, lifecycle_text, " \r\n\t");
    const lifecycle_state = if (lifecycle_trimmed.len == 0) "running" else lifecycle_trimmed;

    const unavailable = std.mem.eql(u8, lifecycle_state, "terminated") or std.mem.eql(u8, lifecycle_state, "unavailable");
    const alive = if (unavailable)
        false
    else
        try isProcessAlive(allocator, io, pid);
    const socket_path = try controlSocketPath(allocator, state_dir, name);
    errdefer allocator.free(socket_path);
    if (!alive) {
        Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    return .{
        .name = try allocator.dupe(u8, name),
        .daemon_pid = pid,
        .daemon_alive = alive,
        .command_count = try readCommandCount(allocator, io, state_dir, name),
        .control_socket = socket_path,
        .log_path = try logPath(allocator, state_dir, name),
        .lifecycle_state = try allocator.dupe(u8, lifecycle_state),
    };
}

pub fn terminate(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) !SessionInfo {
    var before = try inspect(allocator, io, state_dir, name);
    defer before.deinit(allocator);

    if (before.daemon_alive) {
        try writeSessionFile(allocator, io, state_dir, name, "terminate.request", "1\n");
        try waitForDaemonExit(allocator, io, state_dir, name, 2000);
    }

    try writeSessionFile(allocator, io, state_dir, name, "lifecycle.state", "terminated\n");
    try appendSessionFile(allocator, io, state_dir, name, "daemon.log", "session terminated\n");
    const socket_path = try controlSocketPath(allocator, state_dir, name);
    defer allocator.free(socket_path);
    Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    return inspect(allocator, io, state_dir, name);
}

pub fn markTerminated(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) !SessionInfo {
    try writeSessionFile(allocator, io, state_dir, name, "lifecycle.state", "terminated\n");
    try appendSessionFile(allocator, io, state_dir, name, "daemon.log", "session terminated\n");
    const socket_path = try controlSocketPath(allocator, state_dir, name);
    defer allocator.free(socket_path);
    Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    return inspect(allocator, io, state_dir, name);
}

pub fn markUnavailable(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) !SessionInfo {
    try writeSessionFile(allocator, io, state_dir, name, "lifecycle.state", "unavailable\n");
    try appendSessionFile(allocator, io, state_dir, name, "daemon.log", "control socket unavailable\n");
    const socket_path = try controlSocketPath(allocator, state_dir, name);
    defer allocator.free(socket_path);
    Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    return inspect(allocator, io, state_dir, name);
}

pub fn createPane(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    command: []const u8,
    dimensions: domain.Dimensions,
) !PaneInfo {
    var info = try inspect(allocator, io, state_dir, name);
    defer info.deinit(allocator);
    if (!info.daemon_alive) return error.DaemonNotRunning;
    if (command.len == 0) return error.InvalidPaneCommand;
    if (dimensions.cols == 0 or dimensions.rows == 0) return error.InvalidPaneDimensions;

    const next_seq = try readPaneCount(allocator, io, state_dir, name) + 1;
    const local_id = try std.fmt.allocPrint(allocator, "pane-{d}", .{next_seq});
    defer allocator.free(local_id);
    try pty.validatePaneLocalId(local_id);
    try ensurePaneDir(allocator, io, state_dir, name, local_id);

    try writePaneFile(allocator, io, state_dir, name, local_id, "state", "open\n");
    try writePaneFile(allocator, io, state_dir, name, local_id, "command", command);
    try writePaneFile(allocator, io, state_dir, name, local_id, "visible.txt", "");
    try writePaneFile(allocator, io, state_dir, name, local_id, "input.count", "0\n");

    const cols = try std.fmt.allocPrint(allocator, "{d}\n", .{dimensions.cols});
    defer allocator.free(cols);
    const rows = try std.fmt.allocPrint(allocator, "{d}\n", .{dimensions.rows});
    defer allocator.free(rows);
    try writePaneFile(allocator, io, state_dir, name, local_id, "cols", cols);
    try writePaneFile(allocator, io, state_dir, name, local_id, "rows", rows);

    const count = try std.fmt.allocPrint(allocator, "{d}\n", .{next_seq});
    defer allocator.free(count);
    try writeSessionFile(allocator, io, state_dir, name, "panes.count", count);

    return inspectPane(allocator, io, state_dir, name, local_id);
}

pub fn inspectPane(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    local_id: []const u8,
) !PaneInfo {
    try domain.validateSessionName(name);
    try pty.validatePaneLocalId(local_id);
    const state_text = try readPaneFile(allocator, io, state_dir, name, local_id, "state");
    defer allocator.free(state_text);
    const state_trimmed = std.mem.trim(u8, state_text, " \r\n\t");
    const state = if (state_trimmed.len == 0) "open" else state_trimmed;

    const command = try readPaneFileOptional(allocator, io, state_dir, name, local_id, "command");
    errdefer allocator.free(command);
    const input_count = try readPaneInputCount(allocator, io, state_dir, name, local_id);
    const dimensions = try readPaneDimensions(allocator, io, state_dir, name, local_id);

    return .{
        .session = try allocator.dupe(u8, name),
        .local_id = try allocator.dupe(u8, local_id),
        .state = try allocator.dupe(u8, state),
        .command = command,
        .dimensions = dimensions,
        .input_count = input_count,
    };
}

pub fn listPanes(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) !PaneList {
    try domain.validateSessionName(name);
    const panes_root = try sessionPath(allocator, state_dir, name, "panes");
    defer allocator.free(panes_root);
    var dir = Io.Dir.cwd().openDir(io, panes_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .items = try allocator.alloc(PaneInfo, 0) },
        else => |e| return e,
    };
    defer dir.close(io);

    var infos: std.ArrayList(PaneInfo) = .empty;
    errdefer {
        for (infos.items) |info| info.deinit(allocator);
        infos.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        pty.validatePaneLocalId(entry.name) catch continue;
        const pane_info = try inspectPane(allocator, io, state_dir, name, entry.name);
        try infos.append(allocator, pane_info);
    }
    return .{ .items = try infos.toOwnedSlice(allocator) };
}

pub fn resizePane(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    local_id: []const u8,
    dimensions: domain.Dimensions,
) !PaneInfo {
    if (dimensions.cols == 0 or dimensions.rows == 0) return error.InvalidPaneDimensions;
    var before = try inspectPane(allocator, io, state_dir, name, local_id);
    defer before.deinit(allocator);
    if (!std.mem.eql(u8, before.state, pty.PaneState.open.label())) return error.PaneClosed;

    const cols = try std.fmt.allocPrint(allocator, "{d}\n", .{dimensions.cols});
    defer allocator.free(cols);
    const rows = try std.fmt.allocPrint(allocator, "{d}\n", .{dimensions.rows});
    defer allocator.free(rows);
    try writePaneFile(allocator, io, state_dir, name, local_id, "cols", cols);
    try writePaneFile(allocator, io, state_dir, name, local_id, "rows", rows);
    return inspectPane(allocator, io, state_dir, name, local_id);
}

pub fn closePane(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    local_id: []const u8,
) !PaneInfo {
    var before = try inspectPane(allocator, io, state_dir, name, local_id);
    defer before.deinit(allocator);
    try writePaneFile(allocator, io, state_dir, name, local_id, "state", "closed\n");
    return inspectPane(allocator, io, state_dir, name, local_id);
}

pub fn appendPaneResult(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    local_id: []const u8,
    input: []const u8,
    output: []const u8,
    exit_code: u8,
) !void {
    var before = try inspectPane(allocator, io, state_dir, name, local_id);
    defer before.deinit(allocator);
    if (!std.mem.eql(u8, before.state, pty.PaneState.open.label())) return error.PaneClosed;

    const existing = try readPaneFileOptional(allocator, io, state_dir, name, local_id, "visible.txt");
    defer allocator.free(existing);
    const entry = try std.fmt.allocPrint(
        allocator,
        "$ {s}\n{s}",
        .{ input, output },
    );
    defer allocator.free(entry);
    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, entry });
    defer allocator.free(combined);
    try writePaneFile(allocator, io, state_dir, name, local_id, "visible.txt", combined);

    const next_count = try std.fmt.allocPrint(allocator, "{d}\n", .{before.input_count + 1});
    defer allocator.free(next_count);
    try writePaneFile(allocator, io, state_dir, name, local_id, "input.count", next_count);

    _ = try journal.appendPaneInput(allocator, io, state_dir, name, local_id, exit_code, 4);
}

pub fn paneVisibleText(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    local_id: []const u8,
) ![]u8 {
    var info = try inspectPane(allocator, io, state_dir, name, local_id);
    defer info.deinit(allocator);
    return readPaneFileOptional(allocator, io, state_dir, name, local_id, "visible.txt");
}

pub fn controlSocketPath(allocator: Allocator, state_dir: []const u8, name: []const u8) ![]u8 {
    try domain.validateSessionName(name);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(state_dir);
    hasher.update("\x00");
    hasher.update(name);
    const control_id = hasher.final();
    return std.fmt.allocPrint(allocator, "/tmp/minimux-{x}-{s}.sock", .{ control_id, name });
}

pub fn logPath(allocator: Allocator, state_dir: []const u8, name: []const u8) ![]u8 {
    try domain.validateSessionName(name);
    return sessionPath(allocator, state_dir, name, "daemon.log");
}

pub fn markControlSocketReady(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) !void {
    try appendSessionFile(allocator, io, state_dir, name, "daemon.log", "control socket listening\n");
}

pub fn takeTerminateRequest(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) !bool {
    const request = readSessionFile(allocator, io, state_dir, name, "terminate.request") catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer allocator.free(request);
    try deleteSessionFile(allocator, io, state_dir, name, "terminate.request");
    return true;
}

pub fn nextCommandSeq(allocator: Allocator, io: Io, state_dir: []const u8, name: []const u8) !usize {
    return try readCommandCount(allocator, io, state_dir, name) + 1;
}

pub fn waitForControlSocket(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    timeout_ms: u64,
) !void {
    const socket_path = try controlSocketPath(allocator, state_dir, name);
    defer allocator.free(socket_path);

    const interval_ms: u64 = 25;
    const attempts = @max(@as(u64, 1), timeout_ms / interval_ms);
    var index: u64 = 0;
    while (index < attempts) : (index += 1) {
        const stat = Io.Dir.cwd().statFile(io, socket_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try Io.sleep(io, .fromMilliseconds(@intCast(interval_ms)), .awake);
                continue;
            },
            else => |e| return e,
        };
        if (stat.kind == .unix_domain_socket) return;
        try Io.sleep(io, .fromMilliseconds(@intCast(interval_ms)), .awake);
    }
    return error.ControlSocketTimeout;
}

fn waitForDaemonExit(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    timeout_ms: u64,
) !void {
    const interval_ms: u64 = 25;
    const attempts = @max(@as(u64, 1), timeout_ms / interval_ms);
    var index: u64 = 0;
    while (index < attempts) : (index += 1) {
        if (!(try daemonAlive(allocator, io, state_dir, name))) return;
        try Io.sleep(io, .fromMilliseconds(@intCast(interval_ms)), .awake);
    }

    const pid_text = try readSessionFile(allocator, io, state_dir, name, "daemon.pid");
    defer allocator.free(pid_text);
    const pid: std.posix.pid_t = @intCast(try std.fmt.parseInt(i64, std.mem.trim(u8, pid_text, " \r\n\t"), 10));
    std.posix.kill(pid, std.posix.SIG.TERM) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => |e| return e,
    };
}

pub const QueueError = error{ DaemonNotRunning, CommandTimeout } || anyerror;

pub fn enqueueCommandAndWait(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    command: []const u8,
    timeout_ms: u64,
) QueueError!CommandResult {
    try domain.validateSessionName(name);
    if (!(try daemonAlive(allocator, io, state_dir, name))) return error.DaemonNotRunning;

    const seq = try readCommandCount(allocator, io, state_dir, name) + 1;
    const seq_text = try std.fmt.allocPrint(allocator, "{d}\n", .{seq});
    defer allocator.free(seq_text);

    try writeSessionFile(allocator, io, state_dir, name, "pending.seq", seq_text);
    try writeSessionFile(allocator, io, state_dir, name, "pending.cmd", command);

    const interval_ms: u64 = 25;
    const attempts = @max(@as(u64, 1), timeout_ms / interval_ms);
    var index: u64 = 0;
    while (index < attempts) : (index += 1) {
        if (try readCommandResult(allocator, io, state_dir, name, seq)) |result| return result;
        if (!(try daemonAlive(allocator, io, state_dir, name))) return error.DaemonNotRunning;
        try Io.sleep(io, .fromMilliseconds(@intCast(interval_ms)), .awake);
    }
    return error.CommandTimeout;
}

pub fn hasPendingCommand(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) !bool {
    const target = try sessionPath(allocator, state_dir, name, "pending.cmd");
    defer allocator.free(target);
    _ = Io.Dir.cwd().statFile(io, target, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

pub fn takePendingCommand(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) !?QueuedCommand {
    const command = readSessionFile(allocator, io, state_dir, name, "pending.cmd") catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    errdefer allocator.free(command);

    const seq_text = try readSessionFile(allocator, io, state_dir, name, "pending.seq");
    defer allocator.free(seq_text);
    const seq = try std.fmt.parseInt(usize, std.mem.trim(u8, seq_text, " \r\n\t"), 10);

    try deleteSessionFile(allocator, io, state_dir, name, "pending.cmd");
    try deleteSessionFile(allocator, io, state_dir, name, "pending.seq");

    return .{
        .seq = seq,
        .command = command,
    };
}

pub fn completeQueuedCommand(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    queued: QueuedCommand,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
) !void {
    try appendCommandResult(allocator, io, state_dir, name, queued.command, stdout, stderr, exit_code);

    const status_name = try resultFileName(allocator, queued.seq, "status");
    defer allocator.free(status_name);
    const stdout_name = try resultFileName(allocator, queued.seq, "stdout");
    defer allocator.free(stdout_name);
    const stderr_name = try resultFileName(allocator, queued.seq, "stderr");
    defer allocator.free(stderr_name);

    const status = try std.fmt.allocPrint(allocator, "{d}\n", .{exit_code});
    defer allocator.free(status);
    try writeSessionFile(allocator, io, state_dir, name, stdout_name, stdout);
    try writeSessionFile(allocator, io, state_dir, name, stderr_name, stderr);
    try writeSessionFile(allocator, io, state_dir, name, status_name, status);
}

pub fn appendCommandResult(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    command: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
) !void {
    try domain.validateSessionName(name);
    const pid_check = try readSessionFile(allocator, io, state_dir, name, "daemon.pid");
    defer allocator.free(pid_check);

    const existing = try readSessionFileOptional(allocator, io, state_dir, name, "visible.txt");
    defer allocator.free(existing);

    const entry = try std.fmt.allocPrint(
        allocator,
        "$ {s}\n{s}{s}{s}",
        .{
            command,
            stdout,
            stderr,
            if (stdout.len == 0 and stderr.len == 0) "\n" else "",
        },
    );
    defer allocator.free(entry);

    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, entry });
    defer allocator.free(combined);
    try writeSessionFile(allocator, io, state_dir, name, "visible.txt", combined);

    const count = try readCommandCount(allocator, io, state_dir, name);
    const command_count = count + 1;
    const next_count = try std.fmt.allocPrint(allocator, "{d}\n", .{command_count});
    defer allocator.free(next_count);
    try writeSessionFile(allocator, io, state_dir, name, "commands.count", next_count);

    _ = try journal.appendCommand(allocator, io, state_dir, name, command_count, command, entry, exit_code, 4);

    const pid_text = try readSessionFile(allocator, io, state_dir, name, "daemon.pid");
    defer allocator.free(pid_text);
    const daemon_pid = try std.fmt.parseInt(i64, std.mem.trim(u8, pid_text, " \r\n\t"), 10);
    try snapshot_store.writeSnapshot(allocator, io, state_dir, name, .{
        .daemon_pid = daemon_pid,
        .command_count = command_count,
        .recovery_state = .clean,
        .visible_text = combined,
    });
}

pub fn snapshot(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) !Snapshot {
    try domain.validateSessionName(name);

    const pid_text = try readSessionFile(allocator, io, state_dir, name, "daemon.pid");
    defer allocator.free(pid_text);
    const pid = try std.fmt.parseInt(i64, std.mem.trim(u8, pid_text, " \r\n\t"), 10);
    const alive = try isProcessAlive(allocator, io, pid);

    var recovery_state: domain.RecoveryState = .clean;
    var recovered_visible: ?[]u8 = null;
    defer if (recovered_visible) |text| allocator.free(text);
    if (!alive) {
        const report = try recovery.recoverSession(allocator, io, state_dir, name);
        recovery_state = report.recovery_state;
        recovered_visible = try allocator.dupe(u8, report.visible_text);
        try writeSessionFile(allocator, io, state_dir, name, "visible.txt", report.visible_text);
        const recovered_count = try std.fmt.allocPrint(allocator, "{d}\n", .{report.command_count});
        defer allocator.free(recovered_count);
        try writeSessionFile(allocator, io, state_dir, name, "commands.count", recovered_count);
        report.deinit(allocator);
        const socket_path = try controlSocketPath(allocator, state_dir, name);
        defer allocator.free(socket_path);
        Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        try writeSessionFile(allocator, io, state_dir, name, "recovery.state", domain.recoveryLabel(recovery_state));
    } else {
        const state_text = try readSessionFileOptional(allocator, io, state_dir, name, "recovery.state");
        defer allocator.free(state_text);
        if (std.mem.eql(u8, std.mem.trim(u8, state_text, " \r\n\t"), "recovered")) {
            recovery_state = .recovered;
        }
    }

    const visible = if (recovered_visible) |text| blk: {
        recovered_visible = null;
        break :blk text;
    } else try readSessionFileOptional(allocator, io, state_dir, name, "visible.txt");
    errdefer allocator.free(visible);

    return .{
        .name = name,
        .daemon_pid = pid,
        .daemon_alive = alive,
        .command_count = try readCommandCount(allocator, io, state_dir, name),
        .visible_text = visible,
        .recovery_state = recovery_state,
    };
}

pub fn destroySnapshot(allocator: Allocator, snap: Snapshot) void {
    allocator.free(snap.visible_text);
}

pub fn daemonAlive(allocator: Allocator, io: Io, state_dir: []const u8, name: []const u8) !bool {
    const pid_text = try readSessionFile(allocator, io, state_dir, name, "daemon.pid");
    defer allocator.free(pid_text);
    const pid = try std.fmt.parseInt(i64, std.mem.trim(u8, pid_text, " \r\n\t"), 10);
    return isProcessAlive(allocator, io, pid);
}

fn ensureSessionDir(allocator: Allocator, io: Io, state_dir: []const u8, name: []const u8) !void {
    const sessions_dir = try std.fmt.allocPrint(allocator, "{s}/sessions/{s}", .{ state_dir, name });
    defer allocator.free(sessions_dir);
    try Io.Dir.cwd().createDirPath(io, sessions_dir);
}

fn sessionPath(allocator: Allocator, state_dir: []const u8, name: []const u8, file_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sessions/{s}/{s}", .{ state_dir, name, file_name });
}

fn panePath(
    allocator: Allocator,
    state_dir: []const u8,
    name: []const u8,
    local_id: []const u8,
    file_name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sessions/{s}/panes/{s}/{s}", .{ state_dir, name, local_id, file_name });
}

fn ensurePaneDir(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    local_id: []const u8,
) !void {
    const pane_dir = try std.fmt.allocPrint(allocator, "{s}/sessions/{s}/panes/{s}", .{ state_dir, name, local_id });
    defer allocator.free(pane_dir);
    try Io.Dir.cwd().createDirPath(io, pane_dir);
}

fn writeSessionFile(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    file_name: []const u8,
    data: []const u8,
) !void {
    try ensureSessionDir(allocator, io, state_dir, name);
    const target = try sessionPath(allocator, state_dir, name, file_name);
    defer allocator.free(target);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{target});
    defer allocator.free(tmp);
    const cwd = Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{ .read = true } });
    try cwd.rename(tmp, cwd, target, io);
}

fn writePaneFile(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    local_id: []const u8,
    file_name: []const u8,
    data: []const u8,
) !void {
    try ensurePaneDir(allocator, io, state_dir, name, local_id);
    const target = try panePath(allocator, state_dir, name, local_id, file_name);
    defer allocator.free(target);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{target});
    defer allocator.free(tmp);
    const cwd = Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{ .read = true } });
    try cwd.rename(tmp, cwd, target, io);
}

fn appendSessionFile(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    file_name: []const u8,
    data: []const u8,
) !void {
    const existing = try readSessionFileOptional(allocator, io, state_dir, name, file_name);
    defer allocator.free(existing);
    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, data });
    defer allocator.free(combined);
    try writeSessionFile(allocator, io, state_dir, name, file_name, combined);
}

fn deleteSessionFile(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    file_name: []const u8,
) !void {
    const target = try sessionPath(allocator, state_dir, name, file_name);
    defer allocator.free(target);
    Io.Dir.cwd().deleteFile(io, target) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

fn readSessionFile(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    file_name: []const u8,
) ![]u8 {
    const target = try sessionPath(allocator, state_dir, name, file_name);
    defer allocator.free(target);
    return Io.Dir.cwd().readFileAlloc(io, target, allocator, .limited(1024 * 1024));
}

fn readPaneFile(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    local_id: []const u8,
    file_name: []const u8,
) ![]u8 {
    const target = try panePath(allocator, state_dir, name, local_id, file_name);
    defer allocator.free(target);
    return Io.Dir.cwd().readFileAlloc(io, target, allocator, .limited(1024 * 1024));
}

fn readSessionFileOptional(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    file_name: []const u8,
) ![]u8 {
    return readSessionFile(allocator, io, state_dir, name, file_name) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => |e| return e,
    };
}

fn readPaneFileOptional(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    local_id: []const u8,
    file_name: []const u8,
) ![]u8 {
    return readPaneFile(allocator, io, state_dir, name, local_id, file_name) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => |e| return e,
    };
}

fn readCommandCount(allocator: Allocator, io: Io, state_dir: []const u8, name: []const u8) !usize {
    const text = try readSessionFileOptional(allocator, io, state_dir, name, "commands.count");
    defer allocator.free(text);
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(usize, trimmed, 10);
}

fn readPaneCount(allocator: Allocator, io: Io, state_dir: []const u8, name: []const u8) !usize {
    const text = try readSessionFileOptional(allocator, io, state_dir, name, "panes.count");
    defer allocator.free(text);
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(usize, trimmed, 10);
}

fn readPaneInputCount(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    local_id: []const u8,
) !usize {
    const text = try readPaneFileOptional(allocator, io, state_dir, name, local_id, "input.count");
    defer allocator.free(text);
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(usize, trimmed, 10);
}

fn readPaneDimensions(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    local_id: []const u8,
) !domain.Dimensions {
    const cols_text = try readPaneFileOptional(allocator, io, state_dir, name, local_id, "cols");
    defer allocator.free(cols_text);
    const rows_text = try readPaneFileOptional(allocator, io, state_dir, name, local_id, "rows");
    defer allocator.free(rows_text);
    const cols_trimmed = std.mem.trim(u8, cols_text, " \r\n\t");
    const rows_trimmed = std.mem.trim(u8, rows_text, " \r\n\t");
    return .{
        .cols = if (cols_trimmed.len == 0) 80 else try std.fmt.parseInt(u16, cols_trimmed, 10),
        .rows = if (rows_trimmed.len == 0) 24 else try std.fmt.parseInt(u16, rows_trimmed, 10),
    };
}

fn readCommandResult(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    seq: usize,
) !?CommandResult {
    const status_name = try resultFileName(allocator, seq, "status");
    defer allocator.free(status_name);

    const status_text = readSessionFile(allocator, io, state_dir, name, status_name) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer allocator.free(status_text);

    const stdout_name = try resultFileName(allocator, seq, "stdout");
    defer allocator.free(stdout_name);
    const stderr_name = try resultFileName(allocator, seq, "stderr");
    defer allocator.free(stderr_name);

    const stdout = try readSessionFileOptional(allocator, io, state_dir, name, stdout_name);
    errdefer allocator.free(stdout);
    const stderr = try readSessionFileOptional(allocator, io, state_dir, name, stderr_name);
    errdefer allocator.free(stderr);

    const exit_code = try std.fmt.parseInt(u8, std.mem.trim(u8, status_text, " \r\n\t"), 10);
    return .{
        .seq = seq,
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
    };
}

fn resultFileName(allocator: Allocator, seq: usize, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "results/{d}.{s}", .{ seq, suffix });
}

fn joinArgv(allocator: Allocator, argv: []const []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index != 0) try buffer.append(allocator, '\t');
        try buffer.appendSlice(allocator, arg);
    }
    try buffer.append(allocator, '\n');
    return buffer.toOwnedSlice(allocator);
}

fn isProcessAlive(allocator: Allocator, io: Io, pid: i64) !bool {
    const pid_text = try std.fmt.allocPrint(allocator, "{d}", .{pid});
    defer allocator.free(pid_text);
    const argv = [_][]const u8{ "ps", "-p", pid_text, "-o", "stat=" };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    return !std.mem.containsAtLeast(u8, result.stdout, 1, "Z");
}

test "pending command queue is observable without consuming" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-pending-peek-test";
    Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    const argv = [_][]const u8{"bash"};
    try create(allocator, io, state_dir, "pending-peek", @intCast(std.posix.system.getpid()), &argv);
    try std.testing.expect(!(try hasPendingCommand(allocator, io, state_dir, "pending-peek")));

    try writeSessionFile(allocator, io, state_dir, "pending-peek", "pending.seq", "1\n");
    try writeSessionFile(allocator, io, state_dir, "pending-peek", "pending.cmd", "echo queued");
    try std.testing.expect(try hasPendingCommand(allocator, io, state_dir, "pending-peek"));
    try std.testing.expect(try hasPendingCommand(allocator, io, state_dir, "pending-peek"));

    const queued = (try takePendingCommand(allocator, io, state_dir, "pending-peek")) orelse return error.MissingQueuedCommand;
    defer queued.deinit(allocator);
    try std.testing.expectEqualStrings("echo queued", queued.command);
    try std.testing.expect(!(try hasPendingCommand(allocator, io, state_dir, "pending-peek")));
}

test "snapshot marks dead daemon as recovered" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-session-test";
    Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    const argv = [_][]const u8{"bash"};
    try create(allocator, io, state_dir, "dead-daemon", 99999999, &argv);
    try appendCommandResult(allocator, io, state_dir, "dead-daemon", "echo hi", "hi\n", "", 0);
    const snap = try snapshot(allocator, io, state_dir, "dead-daemon");
    defer destroySnapshot(allocator, snap);

    try std.testing.expectEqual(domain.RecoveryState.recovered, snap.recovery_state);
    try std.testing.expect(std.mem.containsAtLeast(u8, snap.visible_text, 1, "echo hi"));
    try std.testing.expect(std.mem.containsAtLeast(u8, snap.visible_text, 1, "hi"));
}
