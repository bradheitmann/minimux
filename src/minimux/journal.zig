const std = @import("std");
const domain = @import("domain.zig");
const proto = @import("proto.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const AppendResult = struct {
    offset: u64,
    synced: bool,
};

pub const ReadResult = struct {
    bytes: []u8,
    has_partial_final_line: bool,
    complete_line_count: usize,

    pub fn deinit(result: ReadResult, allocator: Allocator) void {
        allocator.free(result.bytes);
    }
};

pub fn appendCommand(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    seq: usize,
    command: []const u8,
    visible_delta: []const u8,
    exit_code: u8,
    sync_every: usize,
) !AppendResult {
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("{\"kind\":\"command\",\"seq\":");
    try writer.print("{d}", .{seq});
    try writer.writeAll(",\"command\":");
    try proto.writeJsonString(writer, command);
    try writer.writeAll(",\"visible\":");
    try proto.writeJsonString(writer, visible_delta);
    try writer.print(",\"exit_code\":{d}}}\n", .{exit_code});
    return appendLine(allocator, io, state_dir, name, output.written(), sync_every, seq);
}

pub fn appendPaneInput(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    pane_id: []const u8,
    exit_code: u8,
    sync_every: usize,
) !AppendResult {
    const seq = try countCompleteLines(allocator, io, state_dir, name) + 1;
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("{\"kind\":\"pane_input\",\"seq\":");
    try writer.print("{d}", .{seq});
    try writer.writeAll(",\"pane\":");
    try proto.writeJsonString(writer, pane_id);
    try writer.print(",\"exit_code\":{d}}}\n", .{exit_code});
    return appendLine(allocator, io, state_dir, name, output.written(), sync_every, seq);
}

pub fn appendLine(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    line: []const u8,
    sync_every: usize,
    seq: usize,
) !AppendResult {
    try domain.validateSessionName(name);
    try ensureSessionDir(allocator, io, state_dir, name);
    const path = try sessionPath(allocator, state_dir, name, "journal.ndjson");
    defer allocator.free(path);

    var file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    defer file.close(io);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, line, stat.size);
    const should_sync = sync_every <= 1 or seq % sync_every == 0;
    if (should_sync) try file.sync(io);
    return .{ .offset = stat.size, .synced = should_sync };
}

pub fn readComplete(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) !ReadResult {
    const path = try sessionPath(allocator, state_dir, name, "journal.ndjson");
    defer allocator.free(path);
    const raw = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{
            .bytes = try allocator.dupe(u8, ""),
            .has_partial_final_line = false,
            .complete_line_count = 0,
        },
        else => |e| return e,
    };
    errdefer allocator.free(raw);

    const has_partial = raw.len != 0 and raw[raw.len - 1] != '\n';
    const complete_len = if (has_partial) blk: {
        const last_newline = std.mem.lastIndexOfScalar(u8, raw, '\n') orelse 0;
        break :blk if (last_newline == 0) 0 else last_newline + 1;
    } else raw.len;
    if (complete_len != raw.len) {
        const complete = try allocator.dupe(u8, raw[0..complete_len]);
        allocator.free(raw);
        return .{
            .bytes = complete,
            .has_partial_final_line = has_partial,
            .complete_line_count = countLines(complete),
        };
    }
    return .{
        .bytes = raw,
        .has_partial_final_line = has_partial,
        .complete_line_count = countLines(raw),
    };
}

pub fn countCompleteLines(allocator: Allocator, io: Io, state_dir: []const u8, name: []const u8) !usize {
    const result = try readComplete(allocator, io, state_dir, name);
    defer result.deinit(allocator);
    return result.complete_line_count;
}

fn countLines(bytes: []const u8) usize {
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn ensureSessionDir(allocator: Allocator, io: Io, state_dir: []const u8, name: []const u8) !void {
    const sessions_dir = try std.fmt.allocPrint(allocator, "{s}/sessions/{s}", .{ state_dir, name });
    defer allocator.free(sessions_dir);
    try Io.Dir.cwd().createDirPath(io, sessions_dir);
}

fn sessionPath(allocator: Allocator, state_dir: []const u8, name: []const u8, file_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sessions/{s}/{s}", .{ state_dir, name, file_name });
}

test "journal append keeps complete lines and detects partial tail" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-journal-test";
    Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    const first = try appendCommand(allocator, io, state_dir, "journal", 1, "echo one", "$ echo one\none\n", 0, 2);
    try std.testing.expect(!first.synced);
    const second = try appendCommand(allocator, io, state_dir, "journal", 2, "echo two", "$ echo two\ntwo\n", 0, 2);
    try std.testing.expect(second.synced);
    _ = try appendLine(allocator, io, state_dir, "journal", "{\"kind\":\"partial\"", 1, 3);

    const read = try readComplete(allocator, io, state_dir, "journal");
    defer read.deinit(allocator);
    try std.testing.expect(read.has_partial_final_line);
    try std.testing.expectEqual(@as(usize, 2), read.complete_line_count);
    try std.testing.expect(std.mem.containsAtLeast(u8, read.bytes, 1, "echo one"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, read.bytes, 1, "partial"));
}
