const std = @import("std");

pub const SessionNameError = error{
    EmptySessionName,
    SessionNameTooLong,
    InvalidSessionName,
};

pub const RecoveryState = enum(u8) {
    clean,
    recovered,
    degraded_corrupt_snapshot,
    degraded_partial_journal,
    degraded_missing_recording_fallback,
};

pub const RecoveryStateError = error{InvalidRecoveryState};

pub const Dimensions = struct {
    cols: u16 = 80,
    rows: u16 = 24,
};

pub fn validateSessionName(name: []const u8) SessionNameError!void {
    if (name.len == 0) return error.EmptySessionName;
    if (name.len > 64) return error.SessionNameTooLong;

    for (name) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
            else => return error.InvalidSessionName,
        }
    }
}

pub fn recoveryLabel(state: RecoveryState) []const u8 {
    return switch (state) {
        .clean => "clean",
        .recovered => "recovered",
        .degraded_corrupt_snapshot => "degraded_corrupt_snapshot",
        .degraded_partial_journal => "degraded_partial_journal",
        .degraded_missing_recording_fallback => "degraded_missing_recording_fallback",
    };
}

pub fn recoveryByte(state: RecoveryState) u8 {
    return @intFromEnum(state);
}

pub fn recoveryStateFromByte(byte: u8) RecoveryStateError!RecoveryState {
    return switch (byte) {
        @intFromEnum(RecoveryState.clean) => .clean,
        @intFromEnum(RecoveryState.recovered) => .recovered,
        @intFromEnum(RecoveryState.degraded_corrupt_snapshot) => .degraded_corrupt_snapshot,
        @intFromEnum(RecoveryState.degraded_partial_journal) => .degraded_partial_journal,
        @intFromEnum(RecoveryState.degraded_missing_recording_fallback) => .degraded_missing_recording_fallback,
        else => error.InvalidRecoveryState,
    };
}

test "session names are path-safe" {
    try validateSessionName("agent-1.main");
    try std.testing.expectError(error.EmptySessionName, validateSessionName(""));
    try std.testing.expectError(error.InvalidSessionName, validateSessionName("../escape"));
    try std.testing.expectError(error.InvalidSessionName, validateSessionName("two words"));
}
