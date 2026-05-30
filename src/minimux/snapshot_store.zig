const std = @import("std");
const domain = @import("domain.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const magic = "MINIMUXSNAP\x00";
const version: u16 = 1;
const header_len = magic.len + 2 + 1 + 8 + 8 + 4;

pub const SnapshotRecord = struct {
    daemon_pid: i64,
    command_count: usize,
    recovery_state: domain.RecoveryState,
    visible_text: []const u8,
};

pub const StoredSnapshot = struct {
    daemon_pid: i64,
    command_count: usize,
    recovery_state: domain.RecoveryState,
    visible_text: []u8,

    pub fn deinit(snapshot: StoredSnapshot, allocator: Allocator) void {
        allocator.free(snapshot.visible_text);
    }
};

pub const ReadError = error{CorruptSnapshot} || anyerror;

pub fn writeSnapshot(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
    record: SnapshotRecord,
) !void {
    try domain.validateSessionName(name);
    try ensureSessionDir(allocator, io, state_dir, name);
    const target = try sessionPath(allocator, state_dir, name, "snapshot.bin");
    defer allocator.free(target);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{target});
    defer allocator.free(tmp);

    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll(magic);
    try writer.writeInt(u16, version, .little);
    try writer.writeByte(domain.recoveryByte(record.recovery_state));
    try writer.writeInt(i64, record.daemon_pid, .little);
    try writer.writeInt(u64, @intCast(record.command_count), .little);
    try writer.writeInt(u32, @intCast(record.visible_text.len), .little);
    try writer.writeAll(record.visible_text);

    var file = try Io.Dir.cwd().createFile(io, tmp, .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, output.written());
    try file.sync(io);
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), target, io);
}

pub fn readSnapshot(
    allocator: Allocator,
    io: Io,
    state_dir: []const u8,
    name: []const u8,
) ReadError!StoredSnapshot {
    const path = try sessionPath(allocator, state_dir, name, "snapshot.bin");
    defer allocator.free(path);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    if (bytes.len < header_len) return error.CorruptSnapshot;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.CorruptSnapshot;
    var index: usize = magic.len;
    const stored_version = std.mem.readInt(u16, bytes[index..][0..2], .little);
    index += 2;
    if (stored_version != version) return error.CorruptSnapshot;
    const recovery_state = try domain.recoveryStateFromByte(bytes[index]);
    index += 1;
    const daemon_pid = std.mem.readInt(i64, bytes[index..][0..8], .little);
    index += 8;
    const command_count_u64 = std.mem.readInt(u64, bytes[index..][0..8], .little);
    index += 8;
    const visible_len = std.mem.readInt(u32, bytes[index..][0..4], .little);
    index += 4;
    if (bytes.len != index + visible_len) return error.CorruptSnapshot;
    return .{
        .daemon_pid = daemon_pid,
        .command_count = @intCast(command_count_u64),
        .recovery_state = recovery_state,
        .visible_text = try allocator.dupe(u8, bytes[index..]),
    };
}

pub fn snapshotPath(allocator: Allocator, state_dir: []const u8, name: []const u8) ![]u8 {
    return sessionPath(allocator, state_dir, name, "snapshot.bin");
}

fn ensureSessionDir(allocator: Allocator, io: Io, state_dir: []const u8, name: []const u8) !void {
    const sessions_dir = try std.fmt.allocPrint(allocator, "{s}/sessions/{s}", .{ state_dir, name });
    defer allocator.free(sessions_dir);
    try Io.Dir.cwd().createDirPath(io, sessions_dir);
}

fn sessionPath(allocator: Allocator, state_dir: []const u8, name: []const u8, file_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sessions/{s}/{s}", .{ state_dir, name, file_name });
}

test "atomic_snapshot writes binary snapshot and rejects corruption" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const state_dir = ".zig-cache/minimux-snapshot-store-test";
    Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, state_dir) catch {};

    try writeSnapshot(allocator, io, state_dir, "snap", .{
        .daemon_pid = 1234,
        .command_count = 2,
        .recovery_state = .clean,
        .visible_text = "$ echo hi\nhi\n",
    });
    const stored = try readSnapshot(allocator, io, state_dir, "snap");
    defer stored.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 1234), stored.daemon_pid);
    try std.testing.expectEqual(@as(usize, 2), stored.command_count);
    try std.testing.expectEqual(domain.RecoveryState.clean, stored.recovery_state);
    try std.testing.expectEqualStrings("$ echo hi\nhi\n", stored.visible_text);

    const path = try snapshotPath(allocator, state_dir, "snap");
    defer allocator.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "corrupt" });
    try std.testing.expectError(error.CorruptSnapshot, readSnapshot(allocator, io, state_dir, "snap"));
}
