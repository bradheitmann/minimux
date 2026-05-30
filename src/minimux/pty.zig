const domain = @import("domain.zig");
const std = @import("std");

const builtin = @import("builtin");
const Io = std.Io;

pub const PrototypePty = struct {
    dimensions: domain.Dimensions = .{},
    mode: []const u8 = "daemon-owned-pty",
};

extern "c" fn openpty(
    primary: *std.c.fd_t,
    replica: *std.c.fd_t,
    name: [*c]u8,
    termp: ?*std.posix.termios,
    winp: ?*std.posix.winsize,
) c_int;

pub const OpenedPty = struct {
    master: Io.File,
    slave: Io.File,
    master_closed: bool = false,
    slave_closed: bool = false,

    pub fn closeSlave(opened: *OpenedPty, io: Io) void {
        if (opened.slave_closed) return;
        opened.slave.close(io);
        opened.slave_closed = true;
    }

    pub fn closeMaster(opened: *OpenedPty, io: Io) void {
        if (opened.master_closed) return;
        opened.master.close(io);
        opened.master_closed = true;
    }

    pub fn close(opened: *OpenedPty, io: Io) void {
        opened.closeSlave(io);
        opened.closeMaster(io);
    }
};

pub const PaneState = enum {
    open,
    closed,

    pub fn label(state: PaneState) []const u8 {
        return switch (state) {
            .open => "open",
            .closed => "closed",
        };
    }
};

pub const PaneRef = struct {
    session: []const u8,
    local_id: []const u8,

    pub fn deinit(ref: PaneRef, allocator: std.mem.Allocator) void {
        allocator.free(ref.session);
        allocator.free(ref.local_id);
    }
};

pub fn defaultPrototypePty() PrototypePty {
    return .{};
}

pub fn open(dimensions: domain.Dimensions) !OpenedPty {
    var primary: std.c.fd_t = -1;
    var replica: std.c.fd_t = -1;
    var window: std.posix.winsize = .{
        .row = dimensions.rows,
        .col = dimensions.cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    if (openpty(&primary, &replica, null, null, &window) != 0) return error.OpenPtyFailed;
    return .{
        .master = .{ .handle = primary, .flags = .{ .nonblocking = false } },
        .slave = .{ .handle = replica, .flags = .{ .nonblocking = false } },
    };
}

pub fn resize(master: Io.File, dimensions: domain.Dimensions) !void {
    if (dimensions.cols == 0 or dimensions.rows == 0) return error.InvalidPaneDimensions;
    var window: std.posix.winsize = .{
        .row = dimensions.rows,
        .col = dimensions.cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    const request: u32 = switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => 0x80087467,
        else => @intCast(std.posix.T.IOCSWINSZ),
    };
    const request_arg: c_int = @bitCast(request);
    if (std.c.ioctl(master.handle, request_arg, &window) != 0) return error.ResizePtyFailed;
}

pub fn writeInputAndDrain(
    allocator: std.mem.Allocator,
    io: Io,
    master: Io.File,
    input: []const u8,
) ![]u8 {
    try master.writeStreamingAll(io, input);
    return drainOutput(allocator, master, 1000, 150, 1024 * 1024);
}

pub fn drainOutput(
    allocator: std.mem.Allocator,
    master: Io.File,
    first_timeout_ms: i32,
    idle_timeout_ms: i32,
    max_bytes: usize,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var timeout_ms = first_timeout_ms;
    while (output.items.len < max_bytes) {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = master.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&poll_fds, timeout_ms);
        if (ready == 0) break;
        if ((poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0 and
            (poll_fds[0].revents & std.posix.POLL.IN) == 0) break;
        if ((poll_fds[0].revents & std.posix.POLL.IN) == 0) break;

        var buffer: [4096]u8 = undefined;
        const remaining = @min(buffer.len, max_bytes - output.items.len);
        const count = try std.posix.read(master.handle, buffer[0..remaining]);
        if (count == 0) break;
        try output.appendSlice(allocator, buffer[0..count]);
        timeout_ms = idle_timeout_ms;
    }

    return output.toOwnedSlice(allocator);
}

pub fn decodeControlTokens(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < input.len) {
        if (std.mem.startsWith(u8, input[index..], "<CR>")) {
            try output.append(allocator, '\n');
            index += 4;
            continue;
        }
        if (std.mem.startsWith(u8, input[index..], "<TAB>")) {
            try output.append(allocator, '\t');
            index += 5;
            continue;
        }
        if (std.mem.startsWith(u8, input[index..], "<ESC>")) {
            try output.append(allocator, 0x1b);
            index += 5;
            continue;
        }
        try output.append(allocator, input[index]);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

pub fn validatePaneLocalId(local_id: []const u8) !void {
    if (local_id.len == 0) return error.EmptyPaneId;
    if (local_id.len > 64) return error.PaneIdTooLong;
    for (local_id) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return error.InvalidPaneId,
    };
}

pub fn parsePaneRef(
    allocator: std.mem.Allocator,
    pane_id: []const u8,
    fallback_session: []const u8,
) !PaneRef {
    if (std.mem.indexOfScalar(u8, pane_id, ':')) |separator| {
        const session = pane_id[0..separator];
        const local_id = pane_id[separator + 1 ..];
        try domain.validateSessionName(session);
        try validatePaneLocalId(local_id);
        return .{
            .session = try allocator.dupe(u8, session),
            .local_id = try allocator.dupe(u8, local_id),
        };
    }
    try domain.validateSessionName(fallback_session);
    try validatePaneLocalId(pane_id);
    return .{
        .session = try allocator.dupe(u8, fallback_session),
        .local_id = try allocator.dupe(u8, pane_id),
    };
}

pub fn writePaneId(
    writer: *std.Io.Writer,
    session: []const u8,
    local_id: []const u8,
) !void {
    try writer.writeAll("\"");
    try writer.writeAll(session);
    try writer.writeAll(":");
    try writer.writeAll(local_id);
    try writer.writeAll("\"");
}
