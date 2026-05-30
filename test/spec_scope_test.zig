const std = @import("std");
const minimux = @import("minimux");

test "v0.1.0 public method surface is explicit" {
    const expected = [_][]const u8{
        "session.create",
        "session.attach",
        "session.list",
        "session.terminate",
        "pane.create",
        "pane.send",
        "pane.resize",
        "pane.snapshot",
        "pane.close",
        "agent.wait_idle",
        "record.start",
        "record.stop",
        "tap.open",
        "tap.close",
        "system.health",
    };

    for (expected) |method| {
        try std.testing.expect(minimux.hasPublicMethod(method));
    }
}

test "v0.1.0 boundary does not claim upstream ownership" {
    try std.testing.expect(minimux.isNonGoal("workflow scheduler"));
    try std.testing.expect(minimux.isNonGoal("sandbox enforcement engine"));
    try std.testing.expect(minimux.isNonGoal("operator-facing terminal interface"));
    try std.testing.expect(minimux.isNonGoal("plaintext remote transport"));
}

test "prototype command enum preserves kill-shot shape" {
    const commands = [_]minimux.PrototypeCommand{ .run, .send, .wait_idle, .snapshot };
    try std.testing.expectEqual(@as(usize, 4), commands.len);
}
