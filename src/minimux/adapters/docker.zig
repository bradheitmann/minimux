const substrate = @import("substrate.zig");

pub const name = "docker";

pub fn adapter() substrate.Adapter {
    return .{
        .name = name,
        .placement = .docker,
        .capabilities = &substrate.required_capabilities,
    };
}

pub fn spawnPlan(request: substrate.SpawnRequest) substrate.SpawnPlan {
    return .{
        .adapter_name = name,
        .placement = .docker,
        .session_name = request.session_name,
        .argv = request.command.argv,
    };
}

pub fn attach(_: substrate.AttachRequest) void {}
pub fn kill(_: substrate.KillRequest) void {}
pub fn wait(_: substrate.WaitRequest) void {}
pub fn networkProxy(_: substrate.NetworkProxyRequest) void {}
