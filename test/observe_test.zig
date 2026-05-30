const std = @import("std");
const minimux = @import("minimux");

test "recording_permissions writes private asciicast output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = ".zig-cache/minimux-observe-test-recording";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/sessions/alpha");

    const path = root ++ "/recordings/pane.cast";
    var result = try minimux.observe.startRecording(allocator, io, root, "alpha", "pane-1", path, 1, .error_back);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 0o600), result.file_mode);
    try std.testing.expectEqual(@as(u16, 0o700), result.dir_mode);

    var recordings: std.ArrayList(minimux.observe.ActiveRecording) = .empty;
    defer {
        for (recordings.items) |recording| recording.deinit(allocator);
        recordings.deinit(allocator);
    }
    try recordings.append(allocator, result.recording);
    result.recording = .{
        .id = try allocator.dupe(u8, ""),
        .pane_id = try allocator.dupe(u8, ""),
        .path = try allocator.dupe(u8, ""),
        .policy = .error_back,
        .started_at_ns = 0,
    };

    _ = try minimux.observe.appendOutputEvent(allocator, io, root, "alpha", "pane-1", "hello-recording\n", &recordings);
    recordings.items[0].started_at_ns -= std.time.ns_per_ms;
    _ = try minimux.observe.appendOutputEvent(allocator, io, root, "alpha", "pane-1", "hello-again\n", &recordings);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "{\"version\":2"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"hello-recording\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"hello-again\\n\"") != null);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next();
    const first_line = lines.next() orelse return error.MissingFirstRecordingEvent;
    const second_line = lines.next() orelse return error.MissingSecondRecordingEvent;
    const first_ts = try parseAsciicastTimestamp(first_line);
    const second_ts = try parseAsciicastTimestamp(second_line);
    try std.testing.expect(first_ts >= 0);
    try std.testing.expect(second_ts > first_ts);
}

test "tap ordering policy returns monotonic events for subscriber window" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = ".zig-cache/minimux-observe-test-tap";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/sessions/alpha");

    var recordings: std.ArrayList(minimux.observe.ActiveRecording) = .empty;
    defer recordings.deinit(allocator);

    var tap = try minimux.observe.openTap(allocator, io, root, "alpha", "pane-1", 1);
    defer tap.deinit(allocator);
    _ = try minimux.observe.appendOutputEvent(allocator, io, root, "alpha", "pane-1", "first\n", &recordings);
    _ = try minimux.observe.appendOutputEvent(allocator, io, root, "alpha", "pane-1", "second\n", &recordings);

    var open_json: std.Io.Writer.Allocating = .init(allocator);
    defer open_json.deinit();
    try minimux.observe.writeTapOpenJson(allocator, io, &open_json.writer, root, "alpha", tap.id, tap.pane_id, "test", 1);
    try std.testing.expect(std.mem.indexOf(u8, open_json.written(), "\"local\":\"block_control_response_until_reader_accepts_event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_json.written(), "\"remote\":\"bounded_queue_close_slow_reader_on_overflow\"") != null);

    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    try minimux.observe.writeTapCloseJson(allocator, io, &json.writer, root, "alpha", tap, "test", 2);
    const text = json.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"seq\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"seq\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second") != null);
}

test "shell harness returns idle exited timeout and unknown states" {
    const idle = minimux.harness_shell.observe(.running, null, 5000);
    try std.testing.expectEqual(minimux.harness_shell.State.idle, idle.state);
    try std.testing.expect(idle.ok());

    const exited = minimux.harness_shell.observe(.exited, 23, 5000);
    try std.testing.expectEqual(minimux.harness_shell.State.exited, exited.state);
    try std.testing.expect(exited.ok());
    try std.testing.expectEqual(@as(?u8, 23), exited.exit_code);

    const timeout = minimux.harness_shell.observe(.running, null, 0);
    try std.testing.expectEqual(minimux.harness_shell.State.timeout, timeout.state);
    try std.testing.expect(!timeout.ok());
    try std.testing.expectEqualStrings("error.WaitIdleTimeout", timeout.errorCode());

    const unknown = minimux.harness_shell.observe(.unknown, null, 5000);
    try std.testing.expectEqual(minimux.harness_shell.State.unknown, unknown.state);
    try std.testing.expect(!unknown.ok());
    try std.testing.expect(std.mem.indexOf(u8, unknown.action, "snapshot") != null);
}

fn parseAsciicastTimestamp(line: []const u8) !f64 {
    if (line.len == 0 or line[0] != '[') return error.InvalidAsciicastEvent;
    const comma_index = std.mem.indexOfScalar(u8, line, ',') orelse return error.InvalidAsciicastEvent;
    return std.fmt.parseFloat(f64, line[1..comma_index]);
}
