const std = @import("std");
const minimux = @import("minimux");

test "pty lifecycle creates lists resizes closes pane metadata" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-pty-lifecycle-test";
    std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    const argv = [_][]const u8{"bash"};
    try minimux.session.create(allocator, io, state_dir, "pty-life", @intCast(std.posix.system.getpid()), &argv);

    const created = try minimux.session.createPane(allocator, io, state_dir, "pty-life", "bash", .{ .cols = 90, .rows = 33 });
    defer created.deinit(allocator);
    try std.testing.expectEqualStrings("pty-life", created.session);
    try std.testing.expectEqualStrings("pane-1", created.local_id);
    try std.testing.expectEqualStrings("open", created.state);
    try std.testing.expectEqual(@as(u16, 90), created.dimensions.cols);
    try std.testing.expectEqual(@as(u16, 33), created.dimensions.rows);

    const panes = try minimux.session.listPanes(allocator, io, state_dir, "pty-life");
    defer panes.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), panes.items.len);

    const resized = try minimux.session.resizePane(allocator, io, state_dir, "pty-life", "pane-1", .{ .cols = 120, .rows = 40 });
    defer resized.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 120), resized.dimensions.cols);
    try std.testing.expectEqual(@as(u16, 40), resized.dimensions.rows);

    try minimux.session.appendPaneResult(allocator, io, state_dir, "pty-life", "pane-1", "printf ok", "ok\n", 0);
    const visible = try minimux.session.paneVisibleText(allocator, io, state_dir, "pty-life", "pane-1");
    defer allocator.free(visible);
    try std.testing.expect(std.mem.containsAtLeast(u8, visible, 1, "printf ok"));
    try std.testing.expect(std.mem.containsAtLeast(u8, visible, 1, "ok"));

    const closed = try minimux.session.closePane(allocator, io, state_dir, "pty-life", "pane-1");
    defer closed.deinit(allocator);
    try std.testing.expectEqualStrings("closed", closed.state);
    try std.testing.expectError(
        error.PaneClosed,
        minimux.session.resizePane(allocator, io, state_dir, "pty-life", "pane-1", .{ .cols = 80, .rows = 24 }),
    );
}

test "byte_input_boundaries preserve escaped control bytes" {
    const allocator = std.testing.allocator;
    const decoded = try minimux.pty.decodeControlTokens(allocator, "alpha<TAB>beta<CR><ESC>[31m");
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(
        u8,
        "alpha\tbeta\n\x1b[31m",
        decoded,
    );

    const literal = try minimux.pty.decodeControlTokens(allocator, "two words 'quoted' $dollar");
    defer allocator.free(literal);
    try std.testing.expectEqualStrings("two words 'quoted' $dollar", literal);
}

test "pty stream pair carries child-visible output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var opened = try minimux.pty.open(.{ .cols = 90, .rows = 30 });
    defer opened.close(io);

    try opened.slave.writeStreamingAll(io, "stream-ok\n");
    const output = try minimux.pty.drainOutput(allocator, opened.master, 100, 25, 4096);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "stream-ok") != null);
}

test "pty stream pair preserves non-shell byte input" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var opened = try minimux.pty.open(.{ .cols = 90, .rows = 30 });
    defer opened.close(io);

    const argv = [_][]const u8{"cat"};
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .{ .file = opened.slave },
        .stdout = .{ .file = opened.slave },
        .stderr = .{ .file = opened.slave },
    });
    opened.closeSlave(io);
    defer {
        if (child.id) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        _ = child.wait(io) catch {};
    }

    const output = try minimux.pty.writeInputAndDrain(allocator, io, opened.master, "cat-byte-ok\n");
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "cat-byte-ok") != null);
}
