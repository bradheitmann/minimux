const std = @import("std");
const minimux = @import("minimux");

test "session lifecycle metadata supports list attach and terminate" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-session-lifecycle-test";
    std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    const argv = [_][]const u8{"bash"};
    try minimux.session.create(allocator, io, state_dir, "alpha", 99999997, &argv);

    const list_before = try minimux.session.listSessions(allocator, io, state_dir);
    defer list_before.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list_before.items.len);
    try std.testing.expectEqualStrings("alpha", list_before.items[0].name);
    try std.testing.expect(std.mem.startsWith(u8, list_before.items[0].control_socket, "/tmp/minimux-"));
    try std.testing.expect(std.mem.endsWith(u8, list_before.items[0].control_socket, "-alpha.sock"));
    try std.testing.expect(std.mem.endsWith(u8, list_before.items[0].log_path, "/sessions/alpha/daemon.log"));

    const attached = try minimux.session.inspect(allocator, io, state_dir, "alpha");
    defer attached.deinit(allocator);
    try std.testing.expectEqualStrings("alpha", attached.name);
    try std.testing.expectEqualStrings("running", attached.lifecycle_state);

    const terminated = try minimux.session.terminate(allocator, io, state_dir, "alpha");
    defer terminated.deinit(allocator);
    try std.testing.expectEqualStrings("terminated", terminated.lifecycle_state);
    try std.testing.expect(!terminated.daemon_alive);
}

test "session_isolation tracks independent daemon status" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-session-isolation-test";
    std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    const argv = [_][]const u8{"bash"};
    try minimux.session.create(allocator, io, state_dir, "survivor", @intCast(std.posix.system.getpid()), &argv);
    try minimux.session.create(allocator, io, state_dir, "killed", 99999996, &argv);

    const sessions = try minimux.session.listSessions(allocator, io, state_dir);
    defer sessions.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), sessions.items.len);

    var saw_survivor = false;
    var saw_killed = false;
    for (sessions.items) |info| {
        if (std.mem.eql(u8, info.name, "survivor")) {
            saw_survivor = true;
            try std.testing.expect(info.daemon_alive);
        }
        if (std.mem.eql(u8, info.name, "killed")) {
            saw_killed = true;
            try std.testing.expect(!info.daemon_alive);
        }
    }

    try std.testing.expect(saw_survivor);
    try std.testing.expect(saw_killed);
}
