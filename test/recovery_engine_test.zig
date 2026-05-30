const std = @import("std");
const minimux = @import("minimux");

test "recovery engine restores snapshot and replays complete journal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-recovery-engine-test";
    std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    const argv = [_][]const u8{"bash"};
    try minimux.session.create(allocator, io, state_dir, "engine", 99999997, &argv);
    try minimux.session.appendCommandResult(allocator, io, state_dir, "engine", "echo hi", "hi\n", "", 0);

    const snap = try minimux.session.snapshot(allocator, io, state_dir, "engine");
    defer minimux.session.destroySnapshot(allocator, snap);

    try std.testing.expectEqual(minimux.domain.RecoveryState.recovered, snap.recovery_state);
    try std.testing.expectEqual(@as(usize, 1), snap.command_count);
    try std.testing.expect(std.mem.containsAtLeast(u8, snap.visible_text, 1, "SESSION_RECOVERED") == false);
    try std.testing.expect(std.mem.containsAtLeast(u8, snap.visible_text, 1, "echo hi"));
    try std.testing.expect(std.mem.containsAtLeast(u8, snap.visible_text, 1, "hi"));
}

test "recovery engine exposes deterministic degraded states" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-recovery-degraded-test";
    std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    const argv = [_][]const u8{"bash"};
    try minimux.session.create(allocator, io, state_dir, "faults", 99999996, &argv);
    try minimux.session.appendCommandResult(allocator, io, state_dir, "faults", "echo first", "first\n", "", 0);
    _ = try minimux.journal.appendLine(allocator, io, state_dir, "faults", "{\"kind\":\"partial\"", 1, 3);
    var partial = try minimux.recovery.recoverSession(allocator, io, state_dir, "faults");
    defer partial.deinit(allocator);
    try std.testing.expectEqual(minimux.domain.RecoveryState.degraded_partial_journal, partial.recovery_state);
    try std.testing.expect(partial.session_recovered_emitted);
    try std.testing.expect(partial.child_processes_marked_dead);

    const snapshot_path = try minimux.snapshot_store.snapshotPath(allocator, state_dir, "faults");
    defer allocator.free(snapshot_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = snapshot_path, .data = "bad snapshot" });
    var corrupt = try minimux.recovery.recoverSession(allocator, io, state_dir, "faults");
    defer corrupt.deinit(allocator);
    try std.testing.expectEqual(minimux.domain.RecoveryState.degraded_corrupt_snapshot, corrupt.recovery_state);

    const fallback_path = try std.fmt.allocPrint(allocator, "{s}/sessions/faults/recording.fallback", .{state_dir});
    defer allocator.free(fallback_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fallback_path, .data = ".zig-cache/missing-recording-fallback.ndjson\n" });
    var missing_recording = try minimux.recovery.recoverSession(allocator, io, state_dir, "faults");
    defer missing_recording.deinit(allocator);
    try std.testing.expectEqual(minimux.domain.RecoveryState.degraded_missing_recording_fallback, missing_recording.recovery_state);
}

test "atomic_snapshot gate covers binary snapshot roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-atomic-snapshot-gate";
    std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    try minimux.snapshot_store.writeSnapshot(allocator, io, state_dir, "atomic", .{
        .daemon_pid = 42,
        .command_count = 7,
        .recovery_state = .clean,
        .visible_text = "$ true\n",
    });
    const stored = try minimux.snapshot_store.readSnapshot(allocator, io, state_dir, "atomic");
    defer stored.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 42), stored.daemon_pid);
    try std.testing.expectEqual(@as(usize, 7), stored.command_count);
    try std.testing.expectEqualStrings("$ true\n", stored.visible_text);
}
