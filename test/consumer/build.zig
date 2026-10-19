const std = @import("std");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("minimux", .{ .target = b.graph.host });
    const module = b.createModule(.{
        .root_source_file = b.path("consumer.zig"),
        .target = b.graph.host,
        .link_libc = true,
    });
    module.addImport("full", dep.module("minimux"));
    module.addImport("control", dep.module("minimux_control"));
    module.addImport("proto", dep.module("minimux_proto"));
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Compile and run combined public modules").dependOn(&b.addRunArtifact(tests).step);
}
