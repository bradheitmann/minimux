//! Bounded, same-user local control I/O. No daemon, PTY, or session storage dependency.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const net = std.Io.net;

extern "c" fn getpeereid(fd: std.c.fd_t, uid: *std.c.uid_t, gid: *std.c.gid_t) c_int;

pub fn sameControlUser(fd: std.c.fd_t) bool {
    if (@import("builtin").os.tag == .linux) {
        const Credentials = extern struct { pid: c_int, uid: std.c.uid_t, gid: std.c.gid_t };
        var credentials: Credentials = undefined;
        var length: std.c.socklen_t = @sizeOf(Credentials);
        return std.c.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.PEERCRED, &credentials, &length) == 0 and
            length == @sizeOf(Credentials) and credentials.uid == std.c.geteuid();
    } else {
        var uid: std.c.uid_t = undefined;
        var gid: std.c.gid_t = undefined;
        return getpeereid(fd, &uid, &gid) == 0 and uid == std.c.geteuid();
    }
}

const max_control_request_bytes: usize = 4 * 1024 * 1024;

const PendingControl = struct {
    stream: net.Stream,
    bytes: std.ArrayList(u8) = .empty,
    deadline: i96,
};

/// Slow clients retain bounded state, never the daemon's PTY/control loop.
pub const ControlInbox = struct {
    pending: std.ArrayList(PendingControl) = .empty,
    pub const Request = struct {
        stream: net.Stream,
        text: []u8,
    };

    pub fn deinit(self: *ControlInbox, allocator: Allocator, io: Io) void {
        while (self.pending.items.len > 0) self.drop(allocator, io, self.pending.items.len - 1);
        self.pending.deinit(allocator);
    }

    fn drop(self: *ControlInbox, allocator: Allocator, io: Io, index: usize) void {
        var item = self.pending.swapRemove(index);
        item.stream.close(io);
        item.bytes.deinit(allocator);
    }

    pub fn next(self: *ControlInbox, allocator: Allocator, io: Io, server: *net.Server) !?Request {
        const now = Io.Timestamp.now(io, .awake).nanoseconds;
        var listener = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&listener, 0) > 0) {
            const stream = try server.accept(io);
            if (self.pending.items.len >= 16 or !sameControlUser(stream.socket.handle)) {
                stream.close(io);
            } else {
                self.pending.append(allocator, .{ .stream = stream, .deadline = now + 5 * std.time.ns_per_s }) catch |err| {
                    stream.close(io);
                    return err;
                };
            }
        }
        var index: usize = 0;
        while (index < self.pending.items.len) {
            if (now >= self.pending.items[index].deadline) {
                self.drop(allocator, io, index);
                return error.ControlRequestTimedOut;
            }
            var disconnected = false;
            var budget: usize = 256 * 1024;
            while (budget > 0) {
                var buffer: [16 * 1024]u8 = undefined;
                const count = std.c.recv(self.pending.items[index].stream.socket.handle, &buffer, @min(budget, buffer.len), std.posix.MSG.DONTWAIT);
                if (count < 0) {
                    switch (std.posix.errno(count)) {
                        .AGAIN => break,
                        .INTR => continue,
                        else => {
                            disconnected = true;
                            break;
                        },
                    }
                }
                if (count == 0) {
                    disconnected = true;
                    break;
                }
                const n: usize = @intCast(count);
                budget -= n;
                const line_end = std.mem.indexOfScalar(u8, buffer[0..n], '\n');
                const used = line_end orelse n;
                if (self.pending.items[index].bytes.items.len + used > max_control_request_bytes) {
                    self.drop(allocator, io, index);
                    // The outer loop records this contained rejection, preserving
                    // diagnostics without retaining or parsing attacker bytes.
                    return error.ControlRequestTooLarge;
                }
                try self.pending.items[index].bytes.appendSlice(allocator, buffer[0..used]);
                if (line_end != null) {
                    var complete = self.pending.swapRemove(index);
                    errdefer {
                        complete.stream.close(io);
                        complete.bytes.deinit(allocator);
                    }
                    return .{ .stream = complete.stream, .text = try complete.bytes.toOwnedSlice(allocator) };
                }
            }
            if (disconnected) self.drop(allocator, io, index) else index += 1;
        }
        return null;
    }
};

/// A client that stops reading may cost at most one second of response time.
/// Start the deadline at the first write, after any long-running operation.
pub const DeadlineWriter = struct {
    interface: Io.Writer,
    io: Io,
    fd: std.c.fd_t,
    deadline: ?i96 = null,

    pub fn init(io: Io, fd: std.c.fd_t, buffer: []u8) DeadlineWriter {
        return .{ .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer }, .io = io, .fd = fd };
    }

    fn drain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *DeadlineWriter = @alignCast(@fieldParentPtr("interface", writer));
        if (self.deadline == null) self.deadline = Io.Timestamp.now(self.io, .awake).nanoseconds + std.time.ns_per_s;
        const bytes = blk: {
            if (writer.buffered().len > 0) break :blk writer.buffered();
            for (data[0 .. data.len - 1]) |part| if (part.len > 0) {
                break :blk part;
            };
            if (splat > 0) break :blk data[data.len - 1];
            break :blk &.{};
        };
        if (bytes.len == 0) return 0;
        while (true) {
            const remaining = self.deadline.? - Io.Timestamp.now(self.io, .awake).nanoseconds;
            if (remaining <= 0) return error.WriteFailed;
            const count = std.c.send(self.fd, bytes.ptr, bytes.len, std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL);
            if (count > 0) return writer.consume(@intCast(count));
            if (count == 0) return error.WriteFailed;
            switch (std.posix.errno(count)) {
                .INTR => continue,
                .AGAIN => {
                    var writable = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                    _ = std.posix.poll(&writable, @intCast(@min(25, @divTrunc(remaining, std.time.ns_per_ms)))) catch return error.WriteFailed;
                },
                else => return error.WriteFailed,
            }
        }
    }
};

test "standalone control capability needs no daemon or session" {
    try std.testing.expect(!sameControlUser(-1));
    var inbox: ControlInbox = .{};
    inbox.deinit(std.testing.allocator, std.testing.io);
    var buffer: [16]u8 = undefined;
    var writer = DeadlineWriter.init(std.testing.io, -1, &buffer);
    writer.deadline = 0;
    try writer.interface.writeAll("response");
    try std.testing.expectError(error.WriteFailed, writer.interface.flush());
}
