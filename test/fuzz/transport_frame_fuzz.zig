const std = @import("std");
const minimux = @import("minimux");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const runs = parseRuns(args);
    const schedule = try minimux.crypto.deriveKeySchedule("transport fuzz key material v1", 0xa0b0c0d0e0f00102);

    var seed: u64 = 0x6d696e696d757831;
    var invalid_frames: usize = 0;
    var accepted_frames: usize = 0;
    var buffer: [512]u8 = undefined;

    var index: usize = 0;
    while (index < runs) : (index += 1) {
        const len = nextBounded(&seed, buffer.len + 1);
        fillBytes(&seed, buffer[0..len]);
        var opener = minimux.transport.OpenState.init(schedule, .client_to_server);
        const opened = opener.open(allocator, buffer[0..len]) catch |err| switch (err) {
            error.AuthenticationFailed,
            error.ConnectionIdMismatch,
            error.FrameTooLarge,
            error.InvalidFrame,
            error.Replay,
            error.SequenceSkip,
            error.TruncatedFrame,
            error.UnsupportedFrameKind,
            error.UnsupportedVersion,
            error.WrongDirection,
            => {
                invalid_frames += 1;
                continue;
            },
            else => |e| return e,
        };
        opened.deinit(allocator);
        accepted_frames += 1;
    }

    var plaintext_open = minimux.transport.OpenState.init(schedule, .client_to_server);
    const plaintext_opened = plaintext_open.open(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"system.health\"}") catch |err| switch (err) {
        error.InvalidFrame, error.TruncatedFrame => null,
        else => |e| return e,
    };
    if (plaintext_opened) |opened| {
        opened.deinit(allocator);
        return error.PlaintextFallbackAccepted;
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};
    try stdout.print(
        "{{\"ok\":true,\"runs\":{d},\"invalid_frames\":{d},\"accepted_frames\":{d},\"plaintext_fallback\":false}}\n",
        .{ runs, invalid_frames, accepted_frames },
    );
}

fn parseRuns(args: []const []const u8) usize {
    var index: usize = 1;
    while (index + 1 < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--runs")) {
            return std.fmt.parseInt(usize, args[index + 1], 10) catch 1000;
        }
    }
    return 1000;
}

fn nextBounded(seed: *u64, upper: usize) usize {
    if (upper == 0) return 0;
    seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
    return @as(usize, @intCast(seed.* >> 32)) % upper;
}

fn fillBytes(seed: *u64, output: []u8) void {
    for (output) |*byte| {
        seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(seed.* >> 24);
    }
}
