const std = @import("std");
const Io = std.Io;

pub const protocol_version = "0.1.0";
pub const snapshot_schema_version = "0.1.0";

pub const PublicMethod = enum {
    session_create,
    session_attach,
    session_list,
    session_terminate,
    pane_create,
    pane_send,
    pane_resize,
    pane_snapshot,
    pane_close,
    agent_wait_idle,
    record_start,
    record_stop,
    tap_open,
    tap_close,
    system_health,
};

pub const ParamType = enum {
    string,
    object,
    string_array,
    bytes,
    u16,
    u64,
};

pub const ParamSpec = struct {
    name: []const u8,
    field_type: ParamType,
    required: bool,
};

pub const PublicMethodInfo = struct {
    method: PublicMethod,
    wire_name: []const u8,
    params: []const ParamSpec,
    purpose: []const u8,
};

const session_create_params = [_]ParamSpec{
    .{ .name = "name", .field_type = .string, .required = true },
    .{ .name = "options", .field_type = .object, .required = false },
};

const session_name_params = [_]ParamSpec{
    .{ .name = "name", .field_type = .string, .required = true },
};

const pane_create_params = [_]ParamSpec{
    .{ .name = "session", .field_type = .string, .required = true },
    .{ .name = "argv", .field_type = .string_array, .required = true },
    .{ .name = "env", .field_type = .object, .required = true },
    .{ .name = "cwd", .field_type = .string, .required = true },
    .{ .name = "size", .field_type = .object, .required = true },
};

const pane_send_params = [_]ParamSpec{
    .{ .name = "pane_id", .field_type = .string, .required = true },
    .{ .name = "bytes", .field_type = .bytes, .required = true },
};

const pane_resize_params = [_]ParamSpec{
    .{ .name = "pane_id", .field_type = .string, .required = true },
    .{ .name = "cols", .field_type = .u16, .required = true },
    .{ .name = "rows", .field_type = .u16, .required = true },
};

const pane_id_params = [_]ParamSpec{
    .{ .name = "pane_id", .field_type = .string, .required = true },
};

const wait_idle_params = [_]ParamSpec{
    .{ .name = "pane_id", .field_type = .string, .required = true },
    .{ .name = "timeout_ms", .field_type = .u64, .required = true },
    .{ .name = "harness", .field_type = .object, .required = true },
};

const record_start_params = [_]ParamSpec{
    .{ .name = "pane_id", .field_type = .string, .required = true },
    .{ .name = "path", .field_type = .string, .required = true },
    .{ .name = "policy", .field_type = .object, .required = true },
};

const recording_id_params = [_]ParamSpec{
    .{ .name = "recording_id", .field_type = .string, .required = true },
};

const tap_open_params = [_]ParamSpec{
    .{ .name = "pane_id", .field_type = .string, .required = true },
    .{ .name = "filter", .field_type = .object, .required = true },
};

const tap_id_params = [_]ParamSpec{
    .{ .name = "tap_id", .field_type = .string, .required = true },
};

pub const public_methods = [_]PublicMethodInfo{
    .{ .method = .session_create, .wire_name = "session.create", .params = &session_create_params, .purpose = "Create a named managed session." },
    .{ .method = .session_attach, .wire_name = "session.attach", .params = &session_name_params, .purpose = "Attach to an existing managed session." },
    .{ .method = .session_list, .wire_name = "session.list", .params = &.{}, .purpose = "List visible managed sessions." },
    .{ .method = .session_terminate, .wire_name = "session.terminate", .params = &session_name_params, .purpose = "Terminate a managed session." },
    .{ .method = .pane_create, .wire_name = "pane.create", .params = &pane_create_params, .purpose = "Create a pane process in a session." },
    .{ .method = .pane_send, .wire_name = "pane.send", .params = &pane_send_params, .purpose = "Write bytes to a pane." },
    .{ .method = .pane_resize, .wire_name = "pane.resize", .params = &pane_resize_params, .purpose = "Resize a pane." },
    .{ .method = .pane_snapshot, .wire_name = "pane.snapshot", .params = &pane_id_params, .purpose = "Return structured pane state." },
    .{ .method = .pane_close, .wire_name = "pane.close", .params = &pane_id_params, .purpose = "Close a pane." },
    .{ .method = .agent_wait_idle, .wire_name = "agent.wait_idle", .params = &wait_idle_params, .purpose = "Wait until a harness observes idle state." },
    .{ .method = .record_start, .wire_name = "record.start", .params = &record_start_params, .purpose = "Start a private recording." },
    .{ .method = .record_stop, .wire_name = "record.stop", .params = &recording_id_params, .purpose = "Stop a recording." },
    .{ .method = .tap_open, .wire_name = "tap.open", .params = &tap_open_params, .purpose = "Open an ordered event tap." },
    .{ .method = .tap_close, .wire_name = "tap.close", .params = &tap_id_params, .purpose = "Close an event tap." },
    .{ .method = .system_health, .wire_name = "system.health", .params = &.{}, .purpose = "Return daemon or scaffold health." },
};

pub fn hasPublicMethod(wire_name: []const u8) bool {
    return findPublicMethod(wire_name) != null;
}

pub fn findPublicMethod(wire_name: []const u8) ?*const PublicMethodInfo {
    for (&public_methods) |*entry| {
        if (std.mem.eql(u8, entry.wire_name, wire_name)) return entry;
    }
    return null;
}

pub const ErrorCategory = enum {
    json_rpc,
    lifecycle,
    validation,
};

pub const ProtocolErrorInfo = struct {
    code: i32,
    name: []const u8,
    category: ErrorCategory,
    message: []const u8,
};

pub const RemoteFrameKind = enum(u8) {
    control_request = 1,
    control_response = 2,
    pty_stream = 3,
};

pub const RemoteFrameKindInfo = struct {
    kind: RemoteFrameKind,
    wire_name: []const u8,
    purpose: []const u8,
};

pub const remote_frame_kinds = [_]RemoteFrameKindInfo{
    .{ .kind = .control_request, .wire_name = "CONTROL_REQUEST", .purpose = "Carries a JSON-RPC request over the encrypted remote transport." },
    .{ .kind = .control_response, .wire_name = "CONTROL_RESPONSE", .purpose = "Carries a JSON-RPC response over the encrypted remote transport." },
    .{ .kind = .pty_stream, .wire_name = "PTY_STREAM", .purpose = "Carries encrypted PTY byte stream data." },
};

pub fn remoteFrameKindFromTag(tag: u8) ?RemoteFrameKind {
    return switch (tag) {
        @intFromEnum(RemoteFrameKind.control_request) => .control_request,
        @intFromEnum(RemoteFrameKind.control_response) => .control_response,
        @intFromEnum(RemoteFrameKind.pty_stream) => .pty_stream,
        else => null,
    };
}

pub fn remoteFrameKindName(kind: RemoteFrameKind) []const u8 {
    for (remote_frame_kinds) |entry| {
        if (entry.kind == kind) return entry.wire_name;
    }
    return "UNKNOWN";
}

pub const error_codes = [_]ProtocolErrorInfo{
    .{ .code = -32700, .name = "parse_error", .category = .json_rpc, .message = "Invalid JSON was received by the server." },
    .{ .code = -32600, .name = "invalid_request", .category = .json_rpc, .message = "The JSON sent is not a valid request object." },
    .{ .code = -32601, .name = "method_not_found", .category = .json_rpc, .message = "The method does not exist or is unavailable." },
    .{ .code = -32602, .name = "invalid_params", .category = .json_rpc, .message = "Invalid method parameter." },
    .{ .code = -32603, .name = "internal_error", .category = .json_rpc, .message = "Internal JSON-RPC error." },
    .{ .code = 1001, .name = "session_not_found", .category = .lifecycle, .message = "The requested session does not exist." },
    .{ .code = 1002, .name = "daemon_not_running", .category = .lifecycle, .message = "The daemon is not running." },
    .{ .code = 1003, .name = "control_socket_unavailable", .category = .lifecycle, .message = "The control socket is unavailable." },
    .{ .code = 1004, .name = "control_socket_timeout", .category = .lifecycle, .message = "The control socket timed out." },
    .{ .code = 2001, .name = "validation_unknown_required_field", .category = .validation, .message = "A fixture declares an unknown required field." },
    .{ .code = 2002, .name = "validation_invalid_enum_value", .category = .validation, .message = "A fixture contains an invalid enum value." },
    .{ .code = 2003, .name = "validation_non_monotonic_sequence", .category = .validation, .message = "A fixture sequence number is not strictly increasing." },
    .{ .code = 2004, .name = "validation_missing_method", .category = .validation, .message = "A fixture omits a required public method." },
    .{ .code = 2005, .name = "validation_missing_error_code", .category = .validation, .message = "A fixture omits a required error code." },
};

pub fn hasErrorCode(code: i32) bool {
    for (error_codes) |entry| {
        if (entry.code == code) return true;
    }
    return false;
}

pub const CApiOperation = struct {
    group: []const u8,
    symbol: []const u8,
    signature: []const u8,
    ownership: []const u8,
};

pub const c_api_operations = [_]CApiOperation{
    .{ .group = "session", .symbol = "minimux_session_create", .signature = "int minimux_session_create(const char *name, const struct minimux_session_options *options, minimux_session_t **out_session);", .ownership = "On success, *out_session is caller-owned and must be released with minimux_session_destroy." },
    .{ .group = "session", .symbol = "minimux_session_attach", .signature = "int minimux_session_attach(const char *name, minimux_session_t **out_session);", .ownership = "On success, *out_session is caller-owned and must be released with minimux_session_destroy." },
    .{ .group = "session", .symbol = "minimux_session_list", .signature = "int minimux_session_list(minimux_session_list_t **out_list);", .ownership = "On success, *out_list is caller-owned and must be released with minimux_session_list_destroy." },
    .{ .group = "session", .symbol = "minimux_session_list_destroy", .signature = "void minimux_session_list_destroy(minimux_session_list_t *list);", .ownership = "Releases a caller-owned session list; NULL is accepted." },
    .{ .group = "session", .symbol = "minimux_session_terminate", .signature = "int minimux_session_terminate(const char *name);", .ownership = "The name pointer is borrowed for the duration of the call." },
    .{ .group = "session", .symbol = "minimux_session_destroy", .signature = "void minimux_session_destroy(minimux_session_t *session);", .ownership = "Releases a caller-owned session handle; NULL is accepted." },
    .{ .group = "pane", .symbol = "minimux_pane_create", .signature = "int minimux_pane_create(minimux_session_t *session, const struct minimux_pane_create_options *options, minimux_pane_t **out_pane);", .ownership = "The session and options pointers are borrowed; *out_pane is caller-owned on success." },
    .{ .group = "pane", .symbol = "minimux_pane_send", .signature = "int minimux_pane_send(minimux_pane_t *pane, const uint8_t *bytes, size_t len);", .ownership = "The pane and byte buffer are borrowed for the duration of the call." },
    .{ .group = "pane", .symbol = "minimux_pane_resize", .signature = "int minimux_pane_resize(minimux_pane_t *pane, uint16_t cols, uint16_t rows);", .ownership = "The pane pointer is borrowed for the duration of the call." },
    .{ .group = "snapshot", .symbol = "minimux_pane_snapshot", .signature = "int minimux_pane_snapshot(minimux_pane_t *pane, minimux_snapshot_t **out_snapshot);", .ownership = "On success, *out_snapshot is caller-owned and must be released with minimux_snapshot_destroy." },
    .{ .group = "pane", .symbol = "minimux_pane_close", .signature = "int minimux_pane_close(minimux_pane_t *pane);", .ownership = "The pane pointer is borrowed; closing does not free the handle." },
    .{ .group = "pane", .symbol = "minimux_pane_destroy", .signature = "void minimux_pane_destroy(minimux_pane_t *pane);", .ownership = "Releases a caller-owned pane handle; NULL is accepted." },
    .{ .group = "agent", .symbol = "minimux_agent_wait_idle", .signature = "int minimux_agent_wait_idle(minimux_pane_t *pane, uint64_t timeout_ms, const char *harness);", .ownership = "The pane and harness pointers are borrowed for the duration of the call." },
    .{ .group = "snapshot", .symbol = "minimux_snapshot_destroy", .signature = "void minimux_snapshot_destroy(minimux_snapshot_t *snapshot);", .ownership = "Releases a caller-owned snapshot; NULL is accepted." },
    .{ .group = "recording", .symbol = "minimux_record_start", .signature = "int minimux_record_start(minimux_pane_t *pane, const char *path, const struct minimux_record_policy *policy, minimux_recording_t **out_recording);", .ownership = "The pane, path, and policy are borrowed; *out_recording is caller-owned on success." },
    .{ .group = "recording", .symbol = "minimux_record_stop", .signature = "int minimux_record_stop(minimux_recording_t *recording);", .ownership = "The recording pointer is borrowed; stopping does not free the handle." },
    .{ .group = "recording", .symbol = "minimux_recording_destroy", .signature = "void minimux_recording_destroy(minimux_recording_t *recording);", .ownership = "Releases a caller-owned recording handle; NULL is accepted." },
    .{ .group = "tap", .symbol = "minimux_tap_open", .signature = "int minimux_tap_open(minimux_pane_t *pane, const struct minimux_tap_filter *filter, minimux_tap_t **out_tap);", .ownership = "The pane and filter are borrowed; *out_tap is caller-owned on success." },
    .{ .group = "tap", .symbol = "minimux_tap_close", .signature = "int minimux_tap_close(minimux_tap_t *tap);", .ownership = "The tap pointer is borrowed; closing does not free the handle." },
    .{ .group = "tap", .symbol = "minimux_tap_destroy", .signature = "void minimux_tap_destroy(minimux_tap_t *tap);", .ownership = "Releases a caller-owned tap handle; NULL is accepted." },
    .{ .group = "system", .symbol = "minimux_system_health", .signature = "int minimux_system_health(char *buffer, size_t len);", .ownership = "The caller owns the output buffer and passes its byte length." },
};

pub const FixtureValidationError = error{
    UnsupportedVersion,
    MissingRequiredMethod,
    MissingRequiredErrorCode,
    UnknownMethod,
    UnknownRequiredField,
    InvalidEnumValue,
    MissingRequiredParam,
    ParamRequiredMismatch,
    NonMonotonicSequence,
};

const FixtureParam = struct {
    name: []const u8,
    type: []const u8,
    required: bool,
};

const FixtureMethod = struct {
    name: []const u8,
    params: []const FixtureParam,
};

const FixtureError = struct {
    code: i32,
    name: []const u8,
    category: []const u8,
};

const FixtureEvent = struct {
    seq: u64,
    kind: []const u8,
};

const ProtocolFixture = struct {
    version: []const u8,
    sequence: u64,
    methods: []const FixtureMethod,
    errors: []const FixtureError,
    events: []const FixtureEvent,
};

pub fn validateProtocolFixture(allocator: std.mem.Allocator, bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(ProtocolFixture, allocator, bytes, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const fixture = parsed.value;
    if (!std.mem.eql(u8, fixture.version, protocol_version)) return error.UnsupportedVersion;
    try validateFixtureEvents(fixture.events);
    try validateFixtureMethods(fixture.methods);
    try validateFixtureErrors(fixture.errors);
}

fn validateFixtureMethods(methods: []const FixtureMethod) FixtureValidationError!void {
    for (methods) |method| {
        if (!hasPublicMethod(method.name)) return error.UnknownMethod;
    }

    for (public_methods) |expected| {
        var found = false;
        for (methods) |method| {
            if (std.mem.eql(u8, method.name, expected.wire_name)) {
                found = true;
                try validateFixtureMethodParams(&expected, method.params);
                break;
            }
        }
        if (!found) return error.MissingRequiredMethod;
    }
}

fn validateFixtureMethodParams(expected: *const PublicMethodInfo, params: []const FixtureParam) FixtureValidationError!void {
    for (params) |param| {
        if (!isValidParamType(param.type)) return error.InvalidEnumValue;
        const expected_param = findParamSpec(expected, param.name) orelse {
            if (param.required) return error.UnknownRequiredField;
            continue;
        };
        if (!std.mem.eql(u8, param.type, @tagName(expected_param.field_type))) return error.InvalidEnumValue;
        if (param.required != expected_param.required) return error.ParamRequiredMismatch;
    }

    for (expected.params) |expected_param| {
        if (expected_param.required and !hasFixtureParam(params, expected_param.name)) return error.MissingRequiredParam;
    }
}

fn findParamSpec(method: *const PublicMethodInfo, name: []const u8) ?*const ParamSpec {
    for (method.params) |*param| {
        if (std.mem.eql(u8, param.name, name)) return param;
    }
    return null;
}

fn hasFixtureParam(params: []const FixtureParam, name: []const u8) bool {
    for (params) |param| {
        if (std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

fn isValidParamType(name: []const u8) bool {
    inline for (@typeInfo(ParamType).@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

fn validateFixtureErrors(errors: []const FixtureError) FixtureValidationError!void {
    for (error_codes) |expected| {
        var found = false;
        for (errors) |actual| {
            if (!isValidErrorCategory(actual.category)) return error.InvalidEnumValue;
            if (actual.code == expected.code and std.mem.eql(u8, actual.name, expected.name)) {
                found = true;
            }
        }
        if (!found) return error.MissingRequiredErrorCode;
    }
}

fn isValidErrorCategory(name: []const u8) bool {
    inline for (@typeInfo(ErrorCategory).@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

fn validateFixtureEvents(events: []const FixtureEvent) FixtureValidationError!void {
    var previous: u64 = 0;
    for (events) |event| {
        if (event.seq <= previous) return error.NonMonotonicSequence;
        previous = event.seq;
    }
}

pub fn writeJsonString(writer: *Io.Writer, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (byte < 0x20) {
                    try writer.print("\\u{x:0>4}", .{byte});
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
    try writer.writeAll("\"");
}

pub fn writeStringArray(writer: *Io.Writer, values: []const []const u8) !void {
    try writer.writeAll("[");
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(",");
        try writeJsonString(writer, value);
    }
    try writer.writeAll("]");
}

test "json strings escape control bytes" {
    var buffer: [128]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writeJsonString(&writer, "a\"b\\c\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", writer.buffered());
}

test "protocol metadata covers v0.1.0 surface" {
    try std.testing.expectEqual(@as(usize, 15), public_methods.len);
    try std.testing.expect(hasPublicMethod("session.create"));
    try std.testing.expect(hasPublicMethod("pane.snapshot"));
    try std.testing.expect(hasPublicMethod("agent.wait_idle"));
    try std.testing.expect(hasPublicMethod("system.health"));
    try std.testing.expect(hasErrorCode(-32601));
    try std.testing.expect(hasErrorCode(1001));
    try std.testing.expect(hasErrorCode(2003));
}
