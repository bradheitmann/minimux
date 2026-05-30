const std = @import("std");
const minimux = @import("minimux");

test "adapter manifest covers CustomPaneBackend operations" {
    const manifest: minimux.adapters.custom_pane_backend.ProtocolManifest = .{};
    try minimux.adapters.custom_pane_backend.validateManifest(manifest);
    inline for (minimux.adapters.custom_pane_backend.required_operations) |operation| {
        try std.testing.expect(manifest.hasOperation(operation));
        try std.testing.expect(minimux.adapters.custom_pane_backend.bindingFor(operation) != null);
    }

    var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer json.deinit();
    try minimux.adapters.custom_pane_backend.writeManifestJson(&json.writer, manifest);
    const text = json.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"spawn_agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"context_exited\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"pane.snapshot\"") != null);
}

test "substrate adapters expose baremetal and docker placement capabilities" {
    const baremetal = minimux.adapters.baremetal.adapter();
    const docker = minimux.adapters.docker.adapter();
    try std.testing.expect(baremetal.supportsRequired());
    try std.testing.expect(docker.supportsRequired());
    inline for (minimux.adapters.substrate.required_capabilities) |capability| {
        try std.testing.expect(baremetal.supports(capability));
        try std.testing.expect(docker.supports(capability));
    }
}

test "adapter plans stay below upstream ownership boundaries" {
    const request: minimux.adapters.substrate.SpawnRequest = .{
        .session_name = "agent-alpha",
        .command = .{ .argv = &.{ "bash", "-lc", "echo ok" } },
    };
    const baremetal_plan = minimux.adapters.baremetal.spawnPlan(request);
    const docker_plan = minimux.adapters.docker.spawnPlan(request);
    try minimux.adapters.substrate.validateBoundary(baremetal_plan);
    try minimux.adapters.substrate.validateBoundary(docker_plan);

    var bad = docker_plan;
    bad.owns_isolation = true;
    try std.testing.expectError(error.AdapterOwnsIsolation, minimux.adapters.substrate.validateBoundary(bad));
}
