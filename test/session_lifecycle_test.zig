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
    const expected_socket = try minimux.session.controlSocketPath(allocator, io, state_dir, "alpha");
    defer allocator.free(expected_socket);
    try std.testing.expectEqualStrings(expected_socket, list_before.items[0].control_socket);
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

test "control socket identity includes the canonical project root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const a = ".zig-cache/socket-project-a/.minimux-state";
    const b = ".zig-cache/socket-project-b/.minimux-state";
    try std.Io.Dir.cwd().createDirPath(io, a);
    try std.Io.Dir.cwd().createDirPath(io, b);
    defer std.Io.Dir.cwd().deleteTree(io, ".zig-cache/socket-project-a") catch {};
    defer std.Io.Dir.cwd().deleteTree(io, ".zig-cache/socket-project-b") catch {};
    const first = try minimux.session.controlSocketPath(allocator, io, a, "same");
    defer allocator.free(first);
    const second = try minimux.session.controlSocketPath(allocator, io, b, "same");
    defer allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, a, allocator);
    defer allocator.free(absolute);
    const alias = try minimux.session.controlSocketPath(allocator, io, absolute, "same");
    defer allocator.free(alias);
    try std.testing.expectEqualStrings(first, alias);
}

test "partial control clients do not block complete clients" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = ".zig-cache/control-inbox-test";
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const path = try minimux.session.controlSocketPath(allocator, io, root, "inbox");
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var address = try std.Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var inbox: minimux.daemon.ControlInbox = .{};
    defer inbox.deinit(allocator, io);
    var partial = try address.connect(io);
    defer partial.close(io);
    _ = std.c.send(partial.socket.handle, "{", 1, 0);
    try std.testing.expect((try inbox.next(allocator, io, &server)) == null);
    var complete = try address.connect(io);
    defer complete.close(io);
    const message = "{\"method\":\"system.health\"}\n";
    _ = std.c.send(complete.socket.handle, message.ptr, message.len, 0);
    const ready = (try inbox.next(allocator, io, &server)) orelse return error.CompleteClientBlocked;
    defer ready.stream.close(io);
    defer allocator.free(ready.text);
    try std.testing.expectEqualStrings(message[0 .. message.len - 1], ready.text);
    try std.testing.expectEqual(@as(usize, 1), inbox.pending.items.len);
    inbox.pending.items[0].deadline = 0;
    try std.testing.expect((try inbox.next(allocator, io, &server)) == null);
    try std.testing.expectEqual(@as(usize, 0), inbox.pending.items.len);
}

test "control response writer rejects an expired absolute deadline" {
    var buffer: [16]u8 = undefined;
    var writer = minimux.daemon.DeadlineWriter.init(std.testing.io, -1, &buffer);
    writer.deadline = 0;
    try writer.interface.writeAll("response");
    try std.testing.expectError(error.WriteFailed, writer.interface.flush());
}

test "control root is prepared before first daemon startup" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = ".zig-cache/first-control-root/nested/state";
    std.Io.Dir.cwd().deleteTree(io, ".zig-cache/first-control-root") catch {};
    defer std.Io.Dir.cwd().deleteTree(io, ".zig-cache/first-control-root") catch {};
    const canonical = try minimux.session.prepareStateRoot(allocator, io, root);
    defer allocator.free(canonical);
    try std.testing.expect(std.fs.path.isAbsolute(canonical));
    const path = try minimux.session.controlSocketPath(allocator, io, root, "first");
    defer allocator.free(path);
    const alias = try minimux.session.controlSocketPath(allocator, io, canonical, "first");
    defer allocator.free(alias);
    try std.testing.expectEqualStrings(path, alias);
}

test "control peer identity fails closed for an invalid socket" {
    try std.testing.expect(!minimux.session.sameControlUser(-1));
}
