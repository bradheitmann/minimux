const std = @import("std");
const cli = @import("minimux_cli");
const minimux = @import("minimux");

test "local CLI health and error envelopes carry jsonrpc" {
    const allocator = std.testing.allocator;

    var health: std.Io.Writer.Allocating = .init(allocator);
    defer health.deinit();
    try cli.writeHealthJson(&health.writer);
    try std.testing.expect(std.mem.indexOf(u8, health.written(), "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, health.written(), "\"request_id\":\"local-cli\"") != null);

    var daemon_error: std.Io.Writer.Allocating = .init(allocator);
    defer daemon_error.deinit();
    try cli.writeJsonError(&daemon_error.writer, "error.DaemonNotRunning", "alpha");
    try std.testing.expect(std.mem.indexOf(u8, daemon_error.written(), "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, daemon_error.written(), "\"message\":\"daemon is not running for the requested session\"") != null);

    var session_error: std.Io.Writer.Allocating = .init(allocator);
    defer session_error.deinit();
    try cli.writeJsonError(&session_error.writer, "error.SessionNotFound", "beta");
    try std.testing.expect(std.mem.indexOf(u8, session_error.written(), "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_error.written(), "\"message\":\"session was not found\"") != null);

    try std.testing.expect(!std.mem.eql(
        u8,
        cli.errorMessageForCode("error.DaemonNotRunning"),
        cli.errorMessageForCode("error.SessionNotFound"),
    ));
}

test "record start response emits null pane_id for session scoped recordings" {
    const allocator = std.testing.allocator;

    const result: minimux.observe.StartRecordingResult = .{
        .recording = .{
            .id = try allocator.dupe(u8, "rec-1"),
            .pane_id = try allocator.dupe(u8, ""),
            .path = try allocator.dupe(u8, ".zig-cache/cli-envelope.cast"),
            .policy = .error_back,
            .started_at_ns = 0,
        },
        .dir_path = try allocator.dupe(u8, ".zig-cache"),
        .file_mode = 0o600,
        .dir_mode = 0o700,
    };
    defer result.deinit(allocator);

    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    try minimux.observe.writeRecordingStartJson(&json.writer, "alpha", result, "test", 31);

    try std.testing.expect(std.mem.indexOf(u8, json.written(), "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.written(), "\"pane_id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.written(), "\"pane_id\":\"\"") == null);
}

test "generic unsupported-method text is not returned by known errors" {
    try std.testing.expect(!std.mem.eql(
        u8,
        cli.errorMessageForCode("error.UnsupportedMethod"),
        "unsupported method or command",
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        cli.errorMessageForCode("error.DaemonNotRunning"),
        "unsupported method or command",
    ));
}
