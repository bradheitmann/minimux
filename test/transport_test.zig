const std = @import("std");
const minimux = @import("minimux");

const test_key_material = "transport test key material for chacha20 poly1305";
const connection_id: minimux.transport.ConnectionId = 0x1122334455667788;

test "transport derives chacha20-poly1305 keys with 64 bit connection identity" {
    const schedule = try minimux.crypto.deriveKeySchedule(test_key_material, connection_id);
    try std.testing.expectEqual(@as(u16, 64), schedule.connectionIdBits());
    try std.testing.expect(!std.mem.eql(u8, &schedule.client_to_server, &schedule.server_to_client));
}

test "transport tunnels control request and response json rpc frames" {
    const allocator = std.testing.allocator;
    const schedule = try minimux.crypto.deriveKeySchedule(test_key_material, connection_id);

    const request =
        \\{"jsonrpc":"2.0","id":9,"method":"pane.snapshot","params":{"pane_id":"pane-1"}}
    ;
    var request_seal = minimux.transport.SealState.init(schedule, .client_to_server);
    const request_frame = try minimux.transport.sealControlRequest(&request_seal, allocator, request);
    defer allocator.free(request_frame);
    try std.testing.expect(std.mem.indexOf(u8, request_frame, "pane.snapshot") == null);

    var request_open = minimux.transport.OpenState.init(schedule, .client_to_server);
    const opened_request = try request_open.open(allocator, request_frame);
    defer opened_request.deinit(allocator);
    try std.testing.expectEqual(minimux.transport.FrameKind.control_request, opened_request.kind);
    try std.testing.expectEqual(@as(u64, 0), opened_request.sequence);
    try std.testing.expectEqualSlices(u8, request, opened_request.payload);

    const response =
        \\{"jsonrpc":"2.0","id":9,"result":{"visible_text":"ok"}}
    ;
    var response_seal = minimux.transport.SealState.init(schedule, .server_to_client);
    const response_frame = try minimux.transport.sealControlResponse(&response_seal, allocator, response);
    defer allocator.free(response_frame);
    try std.testing.expect(std.mem.indexOf(u8, response_frame, "visible_text") == null);

    var response_open = minimux.transport.OpenState.init(schedule, .server_to_client);
    const opened_response = try response_open.open(allocator, response_frame);
    defer opened_response.deinit(allocator);
    try std.testing.expectEqual(minimux.transport.FrameKind.control_response, opened_response.kind);
    try std.testing.expectEqualSlices(u8, response, opened_response.payload);
}

test "transport fails closed for wrong psk replay truncated frame and sequence skip" {
    const allocator = std.testing.allocator;
    const schedule = try minimux.crypto.deriveKeySchedule(test_key_material, connection_id);
    var seal = minimux.transport.SealState.init(schedule, .client_to_server);
    const first = try minimux.transport.sealControlRequest(&seal, allocator, "{\"jsonrpc\":\"2.0\",\"id\":1}");
    defer allocator.free(first);
    const second = try minimux.transport.sealControlRequest(&seal, allocator, "{\"jsonrpc\":\"2.0\",\"id\":2}");
    defer allocator.free(second);

    const bad_schedule = try minimux.crypto.deriveKeySchedule("different transport test key material", connection_id);
    var wrong_psk = minimux.transport.OpenState.init(bad_schedule, .client_to_server);
    try std.testing.expectError(error.AuthenticationFailed, wrong_psk.open(allocator, first));

    var replay = minimux.transport.OpenState.init(schedule, .client_to_server);
    const opened = try replay.open(allocator, first);
    opened.deinit(allocator);
    try std.testing.expectError(error.Replay, replay.open(allocator, first));

    var truncated = minimux.transport.OpenState.init(schedule, .client_to_server);
    try std.testing.expectError(error.TruncatedFrame, truncated.open(allocator, first[0 .. first.len - 1]));

    var skipped = minimux.transport.OpenState.init(schedule, .client_to_server);
    try std.testing.expectError(error.SequenceSkip, skipped.open(allocator, second));
}

test "transport self-test reports every required failure mode" {
    const report = try minimux.transport.runSelfTest(std.testing.allocator);
    try std.testing.expect(report.request_tunneled);
    try std.testing.expect(report.response_tunneled);
    try std.testing.expect(report.wrong_psk_failed);
    try std.testing.expect(report.replay_failed);
    try std.testing.expect(report.truncated_frame_failed);
    try std.testing.expect(report.sequence_skip_failed);
    try std.testing.expect(report.no_plaintext_fallback);
}
