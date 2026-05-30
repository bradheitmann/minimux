const std = @import("std");

const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

pub const ConnectionId = u64;
pub const key_length = Aead.key_length;
pub const nonce_length = Aead.nonce_length;
pub const tag_length = Aead.tag_length;
pub const min_psk_length = 16;

pub const CryptoError = error{
    WeakPsk,
};

pub const KeySchedule = struct {
    connection_id: ConnectionId,
    client_to_server: [key_length]u8,
    server_to_client: [key_length]u8,

    pub fn connectionIdBits(_: KeySchedule) u16 {
        return @bitSizeOf(ConnectionId);
    }
};

pub fn deriveKeySchedule(psk: []const u8, connection_id: ConnectionId) CryptoError!KeySchedule {
    if (psk.len < min_psk_length) return error.WeakPsk;

    const salt_prefix = "minimux-remote-v1";
    var salt: [salt_prefix.len + @sizeOf(ConnectionId)]u8 = undefined;
    @memcpy(salt[0..salt_prefix.len], salt_prefix);
    std.mem.writeInt(ConnectionId, salt[salt_prefix.len..][0..@sizeOf(ConnectionId)], connection_id, .little);

    const prk = Hkdf.extract(&salt, psk);
    var schedule: KeySchedule = .{
        .connection_id = connection_id,
        .client_to_server = undefined,
        .server_to_client = undefined,
    };
    Hkdf.expand(&schedule.client_to_server, "minimux c2s chacha20poly1305", prk);
    Hkdf.expand(&schedule.server_to_client, "minimux s2c chacha20poly1305", prk);
    return schedule;
}

pub fn nonceFromSequence(direction_tag: u8, sequence: u64) [nonce_length]u8 {
    var nonce = [_]u8{0} ** nonce_length;
    nonce[0] = direction_tag;
    std.mem.writeInt(u64, nonce[4..12], sequence, .little);
    return nonce;
}

test "hkdf derives separate per-direction keys from psk and connection id" {
    const schedule = try deriveKeySchedule("0123456789abcdef0123456789abcdef", 0x1020304050607080);
    try std.testing.expectEqual(@as(u16, 64), schedule.connectionIdBits());
    try std.testing.expect(!std.mem.eql(u8, &schedule.client_to_server, &schedule.server_to_client));

    const other = try deriveKeySchedule("0123456789abcdef0123456789abcdef", 0x1020304050607081);
    try std.testing.expect(!std.mem.eql(u8, &schedule.client_to_server, &other.client_to_server));
}

test "weak psk is rejected before deriving transport keys" {
    try std.testing.expectError(error.WeakPsk, deriveKeySchedule("short", 1));
}
