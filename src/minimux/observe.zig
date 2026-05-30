const std = @import("std");
const domain = @import("domain.zig");
const proto = @import("proto.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const DiskFullPolicy = enum {
    error_back,
    stop_recording,
    drop_oldest,

    pub fn label(policy: DiskFullPolicy) []const u8 {
        return switch (policy) {
            .error_back => "error_back",
            .stop_recording => "stop_recording",
            .drop_oldest => "drop_oldest",
        };
    }

    pub fn parse(value: []const u8) DiskFullPolicy {
        if (std.mem.eql(u8, value, "error_back")) return .error_back;
        if (std.mem.eql(u8, value, "stop_recording")) return .stop_recording;
        if (std.mem.eql(u8, value, "drop_oldest")) return .drop_oldest;
        return .error_back;
    }
};

pub const BackPressure = struct {
    max_pending_events: usize = 64,
    local: []const u8 = "block_control_response_until_reader_accepts_event",
    remote: []const u8 = "bounded_queue_close_slow_reader_on_overflow",
    ordering: []const u8 = "monotonic_seq_per_session",
};

pub const ActiveRecording = struct {
    id: []u8,
    pane_id: []u8,
    path: []u8,
    policy: DiskFullPolicy,
    started_at_ns: i128,

    pub fn deinit(recording: ActiveRecording, allocator: Allocator) void {
        allocator.free(recording.id);
        allocator.free(recording.pane_id);
        allocator.free(recording.path);
    }
};

pub const ActiveTap = struct {
    id: []u8,
    start_seq: u64,
    pane_id: []u8,

    pub fn deinit(tap: ActiveTap, allocator: Allocator) void {
        allocator.free(tap.id);
        allocator.free(tap.pane_id);
    }
};

pub const StartRecordingResult = struct {
    recording: ActiveRecording,
    dir_path: []u8,
    file_mode: u16,
    dir_mode: u16,

    pub fn deinit(result: StartRecordingResult, allocator: Allocator) void {
        result.recording.deinit(allocator);
        allocator.free(result.dir_path);
    }
};

pub const AppendResult = struct {
    seq: u64,
    stopped_recordings: usize,
};

pub fn startRecording(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    session_name: []const u8,
    pane_id: []const u8,
    requested_path: []const u8,
    next_recording_index: usize,
    policy: DiskFullPolicy,
) !StartRecordingResult {
    try domain.validateSessionName(session_name);
    try validateRelativeId(pane_id);

    const recording_id = try std.fmt.allocPrint(allocator, "rec-{d}", .{next_recording_index});
    errdefer allocator.free(recording_id);

    const path = if (requested_path.len == 0)
        try std.fmt.allocPrint(
            allocator,
            "{s}/sessions/{s}/recordings/{s}.cast",
            .{ state_dir, session_name, recording_id },
        )
    else
        try allocator.dupe(u8, requested_path);
    errdefer allocator.free(path);
    try validateRecordingPath(path);

    const dir_path = try recordingDirPath(allocator, path);
    errdefer allocator.free(dir_path);
    try ensurePrivateDirectory(io, dir_path);

    var file = try Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = true,
        .permissions = .fromMode(0o600),
    });
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o600));
    try file.writeStreamingAll(io,
        \\{"version":2,"width":80,"height":24,"timestamp":0,"env":{"TERM":"xterm-256color"}}
        \\
    );
    try file.sync(io);

    return .{
        .recording = .{
            .id = recording_id,
            .pane_id = try allocator.dupe(u8, pane_id),
            .path = path,
            .policy = policy,
            .started_at_ns = try monotonicNowNs(),
        },
        .dir_path = dir_path,
        .file_mode = try modeOf(io, path),
        .dir_mode = try modeOf(io, dir_path),
    };
}

pub fn stopRecording(recordings: *std.ArrayList(ActiveRecording), allocator: Allocator, recording_id: []const u8) ?ActiveRecording {
    for (recordings.items, 0..) |recording, index| {
        if (std.mem.eql(u8, recording.id, recording_id)) {
            return recordings.swapRemove(index);
        }
    }
    _ = allocator;
    return null;
}

pub fn appendOutputEvent(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    session_name: []const u8,
    pane_id: []const u8,
    output: []const u8,
    recordings: *std.ArrayList(ActiveRecording),
) !AppendResult {
    try domain.validateSessionName(session_name);
    const seq = try appendTapEvent(allocator, io, state_dir, session_name, pane_id, output);

    var stopped: usize = 0;
    var index: usize = 0;
    while (index < recordings.items.len) {
        if (recordings.items[index].pane_id.len > 0 and !std.mem.eql(u8, recordings.items[index].pane_id, pane_id)) {
            index += 1;
            continue;
        }
        appendAsciicastEvent(allocator, io, recordings.items[index], output) catch |err| switch (err) {
            error.NoSpaceLeft => {
                if (recordings.items[index].policy == .error_back) return error.NoSpaceLeft;
                const stopped_recording = recordings.swapRemove(index);
                stopped_recording.deinit(allocator);
                stopped += 1;
                continue;
            },
            else => |e| return e,
        };
        index += 1;
    }

    return .{ .seq = seq, .stopped_recordings = stopped };
}

pub fn writeRecordingStartJson(
    writer: *Io.Writer,
    session_name: []const u8,
    result: StartRecordingResult,
    request_id: []const u8,
    seq: u64,
) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"session\":");
    try proto.writeJsonString(writer, session_name);
    try writer.writeAll(",\"recording_id\":");
    try proto.writeJsonString(writer, result.recording.id);
    try writer.writeAll(",\"pane_id\":");
    if (result.recording.pane_id.len == 0) {
        try writer.writeAll("null");
    } else {
        try proto.writeJsonString(writer, result.recording.pane_id);
    }
    try writer.writeAll(",\"path\":");
    try proto.writeJsonString(writer, result.recording.path);
    try writer.writeAll(",\"format\":\"asciicast-v2\",\"disk_full_policy\":");
    try proto.writeJsonString(writer, result.recording.policy.label());
    try writer.print(",\"file_mode_octal\":\"{o:0>3}\",\"directory_mode_octal\":\"{o:0>3}\",\"directory\":", .{
        result.file_mode,
        result.dir_mode,
    });
    try proto.writeJsonString(writer, result.dir_path);
    try writer.writeAll("},\"request_id\":");
    try proto.writeJsonString(writer, request_id);
    try writer.print(",\"seq\":{d}}}\n", .{seq});
}

pub fn writeRecordingStopJson(
    writer: *Io.Writer,
    session_name: []const u8,
    recording: ActiveRecording,
    request_id: []const u8,
    seq: u64,
) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"session\":");
    try proto.writeJsonString(writer, session_name);
    try writer.writeAll(",\"recording_id\":");
    try proto.writeJsonString(writer, recording.id);
    try writer.writeAll(",\"pane_id\":");
    try proto.writeJsonString(writer, recording.pane_id);
    try writer.writeAll(",\"path\":");
    try proto.writeJsonString(writer, recording.path);
    try writer.writeAll(",\"state\":\"stopped\"},\"request_id\":");
    try proto.writeJsonString(writer, request_id);
    try writer.print(",\"seq\":{d}}}\n", .{seq});
}

pub fn writeTapOpenJson(
    allocator: Allocator,
    io: Io,
    writer: *Io.Writer,
    state_dir: []const u8,
    session_name: []const u8,
    tap_id: []const u8,
    pane_id: []const u8,
    request_id: []const u8,
    seq: u64,
) !void {
    const events = try readTapEventsFrom(allocator, io, state_dir, session_name, pane_id, 0);
    defer allocator.free(events);
    const back_pressure: BackPressure = .{};

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"session\":");
    try proto.writeJsonString(writer, session_name);
    try writer.writeAll(",\"tap_id\":");
    try proto.writeJsonString(writer, tap_id);
    try writer.writeAll(",\"pane_id\":");
    try proto.writeJsonString(writer, pane_id);
    try writer.print(",\"back_pressure\":{{\"max_pending_events\":{d},\"local\":", .{back_pressure.max_pending_events});
    try proto.writeJsonString(writer, back_pressure.local);
    try writer.writeAll(",\"remote\":");
    try proto.writeJsonString(writer, back_pressure.remote);
    try writer.writeAll(",\"ordering\":");
    try proto.writeJsonString(writer, back_pressure.ordering);
    try writer.writeAll("},\"events\":[");

    var first = true;
    var lines = std.mem.splitScalar(u8, events, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\n\t").len == 0) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll(line);
    }

    try writer.writeAll("]},\"request_id\":");
    try proto.writeJsonString(writer, request_id);
    try writer.print(",\"seq\":{d}}}\n", .{seq});
}

pub fn writeTapCloseJson(
    allocator: Allocator,
    io: Io,
    writer: *Io.Writer,
    state_dir: []const u8,
    session_name: []const u8,
    tap: ActiveTap,
    request_id: []const u8,
    seq: u64,
) !void {
    const events = try readTapEventsFrom(allocator, io, state_dir, session_name, tap.pane_id, tap.start_seq);
    defer allocator.free(events);
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"session\":");
    try proto.writeJsonString(writer, session_name);
    try writer.writeAll(",\"tap_id\":");
    try proto.writeJsonString(writer, tap.id);
    try writer.writeAll(",\"pane_id\":");
    try proto.writeJsonString(writer, tap.pane_id);
    try writer.writeAll(",\"state\":\"closed\",\"events\":[");
    try writeRawNdjsonArray(writer, events);
    try writer.writeAll("]},\"request_id\":");
    try proto.writeJsonString(writer, request_id);
    try writer.print(",\"seq\":{d}}}\n", .{seq});
}

pub fn openTap(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    session_name: []const u8,
    pane_id: []const u8,
    next_tap_index: usize,
) !ActiveTap {
    try domain.validateSessionName(session_name);
    try validateRelativeId(pane_id);
    const tap_id = try std.fmt.allocPrint(allocator, "tap-{d}", .{next_tap_index});
    errdefer allocator.free(tap_id);
    return .{
        .id = tap_id,
        .start_seq = try currentTapSeq(allocator, io, state_dir, session_name),
        .pane_id = try allocator.dupe(u8, pane_id),
    };
}

pub fn closeTap(taps: *std.ArrayList(ActiveTap), tap_id: []const u8) ?ActiveTap {
    for (taps.items, 0..) |tap, index| {
        if (std.mem.eql(u8, tap.id, tap_id)) return taps.swapRemove(index);
    }
    return null;
}

pub fn writeObserveError(writer: *Io.Writer, seq: u64, code: []const u8, detail: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":false,\"error\":{\"code\":");
    try proto.writeJsonString(writer, code);
    try writer.writeAll(",\"message\":\"observability request failed\",\"detail\":");
    try proto.writeJsonString(writer, detail);
    try writer.print(",\"retryable\":false}},\"request_id\":\"control-socket\",\"seq\":{d}}}\n", .{seq});
}

pub fn modeOf(io: Io, path: []const u8) !u16 {
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    return @intCast(stat.permissions.toMode() & 0o777);
}

fn appendTapEvent(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    session_name: []const u8,
    pane_id: []const u8,
    output: []const u8,
) !u64 {
    const path = try tapEventPath(allocator, state_dir, session_name);
    defer allocator.free(path);
    const existing = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => |e| return e,
    };
    defer allocator.free(existing);

    const seq = countCompleteLines(existing) + 1;
    var line: Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    const writer = &line.writer;
    try writer.writeAll("{\"seq\":");
    try writer.print("{d}", .{seq});
    try writer.writeAll(",\"kind\":\"pty_output\",\"session\":");
    try proto.writeJsonString(writer, session_name);
    if (pane_id.len > 0) {
        try writer.writeAll(",\"pane_id\":");
        try proto.writeJsonString(writer, pane_id);
    }
    try writer.writeAll(",\"bytes\":");
    try proto.writeJsonString(writer, output);
    try writer.writeAll("}\n");
    try appendFile(io, path, line.written(), .fromMode(0o600));
    return seq;
}

fn readTapEventsFrom(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    session_name: []const u8,
    pane_id: []const u8,
    after_seq: u64,
) ![]u8 {
    const events = try readTapEvents(allocator, io, state_dir, session_name);
    defer allocator.free(events);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var lines = std.mem.splitScalar(u8, events, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\n\t").len == 0) continue;
        const seq = parseEventSeq(line) orelse continue;
        if (seq <= after_seq) continue;
        if (pane_id.len > 0 and !eventMatchesPane(line, pane_id)) continue;
        try output.appendSlice(allocator, line);
        try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}

fn appendAsciicastEvent(
    allocator: Allocator,
    io: Io,
    recording: ActiveRecording,
    output: []const u8,
) !void {
    var line: Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    const writer = &line.writer;
    const elapsed_ns = try elapsedSince(recording.started_at_ns);
    try writer.writeAll("[");
    try writeElapsedSeconds(writer, elapsed_ns);
    try writer.writeAll(",\"o\",");
    try proto.writeJsonString(writer, output);
    try writer.writeAll("]\n");
    try appendFile(io, recording.path, line.written(), .fromMode(0o600));
}

fn monotonicNowNs() !i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return error.ClockUnavailable;
    const seconds: i128 = @intCast(ts.sec);
    const nanos: i128 = @intCast(ts.nsec);
    return seconds * std.time.ns_per_s + nanos;
}

fn elapsedSince(started_at_ns: i128) !i128 {
    const now_ns = try monotonicNowNs();
    if (now_ns <= started_at_ns) return 0;
    return now_ns - started_at_ns;
}

fn writeElapsedSeconds(writer: *Io.Writer, elapsed_ns: i128) !void {
    const clamped_ns: u128 = @intCast(@max(elapsed_ns, 0));
    const ns_per_s: u128 = std.time.ns_per_s;
    const seconds = clamped_ns / ns_per_s;
    const nanos = clamped_ns % ns_per_s;
    try writer.print("{d}.{d:0>9}", .{ seconds, nanos });
}

fn appendFile(io: Io, path: []const u8, data: []const u8, permissions: Io.File.Permissions) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .permissions = permissions,
    });
    defer file.close(io);
    try file.setPermissions(io, permissions);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, data, stat.size);
    try file.sync(io);
}

fn readTapEvents(allocator: Allocator, io: Io, state_dir: []const u8, session_name: []const u8) ![]u8 {
    const path = try tapEventPath(allocator, state_dir, session_name);
    defer allocator.free(path);
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => |e| return e,
    };
}

fn currentTapSeq(allocator: Allocator, io: Io, state_dir: []const u8, session_name: []const u8) !u64 {
    const events = try readTapEvents(allocator, io, state_dir, session_name);
    defer allocator.free(events);
    return countCompleteLines(events);
}

fn tapEventPath(allocator: Allocator, state_dir: []const u8, session_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sessions/{s}/tap-events.ndjson", .{ state_dir, session_name });
}

fn ensurePrivateDirectory(io: Io, dir_path: []const u8) !void {
    _ = try Io.Dir.cwd().createDirPathStatus(io, dir_path, .fromMode(0o700));
    try Io.Dir.cwd().setFilePermissions(io, dir_path, .fromMode(0o700), .{});
}

fn recordingDirPath(allocator: Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.dirname(path)) |dirname| {
        if (dirname.len > 0) return allocator.dupe(u8, dirname);
    }
    return allocator.dupe(u8, ".");
}

fn countCompleteLines(bytes: []const u8) u64 {
    var count: u64 = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn writeRawNdjsonArray(writer: *Io.Writer, events: []const u8) !void {
    var first = true;
    var lines = std.mem.splitScalar(u8, events, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\n\t").len == 0) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll(line);
    }
}

fn parseEventSeq(line: []const u8) ?u64 {
    const needle = "\"seq\":";
    const start = (std.mem.indexOf(u8, line, needle) orelse return null) + needle.len;
    var end = start;
    while (end < line.len and line[end] >= '0' and line[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, line[start..end], 10) catch null;
}

fn eventMatchesPane(line: []const u8, pane_id: []const u8) bool {
    if (pane_id.len == 0) return true;
    return std.mem.indexOf(u8, line, pane_id) != null;
}

fn validateRelativeId(value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidIdentifier;
}

fn validateRecordingPath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidRecordingPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidRecordingPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.InvalidRecordingPath;
    }
}

test "recording_permissions creates private asciicast file and directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = ".zig-cache/minimux-observe-recording-permissions";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    const path = root ++ "/recordings/session.cast";
    var result = try startRecording(allocator, io, root, "alpha", "pane-1", path, 1, .error_back);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 0o600), result.file_mode);
    try std.testing.expectEqual(@as(u16, 0o700), result.dir_mode);

    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "{\"version\":2"));
}

test "tap events are ordered and filterable from subscriber start" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = ".zig-cache/minimux-observe-tap-ordering";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root ++ "/sessions/alpha");

    var recordings: std.ArrayList(ActiveRecording) = .empty;
    defer recordings.deinit(allocator);
    const tap = try openTap(allocator, io, root, "alpha", "pane-1", 1);
    defer tap.deinit(allocator);

    _ = try appendOutputEvent(allocator, io, root, "alpha", "pane-1", "first\n", &recordings);
    _ = try appendOutputEvent(allocator, io, root, "alpha", "pane-1", "second\n", &recordings);

    const events = try readTapEventsFrom(allocator, io, root, "alpha", tap.pane_id, tap.start_seq);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"seq\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"seq\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "second") != null);
}
