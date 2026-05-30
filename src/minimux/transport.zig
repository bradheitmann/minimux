const std = @import("std");
const crypto = @import("crypto.zig");
const proto = @import("proto.zig");

const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const FrameKind = proto.RemoteFrameKind;
pub const ConnectionId = crypto.ConnectionId;

pub const Direction = enum(u8) {
    client_to_server = 1,
    server_to_client = 2,

    pub fn label(direction: Direction) []const u8 {
        return switch (direction) {
            .client_to_server => "client_to_server",
            .server_to_client => "server_to_client",
        };
    }
};

pub const TransportError = error{
    AuthenticationFailed,
    ConnectionIdMismatch,
    FrameTooLarge,
    InvalidFrame,
    Replay,
    SequenceSkip,
    TruncatedFrame,
    UnsupportedFrameKind,
    UnsupportedVersion,
    WrongDirection,
};

pub const magic = "MMXT";
pub const version: u8 = 1;
pub const header_len: usize = 28;
pub const min_frame_len: usize = header_len + crypto.tag_length;
pub const max_payload_len: usize = 1024 * 1024;

const Header = struct {
    kind: FrameKind,
    direction: Direction,
    connection_id: ConnectionId,
    sequence: u64,
    payload_len: usize,
};

pub const SealState = struct {
    key: [crypto.key_length]u8,
    connection_id: ConnectionId,
    direction: Direction,
    next_sequence: u64 = 0,

    pub fn init(schedule: crypto.KeySchedule, direction: Direction) SealState {
        return .{
            .key = keyFor(schedule, direction),
            .connection_id = schedule.connection_id,
            .direction = direction,
        };
    }

    pub fn seal(state: *SealState, allocator: std.mem.Allocator, kind: FrameKind, payload: []const u8) ![]u8 {
        if (payload.len > max_payload_len) return error.FrameTooLarge;

        const frame_len = min_frame_len + payload.len;
        var frame = try allocator.alloc(u8, frame_len);
        errdefer allocator.free(frame);

        const sequence = state.next_sequence;
        writeHeader(frame[0..header_len], .{
            .kind = kind,
            .direction = state.direction,
            .connection_id = state.connection_id,
            .sequence = sequence,
            .payload_len = payload.len,
        });

        const nonce = crypto.nonceFromSequence(@intFromEnum(state.direction), sequence);
        var tag: [crypto.tag_length]u8 = undefined;
        Aead.encrypt(frame[min_frame_len..], &tag, payload, frame[0..header_len], nonce, state.key);
        @memcpy(frame[header_len..min_frame_len], tag[0..]);
        state.next_sequence +%= 1;
        return frame;
    }
};

pub const OpenState = struct {
    key: [crypto.key_length]u8,
    connection_id: ConnectionId,
    direction: Direction,
    next_sequence: u64 = 0,

    pub fn init(schedule: crypto.KeySchedule, direction: Direction) OpenState {
        return .{
            .key = keyFor(schedule, direction),
            .connection_id = schedule.connection_id,
            .direction = direction,
        };
    }

    pub fn open(state: *OpenState, allocator: std.mem.Allocator, frame: []const u8) !OpenedFrame {
        const header = try readHeader(frame);
        if (header.connection_id != state.connection_id) return error.ConnectionIdMismatch;
        if (header.direction != state.direction) return error.WrongDirection;
        if (header.sequence < state.next_sequence) return error.Replay;
        if (header.sequence > state.next_sequence) return error.SequenceSkip;

        const ciphertext = frame[min_frame_len..];
        var tag: [crypto.tag_length]u8 = undefined;
        @memcpy(tag[0..], frame[header_len..min_frame_len]);
        const payload = try allocator.alloc(u8, ciphertext.len);
        errdefer allocator.free(payload);

        const nonce = crypto.nonceFromSequence(@intFromEnum(header.direction), header.sequence);
        Aead.decrypt(payload, ciphertext, tag, frame[0..header_len], nonce, state.key) catch |err| switch (err) {
            error.AuthenticationFailed => return error.AuthenticationFailed,
        };
        state.next_sequence +%= 1;
        return .{
            .kind = header.kind,
            .direction = header.direction,
            .connection_id = header.connection_id,
            .sequence = header.sequence,
            .payload = payload,
        };
    }
};

pub const OpenedFrame = struct {
    kind: FrameKind,
    direction: Direction,
    connection_id: ConnectionId,
    sequence: u64,
    payload: []u8,

    pub fn deinit(frame: OpenedFrame, allocator: std.mem.Allocator) void {
        allocator.free(frame.payload);
    }
};

pub const SelfTestReport = struct {
    cipher: []const u8 = "ChaCha20-Poly1305",
    kdf: []const u8 = "HKDF-SHA256",
    connection_id_bits: u16 = @bitSizeOf(ConnectionId),
    request_tunneled: bool,
    response_tunneled: bool,
    wrong_psk_failed: bool,
    replay_failed: bool,
    truncated_frame_failed: bool,
    sequence_skip_failed: bool,
    no_plaintext_fallback: bool,
};

pub fn sealControlRequest(state: *SealState, allocator: std.mem.Allocator, json_rpc: []const u8) ![]u8 {
    return state.seal(allocator, .control_request, json_rpc);
}

pub fn sealControlResponse(state: *SealState, allocator: std.mem.Allocator, json_rpc: []const u8) ![]u8 {
    return state.seal(allocator, .control_response, json_rpc);
}

pub fn runSelfTest(allocator: std.mem.Allocator) !SelfTestReport {
    const test_key_material = "minimux transport test key material v1";
    const connection_id: ConnectionId = 0x0102030405060708;
    const request_payload =
        \\{"jsonrpc":"2.0","id":1,"method":"system.health","params":{}}
    ;
    const response_payload =
        \\{"jsonrpc":"2.0","id":1,"result":{"status":"ok"}}
    ;

    const schedule = try crypto.deriveKeySchedule(test_key_material, connection_id);
    var client_seal = SealState.init(schedule, .client_to_server);
    var server_open = OpenState.init(schedule, .client_to_server);
    const request_frame = try sealControlRequest(&client_seal, allocator, request_payload);
    defer allocator.free(request_frame);

    const request_opened = try server_open.open(allocator, request_frame);
    defer request_opened.deinit(allocator);

    var server_seal = SealState.init(schedule, .server_to_client);
    var client_open = OpenState.init(schedule, .server_to_client);
    const response_frame = try sealControlResponse(&server_seal, allocator, response_payload);
    defer allocator.free(response_frame);
    const response_opened = try client_open.open(allocator, response_frame);
    defer response_opened.deinit(allocator);

    const bad_schedule = try crypto.deriveKeySchedule("wrong minimux transport key material", connection_id);
    var bad_open = OpenState.init(bad_schedule, .client_to_server);
    const wrong_psk_failed = blk: {
        const opened = bad_open.open(allocator, request_frame) catch |err| switch (err) {
            error.AuthenticationFailed => break :blk true,
            else => |e| return e,
        };
        opened.deinit(allocator);
        break :blk false;
    };

    const replay_failed = blk: {
        const opened = server_open.open(allocator, request_frame) catch |err| switch (err) {
            error.Replay => break :blk true,
            else => |e| return e,
        };
        opened.deinit(allocator);
        break :blk false;
    };

    const truncated_frame_failed = blk: {
        var fresh_open = OpenState.init(schedule, .client_to_server);
        const opened = fresh_open.open(allocator, request_frame[0 .. request_frame.len - 1]) catch |err| switch (err) {
            error.TruncatedFrame => break :blk true,
            else => |e| return e,
        };
        opened.deinit(allocator);
        break :blk false;
    };

    var skip_seal = SealState.init(schedule, .client_to_server);
    const skip_first = try sealControlRequest(&skip_seal, allocator, request_payload);
    defer allocator.free(skip_first);
    const skip_second = try sealControlRequest(&skip_seal, allocator, request_payload);
    defer allocator.free(skip_second);
    const sequence_skip_failed = blk: {
        var fresh_open = OpenState.init(schedule, .client_to_server);
        const opened = fresh_open.open(allocator, skip_second) catch |err| switch (err) {
            error.SequenceSkip => break :blk true,
            else => |e| return e,
        };
        opened.deinit(allocator);
        break :blk false;
    };

    return .{
        .request_tunneled = request_opened.kind == .control_request and
            std.mem.eql(u8, request_opened.payload, request_payload),
        .response_tunneled = response_opened.kind == .control_response and
            std.mem.eql(u8, response_opened.payload, response_payload),
        .wrong_psk_failed = wrong_psk_failed,
        .replay_failed = replay_failed,
        .truncated_frame_failed = truncated_frame_failed,
        .sequence_skip_failed = sequence_skip_failed,
        .no_plaintext_fallback = std.mem.indexOf(u8, request_frame, "system.health") == null and
            std.mem.indexOf(u8, response_frame, "status") == null,
    };
}

fn keyFor(schedule: crypto.KeySchedule, direction: Direction) [crypto.key_length]u8 {
    return switch (direction) {
        .client_to_server => schedule.client_to_server,
        .server_to_client => schedule.server_to_client,
    };
}

fn writeHeader(out: []u8, header: Header) void {
    std.debug.assert(out.len == header_len);
    @memcpy(out[0..4], magic);
    out[4] = version;
    out[5] = @intFromEnum(header.kind);
    out[6] = @intFromEnum(header.direction);
    out[7] = 0;
    std.mem.writeInt(ConnectionId, out[8..16], header.connection_id, .little);
    std.mem.writeInt(u64, out[16..24], header.sequence, .little);
    std.mem.writeInt(u32, out[24..28], @intCast(header.payload_len), .little);
}

fn readHeader(frame: []const u8) !Header {
    if (frame.len < min_frame_len) return error.TruncatedFrame;
    if (!std.mem.eql(u8, frame[0..4], magic)) return error.InvalidFrame;
    if (frame[4] != version) return error.UnsupportedVersion;
    if (frame[7] != 0) return error.InvalidFrame;

    const payload_len = std.mem.readInt(u32, frame[24..28], .little);
    if (payload_len > max_payload_len) return error.FrameTooLarge;
    if (frame.len != min_frame_len + @as(usize, @intCast(payload_len))) return error.TruncatedFrame;

    return .{
        .kind = proto.remoteFrameKindFromTag(frame[5]) orelse return error.UnsupportedFrameKind,
        .direction = directionFromTag(frame[6]) orelse return error.WrongDirection,
        .connection_id = std.mem.readInt(ConnectionId, frame[8..16], .little),
        .sequence = std.mem.readInt(u64, frame[16..24], .little),
        .payload_len = @intCast(payload_len),
    };
}

fn directionFromTag(tag: u8) ?Direction {
    return switch (tag) {
        @intFromEnum(Direction.client_to_server) => .client_to_server,
        @intFromEnum(Direction.server_to_client) => .server_to_client,
        else => null,
    };
}

test "transport self-test covers encrypted control tunnel failures" {
    const report = try runSelfTest(std.testing.allocator);
    try std.testing.expect(report.request_tunneled);
    try std.testing.expect(report.response_tunneled);
    try std.testing.expect(report.wrong_psk_failed);
    try std.testing.expect(report.replay_failed);
    try std.testing.expect(report.truncated_frame_failed);
    try std.testing.expect(report.sequence_skip_failed);
    try std.testing.expect(report.no_plaintext_fallback);
}
