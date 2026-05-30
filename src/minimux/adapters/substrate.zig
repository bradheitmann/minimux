const std = @import("std");

pub const PlacementKind = enum {
    baremetal,
    docker,

    pub fn label(kind: PlacementKind) []const u8 {
        return switch (kind) {
            .baremetal => "baremetal",
            .docker => "docker",
        };
    }
};

pub const Capability = enum {
    spawn,
    attach,
    kill,
    wait,
    network_proxy,

    pub fn label(capability: Capability) []const u8 {
        return switch (capability) {
            .spawn => "spawn",
            .attach => "attach",
            .kill => "kill",
            .wait => "wait",
            .network_proxy => "network_proxy",
        };
    }
};

pub const forbidden_ownership = [_][]const u8{
    "task retry loops",
    "task-state stores",
    "sandbox enforcement engines",
    "operator terminal surfaces",
};

pub const CommandSpec = struct {
    argv: []const []const u8,
    cwd: []const u8 = "",
    env: []const []const u8 = &.{},
};

pub const SpawnRequest = struct {
    session_name: []const u8,
    command: CommandSpec,
};

pub const SpawnPlan = struct {
    adapter_name: []const u8,
    placement: PlacementKind,
    session_name: []const u8,
    argv: []const []const u8,
    owns_isolation: bool = false,
    owns_task_state: bool = false,
    owns_retry_policy: bool = false,
    renders_human_terminal: bool = false,
};

pub const AttachRequest = struct {
    session_name: []const u8,
};

pub const KillRequest = struct {
    session_name: []const u8,
    signal: []const u8 = "TERM",
};

pub const WaitRequest = struct {
    session_name: []const u8,
    timeout_ms: u64,
};

pub const NetworkProxyRequest = struct {
    session_name: []const u8,
    listen: []const u8,
    target: []const u8,
};

pub const Adapter = struct {
    name: []const u8,
    placement: PlacementKind,
    capabilities: []const Capability,

    pub fn supports(adapter: Adapter, capability: Capability) bool {
        for (adapter.capabilities) |entry| {
            if (entry == capability) return true;
        }
        return false;
    }

    pub fn supportsRequired(adapter: Adapter) bool {
        inline for (required_capabilities) |capability| {
            if (!adapter.supports(capability)) return false;
        }
        return true;
    }
};

pub const required_capabilities = [_]Capability{
    .spawn,
    .attach,
    .kill,
    .wait,
    .network_proxy,
};

pub fn validateBoundary(plan: SpawnPlan) !void {
    if (plan.owns_isolation) return error.AdapterOwnsIsolation;
    if (plan.owns_task_state) return error.AdapterOwnsTaskState;
    if (plan.owns_retry_policy) return error.AdapterOwnsRetryPolicy;
    if (plan.renders_human_terminal) return error.AdapterRendersHumanTerminal;
}

pub fn writeAdapterJson(writer: *std.Io.Writer, adapter: Adapter) !void {
    try writer.print("{{\"name\":\"{s}\",\"placement\":\"{s}\",\"capabilities\":[", .{
        adapter.name,
        adapter.placement.label(),
    });
    for (adapter.capabilities, 0..) |capability, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("\"{s}\"", .{capability.label()});
    }
    try writer.writeAll("]}");
}

test "substrate adapter requires placement capabilities" {
    const adapter: Adapter = .{
        .name = "test",
        .placement = .baremetal,
        .capabilities = &required_capabilities,
    };
    try std.testing.expect(adapter.supportsRequired());
    try std.testing.expect(adapter.supports(.network_proxy));
}

test "substrate boundary rejects upstream ownership" {
    try validateBoundary(.{
        .adapter_name = "baremetal",
        .placement = .baremetal,
        .session_name = "alpha",
        .argv = &.{"bash"},
    });
    try std.testing.expectError(error.AdapterOwnsRetryPolicy, validateBoundary(.{
        .adapter_name = "bad",
        .placement = .docker,
        .session_name = "alpha",
        .argv = &.{"bash"},
        .owns_retry_policy = true,
    }));
    try std.testing.expectError(error.AdapterOwnsIsolation, validateBoundary(.{
        .adapter_name = "bad",
        .placement = .docker,
        .session_name = "alpha",
        .argv = &.{"bash"},
        .owns_isolation = true,
    }));
}
