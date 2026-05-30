const std = @import("std");
const minimux = @import("minimux");

test "prototype session recovery model includes notification source" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-prototype-test";
    std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    const argv = [_][]const u8{"bash"};
    try minimux.session.create(allocator, io, state_dir, "prototype", 99999998, &argv);
    try minimux.session.appendCommandResult(allocator, io, state_dir, "prototype", "echo hi", "hi\n", "", 0);

    const snap = try minimux.session.snapshot(allocator, io, state_dir, "prototype");
    defer minimux.session.destroySnapshot(allocator, snap);

    try std.testing.expectEqual(minimux.domain.RecoveryState.recovered, snap.recovery_state);
    try std.testing.expect(!snap.daemon_alive);
    try std.testing.expectEqual(@as(usize, 1), snap.command_count);
    try std.testing.expect(std.mem.containsAtLeast(u8, snap.visible_text, 1, "echo hi"));
    try std.testing.expect(std.mem.containsAtLeast(u8, snap.visible_text, 1, "hi"));
}
