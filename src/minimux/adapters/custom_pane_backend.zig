const std = @import("std");
const proto = @import("../proto.zig");

pub const Operation = enum {
    initialize,
    spawn_agent,
    write,
    capture,
    kill,
    list,
    context_output,
    context_exited,

    pub fn wireName(operation: Operation) []const u8 {
        return switch (operation) {
            .initialize => "initialize",
            .spawn_agent => "spawn_agent",
            .write => "write",
            .capture => "capture",
            .kill => "kill",
            .list => "list",
            .context_output => "context_output",
            .context_exited => "context_exited",
        };
    }
};

pub const required_operations = [_]Operation{
    .initialize,
    .spawn_agent,
    .write,
    .capture,
    .kill,
    .list,
    .context_output,
    .context_exited,
};

pub const MethodBinding = struct {
    operation: Operation,
    minimux_method: []const u8,
    purpose: []const u8,
};

pub const method_bindings = [_]MethodBinding{
    .{ .operation = .initialize, .minimux_method = "system.health", .purpose = "report adapter protocol and minimux availability" },
    .{ .operation = .spawn_agent, .minimux_method = "session.create", .purpose = "create a managed minimux session for an agent process" },
    .{ .operation = .write, .minimux_method = "pane.send", .purpose = "write bytes into a managed pane" },
    .{ .operation = .capture, .minimux_method = "pane.snapshot", .purpose = "capture structured terminal state" },
    .{ .operation = .kill, .minimux_method = "session.terminate", .purpose = "stop a managed session" },
    .{ .operation = .list, .minimux_method = "session.list", .purpose = "list managed sessions" },
    .{ .operation = .context_output, .minimux_method = "tap.open", .purpose = "stream ordered context output events" },
    .{ .operation = .context_exited, .minimux_method = "agent.wait_idle", .purpose = "report process completion state through the harness" },
};

pub const Boundary = struct {
    owns_task_state: bool = false,
    owns_retry_policy: bool = false,
    owns_isolation: bool = false,
    renders_human_terminal: bool = false,

    pub fn validate(boundary: Boundary) !void {
        if (boundary.owns_task_state) return error.AdapterOwnsTaskState;
        if (boundary.owns_retry_policy) return error.AdapterOwnsRetryPolicy;
        if (boundary.owns_isolation) return error.AdapterOwnsIsolation;
        if (boundary.renders_human_terminal) return error.AdapterRendersHumanTerminal;
    }
};

pub const ProtocolManifest = struct {
    protocol: []const u8 = "CustomPaneBackend",
    version: []const u8 = "0.1.0",
    operations: []const Operation = &required_operations,
    boundary: Boundary = .{},

    pub fn hasOperation(manifest: ProtocolManifest, operation: Operation) bool {
        for (manifest.operations) |entry| {
            if (entry == operation) return true;
        }
        return false;
    }

    pub fn complete(manifest: ProtocolManifest) bool {
        for (required_operations) |operation| {
            if (!manifest.hasOperation(operation)) return false;
        }
        return true;
    }
};

pub fn bindingFor(operation: Operation) ?MethodBinding {
    for (method_bindings) |binding| {
        if (binding.operation == operation) return binding;
    }
    return null;
}

pub fn validateManifest(manifest: ProtocolManifest) !void {
    if (!manifest.complete()) return error.MissingCustomPaneBackendOperation;
    try manifest.boundary.validate();
    for (method_bindings) |binding| {
        if (!proto.hasPublicMethod(binding.minimux_method)) return error.MissingMinimuxMethod;
    }
}

pub fn writeManifestJson(writer: *std.Io.Writer, manifest: ProtocolManifest) !void {
    try writer.writeAll("{\"protocol\":");
    try proto.writeJsonString(writer, manifest.protocol);
    try writer.writeAll(",\"version\":");
    try proto.writeJsonString(writer, manifest.version);
    try writer.writeAll(",\"operations\":[");
    for (manifest.operations, 0..) |operation, index| {
        if (index != 0) try writer.writeAll(",");
        try proto.writeJsonString(writer, operation.wireName());
    }
    try writer.writeAll("],\"bindings\":[");
    for (method_bindings, 0..) |binding, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"operation\":");
        try proto.writeJsonString(writer, binding.operation.wireName());
        try writer.writeAll(",\"minimux_method\":");
        try proto.writeJsonString(writer, binding.minimux_method);
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"boundary\":{\"owns_task_state\":false,\"owns_retry_policy\":false,\"owns_isolation\":false,\"renders_human_terminal\":false}}");
}

test "custom pane backend manifest is complete and bound to public minimux methods" {
    const manifest: ProtocolManifest = .{};
    try validateManifest(manifest);
    try std.testing.expect(manifest.complete());
    try std.testing.expectEqualStrings("pane.snapshot", bindingFor(.capture).?.minimux_method);
}

test "custom pane backend boundary rejects upstream ownership" {
    try std.testing.expectError(error.AdapterOwnsTaskState, validateManifest(.{
        .boundary = .{ .owns_task_state = true },
    }));
    try std.testing.expectError(error.AdapterOwnsRetryPolicy, validateManifest(.{
        .boundary = .{ .owns_retry_policy = true },
    }));
    try std.testing.expectError(error.AdapterRendersHumanTerminal, validateManifest(.{
        .boundary = .{ .renders_human_terminal = true },
    }));
}
