const std = @import("std");
const builtin = @import("builtin");

pub const version = "0.1.0";
pub const product_name = "minimux";
pub const status = "prototype";
pub const zig_minimum_version = "0.16.0";

pub const adapters = struct {
    pub const baremetal = @import("adapters/baremetal.zig");
    pub const custom_pane_backend = @import("adapters/custom_pane_backend.zig");
    pub const docker = @import("adapters/docker.zig");
    pub const substrate = @import("adapters/substrate.zig");
};
pub const daemon = @import("daemon.zig");
pub const crypto = @import("crypto.zig");
pub const domain = @import("domain.zig");
pub const errors = @import("errors.zig");
pub const platform = switch (builtin.os.tag) {
    .linux => @import("platform/linux.zig"),
    else => @import("platform/darwin.zig"),
};
pub const proto = @import("proto.zig");
pub const pty = @import("pty.zig");
pub const journal = @import("journal.zig");
pub const harness_shell = @import("harness_shell.zig");
pub const observe = @import("observe.zig");
pub const recovery = @import("recovery.zig");
pub const shadow = @import("shadow.zig");
pub const snapshot = @import("snapshot.zig");
pub const snapshot_store = @import("snapshot_store.zig");
pub const session = @import("session.zig");
pub const transport = @import("transport.zig");

pub const Boundary = struct {
    pub const decision_filter =
        "Keeps the terminal intact across agent crashes inside the substrate the operator chose and beneath the orchestrator the operator controls.";

    pub const in_scope = [_][]const u8{
        "per-session daemon process",
        "managed PTY ownership",
        "local JSON-RPC control socket",
        "local PTY input and output stream endpoint",
        "structured VT snapshot",
        "append-only journal and atomic snapshot recovery",
        "recording and tap streams",
        "shell-generic wait-idle harness",
        "encrypted remote transport",
        "CustomPaneBackend adapter",
        "baremetal and Docker placement adapters",
    };

    pub const non_goals = [_][]const u8{
        "operator-facing terminal interface",
        "workflow scheduler",
        "sandbox enforcement engine",
        "plaintext remote transport",
        "terminal multiplexer compatibility claim",
    };
};

pub const PrototypeCommand = enum {
    run,
    send,
    wait_idle,
    snapshot,
};

pub const PublicMethod = proto.PublicMethod;
pub const PublicMethodInfo = proto.PublicMethodInfo;
pub const public_methods = proto.public_methods;
pub const error_codes = proto.error_codes;
pub const hasPublicMethod = proto.hasPublicMethod;
pub const hasErrorCode = proto.hasErrorCode;

pub fn isNonGoal(text: []const u8) bool {
    for (Boundary.non_goals) |entry| {
        if (std.mem.eql(u8, entry, text)) return true;
    }
    return false;
}

test "public method table contains required v0.1.0 methods" {
    try std.testing.expectEqual(@as(usize, 15), public_methods.len);
    try std.testing.expect(hasPublicMethod("session.create"));
    try std.testing.expect(hasPublicMethod("pane.snapshot"));
    try std.testing.expect(hasPublicMethod("agent.wait_idle"));
    try std.testing.expect(hasPublicMethod("system.health"));
    try std.testing.expectEqualStrings("CONTROL_REQUEST", proto.remoteFrameKindName(.control_request));
    const adapter_manifest: adapters.custom_pane_backend.ProtocolManifest = .{};
    try std.testing.expect(adapter_manifest.complete());
}

test "boundary excludes upstream ownership" {
    try std.testing.expect(isNonGoal("workflow scheduler"));
    try std.testing.expect(isNonGoal("sandbox enforcement engine"));
    try std.testing.expect(isNonGoal("operator-facing terminal interface"));
    try std.testing.expect(isNonGoal("plaintext remote transport"));
}

test {
    _ = adapters;
    _ = daemon;
    _ = crypto;
    _ = domain;
    _ = errors;
    _ = harness_shell;
    _ = observe;
    _ = platform;
    _ = proto;
    _ = pty;
    _ = journal;
    _ = recovery;
    _ = shadow;
    _ = snapshot;
    _ = snapshot_store;
    _ = session;
    _ = transport;
}
