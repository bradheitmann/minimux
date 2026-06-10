const std = @import("std");
const proto = @import("proto.zig");

const Io = std.Io;

pub const ProcessState = enum {
    running,
    exited,
    signaled,
    unknown,
};

pub const State = enum {
    idle,
    exited,
    timeout,
    unknown,

    pub fn label(state: State) []const u8 {
        return switch (state) {
            .idle => "idle",
            .exited => "exited",
            .timeout => "timeout",
            .unknown => "unknown",
        };
    }
};

pub const Observation = struct {
    state: State,
    idle: bool,
    exit_code: ?u8,
    timeout_ms: u64,
    reason: []const u8,
    action: []const u8,
    retryable: bool,

    pub fn ok(observation: Observation) bool {
        return observation.state == .idle or observation.state == .exited;
    }

    pub fn errorCode(observation: Observation) []const u8 {
        return switch (observation.state) {
            .idle => "ok",
            .exited => "ok",
            .timeout => "error.WaitIdleTimeout",
            .unknown => "error.WaitIdleUnknown",
        };
    }
};

pub fn observe(process_state: ProcessState, exit_code: ?u8, timeout_ms: u64) Observation {
    if (timeout_ms == 0) {
        return .{
            .state = .timeout,
            .idle = false,
            .exit_code = null,
            .timeout_ms = timeout_ms,
            .reason = "timeout expired before a shell prompt could be observed",
            .action = "retry with --timeout-ms greater than 0 or inspect pane snapshot",
            .retryable = true,
        };
    }

    return switch (process_state) {
        .running => .{
            .state = .idle,
            .idle = true,
            .exit_code = null,
            .timeout_ms = timeout_ms,
            .reason = "shell process is running and no command is pending",
            .action = "safe to send the next shell command",
            .retryable = false,
        },
        .exited => .{
            .state = .exited,
            .idle = false,
            .exit_code = exit_code,
            .timeout_ms = timeout_ms,
            .reason = "shell process exited",
            .action = "start a new session or inspect the final snapshot",
            .retryable = false,
        },
        .signaled => .{
            .state = .unknown,
            .idle = false,
            .exit_code = null,
            .timeout_ms = timeout_ms,
            .reason = "shell process ended by signal",
            .action = "inspect daemon logs and final snapshot before sending more input",
            .retryable = false,
        },
        .unknown => .{
            .state = .unknown,
            .idle = false,
            .exit_code = null,
            .timeout_ms = timeout_ms,
            .reason = "shell process state could not be determined",
            .action = "inspect session metadata, daemon logs, and snapshot recovery state",
            .retryable = false,
        },
    };
}

pub fn unknown(timeout_ms: u64, reason: []const u8, action: []const u8) Observation {
    return .{
        .state = .unknown,
        .idle = false,
        .exit_code = null,
        .timeout_ms = timeout_ms,
        .reason = reason,
        .action = action,
        .retryable = false,
    };
}

pub fn timedOut(timeout_ms: u64) Observation {
    return .{
        .state = .timeout,
        .idle = false,
        .exit_code = null,
        .timeout_ms = timeout_ms,
        .reason = "timeout expired before the harness observed an idle terminal",
        .action = "retry with a larger --timeout-ms or inspect the pane snapshot",
        .retryable = true,
    };
}

pub fn exited(timeout_ms: u64, reason: []const u8, action: []const u8) Observation {
    return .{
        .state = .exited,
        .idle = false,
        .exit_code = null,
        .timeout_ms = timeout_ms,
        .reason = reason,
        .action = action,
        .retryable = false,
    };
}

pub fn writeObservationJson(
    writer: *Io.Writer,
    session_name: []const u8,
    observation: Observation,
    request_id: []const u8,
    seq: u64,
) !void {
    if (observation.ok()) {
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":true,\"result\":{\"session\":");
        try proto.writeJsonString(writer, session_name);
        try writer.writeAll(",\"state\":");
        try proto.writeJsonString(writer, observation.state.label());
        try writer.print(",\"idle\":{},\"timeout_ms\":{d},\"harness\":\"shell-generic\"", .{
            observation.idle,
            observation.timeout_ms,
        });
        if (observation.exit_code) |code| try writer.print(",\"exit_code\":{d}", .{code});
        try writer.writeAll(",\"detail\":");
        try writeDetailJson(writer, observation);
        try writer.writeAll("},\"request_id\":");
        try proto.writeJsonString(writer, request_id);
        try writer.print(",\"seq\":{d}}}\n", .{seq});
        return;
    }

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"ok\":false,\"error\":{\"code\":");
    try proto.writeJsonString(writer, observation.errorCode());
    try writer.writeAll(",\"message\":\"shell wait-idle did not reach idle\",\"detail\":");
    try writeDetailJson(writer, observation);
    try writer.print(",\"retryable\":{}}},\"request_id\":", .{observation.retryable});
    try proto.writeJsonString(writer, request_id);
    try writer.print(",\"seq\":{d}}}\n", .{seq});
}

fn writeDetailJson(writer: *Io.Writer, observation: Observation) !void {
    try writer.writeAll("{\"state\":");
    try proto.writeJsonString(writer, observation.state.label());
    try writer.writeAll(",\"harness\":\"shell-generic\",\"reason\":");
    try proto.writeJsonString(writer, observation.reason);
    try writer.writeAll(",\"action\":");
    try proto.writeJsonString(writer, observation.action);
    try writer.print(",\"timeout_ms\":{d}", .{observation.timeout_ms});
    if (observation.exit_code) |code| try writer.print(",\"exit_code\":{d}", .{code});
    try writer.writeAll("}");
}

test "shell harness maps process states to actionable observations" {
    const idle = observe(.running, null, 5000);
    try std.testing.expectEqual(State.idle, idle.state);
    try std.testing.expect(idle.idle);

    const timed_out = observe(.running, null, 0);
    try std.testing.expectEqual(State.timeout, timed_out.state);
    try std.testing.expect(timed_out.retryable);

    const done = observe(.exited, 7, 5000);
    try std.testing.expectEqual(State.exited, done.state);
    try std.testing.expectEqual(@as(?u8, 7), done.exit_code);

    const unclear = observe(.unknown, null, 5000);
    try std.testing.expectEqual(State.unknown, unclear.state);
    try std.testing.expect(std.mem.indexOf(u8, unclear.action, "snapshot") != null);

    const expired = timedOut(750);
    try std.testing.expectEqual(State.timeout, expired.state);
    try std.testing.expect(expired.retryable);
    try std.testing.expectEqual(@as(u64, 750), expired.timeout_ms);
    try std.testing.expectEqualStrings("error.WaitIdleTimeout", expired.errorCode());
}
