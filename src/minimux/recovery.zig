const std = @import("std");
const domain = @import("domain.zig");
const journal = @import("journal.zig");
const snapshot_store = @import("snapshot_store.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Report = struct {
    recovery_state: domain.RecoveryState,
    daemon_pid: i64,
    command_count: usize,
    visible_text: []u8,
    replayed_entries: usize,
    child_processes_marked_dead: bool,
    session_recovered_emitted: bool,

    pub fn deinit(report: Report, allocator: Allocator) void {
        allocator.free(report.visible_text);
    }
};

const JournalEntry = struct {
    kind: []const u8 = "",
    visible: ?[]const u8 = null,
};

pub fn recoverSession(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) !Report {
    var state: domain.RecoveryState = .recovered;
    var daemon_pid: i64 = 0;
    var command_count: usize = 0;
    var visible: []u8 = undefined;

    const stored = snapshot_store.readSnapshot(allocator, io, state_dir, name) catch |err| switch (err) {
        error.FileNotFound, error.CorruptSnapshot => blk: {
            state = .degraded_corrupt_snapshot;
            break :blk null;
        },
        else => |e| return e,
    };
    if (stored) |snapshot| {
        defer snapshot.deinit(allocator);
        daemon_pid = snapshot.daemon_pid;
        command_count = snapshot.command_count;
        visible = try allocator.dupe(u8, snapshot.visible_text);
    } else {
        visible = try allocator.dupe(u8, "");
    }
    errdefer allocator.free(visible);

    const journal_read = try journal.readComplete(allocator, io, state_dir, name);
    defer journal_read.deinit(allocator);
    if (journal_read.has_partial_final_line and state == .recovered) {
        state = .degraded_partial_journal;
    }

    var replayed: usize = 0;
    var command_entries: usize = 0;
    var replay_visible: std.ArrayList(u8) = .empty;
    defer replay_visible.deinit(allocator);
    var lines = std.mem.splitScalar(u8, journal_read.bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(JournalEntry, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        if (std.mem.eql(u8, parsed.value.kind, "command")) {
            replayed += 1;
            command_entries += 1;
            if (parsed.value.visible) |delta| try replay_visible.appendSlice(allocator, delta);
        } else if (std.mem.eql(u8, parsed.value.kind, "pane_input")) {
            replayed += 1;
        }
    }
    if (state == .degraded_corrupt_snapshot and replay_visible.items.len > 0) {
        allocator.free(visible);
        visible = try replay_visible.toOwnedSlice(allocator);
    }
    if (command_entries > command_count) command_count = command_entries;

    if (try missingRecordingFallback(allocator, io, state_dir, name)) {
        state = .degraded_missing_recording_fallback;
    }

    return .{
        .recovery_state = state,
        .daemon_pid = daemon_pid,
        .command_count = command_count,
        .visible_text = visible,
        .replayed_entries = replayed,
        .child_processes_marked_dead = true,
        .session_recovered_emitted = true,
    };
}

fn missingRecordingFallback(allocator: Allocator, io: Io, state_dir: []const u8, name: []const u8) !bool {
    const marker_path = try sessionPath(allocator, state_dir, name, "recording.fallback");
    defer allocator.free(marker_path);
    const marker = Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer allocator.free(marker);
    const fallback_path = std.mem.trim(u8, marker, " \r\n\t");
    if (fallback_path.len == 0) return true;
    _ = Io.Dir.cwd().statFile(io, fallback_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => |e| return e,
    };
    return false;
}

fn sessionPath(allocator: Allocator, state_dir: []const u8, name: []const u8, file_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sessions/{s}/{s}", .{ state_dir, name, file_name });
}

test "recovery replays journal and detects degraded states" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-recovery-module-test";
    Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    try snapshot_store.writeSnapshot(allocator, io, state_dir, "recover", .{
        .daemon_pid = 9999,
        .command_count = 1,
        .recovery_state = .clean,
        .visible_text = "$ echo old\nold\n",
    });
    _ = try journal.appendCommand(allocator, io, state_dir, "recover", 1, "echo old", "$ echo old\nold\n", 0, 1);
    _ = try journal.appendCommand(allocator, io, state_dir, "recover", 2, "echo new", "$ echo new\nnew\n", 0, 1);
    var report = try recoverSession(allocator, io, state_dir, "recover");
    defer report.deinit(allocator);
    try std.testing.expectEqual(domain.RecoveryState.recovered, report.recovery_state);
    try std.testing.expect(report.session_recovered_emitted);
    try std.testing.expect(report.child_processes_marked_dead);
    try std.testing.expectEqual(@as(usize, 2), report.replayed_entries);
    try std.testing.expectEqual(@as(usize, 2), report.command_count);

    _ = try journal.appendLine(allocator, io, state_dir, "recover", "{\"kind\":\"partial\"", 1, 3);
    var partial = try recoverSession(allocator, io, state_dir, "recover");
    defer partial.deinit(allocator);
    try std.testing.expectEqual(domain.RecoveryState.degraded_partial_journal, partial.recovery_state);

    const snapshot_path = try snapshot_store.snapshotPath(allocator, state_dir, "recover");
    defer allocator.free(snapshot_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = snapshot_path, .data = "corrupt" });
    var corrupt = try recoverSession(allocator, io, state_dir, "recover");
    defer corrupt.deinit(allocator);
    try std.testing.expectEqual(domain.RecoveryState.degraded_corrupt_snapshot, corrupt.recovery_state);

    const fallback_marker = try sessionPath(allocator, state_dir, "recover", "recording.fallback");
    defer allocator.free(fallback_marker);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fallback_marker, .data = ".zig-cache/missing-recording.ndjson\n" });
    var missing_recording = try recoverSession(allocator, io, state_dir, "recover");
    defer missing_recording.deinit(allocator);
    try std.testing.expectEqual(domain.RecoveryState.degraded_missing_recording_fallback, missing_recording.recovery_state);
}
