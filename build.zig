const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose names contain this filter");
    const test_filters: []const []const u8 = if (test_filter) |filter|
        b.dupeStrings(&.{filter})
    else
        &.{};

    const minimux_mod = b.addModule("minimux", .{
        .root_source_file = b.path("src/minimux/root.zig"),
        .target = target,
        .link_libc = true,
    });
    const minimux_proto_mod = b.addModule("minimux_proto", .{
        .root_source_file = b.path("src/minimux/proto.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "minimux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/minimux.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const gen_header = b.addExecutable(.{
        .name = "gen-c-header",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen-c-header.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux_proto", .module = minimux_proto_mod },
            },
        }),
    });
    const run_gen_header = b.addRunArtifact(gen_header);
    run_gen_header.addArg("include/minimux.h");
    b.getInstallStep().dependOn(&run_gen_header.step);

    const gen_header_step = b.step("gen-c-header", "Regenerate include/minimux.h");
    gen_header_step.dependOn(&run_gen_header.step);

    const c_smoke_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_smoke_mod.addIncludePath(b.path("include"));
    c_smoke_mod.addCSourceFile(.{
        .file = b.path("examples/c/minimux_smoke.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    const c_smoke_exe = b.addExecutable(.{
        .name = "minimux_c_smoke",
        .root_module = c_smoke_mod,
    });
    const run_c_smoke = b.addRunArtifact(c_smoke_exe);
    run_c_smoke.step.dependOn(&run_gen_header.step);

    const c_smoke_step = b.step("c-smoke", "Compile and run the generated C header smoke test");
    c_smoke_step.dependOn(&run_c_smoke.step);

    const run_step = b.step("run", "Run minimux");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const root_tests = b.addTest(.{
        .root_module = minimux_mod,
        .filters = test_filters,
    });
    const run_root_tests = b.addRunArtifact(root_tests);

    const cli_tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters = test_filters,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const spec_scope_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/spec_scope_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_spec_scope_tests = b.addRunArtifact(spec_scope_tests);

    const prototype_recovery_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/prototype_recovery_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_prototype_recovery_tests = b.addRunArtifact(prototype_recovery_tests);

    const session_lifecycle_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/session_lifecycle_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_session_lifecycle_tests = b.addRunArtifact(session_lifecycle_tests);

    const pty_lifecycle_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/pty_lifecycle_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_pty_lifecycle_tests = b.addRunArtifact(pty_lifecycle_tests);

    const protocol_fixture_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/protocol_fixture_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_protocol_fixture_tests = b.addRunArtifact(protocol_fixture_tests);

    const recovery_engine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/recovery_engine_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_recovery_engine_tests = b.addRunArtifact(recovery_engine_tests);

    const snapshot_fixture_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/snapshot_fixture_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_snapshot_fixture_tests = b.addRunArtifact(snapshot_fixture_tests);

    const observe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/observe_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_observe_tests = b.addRunArtifact(observe_tests);

    const minimux_cli_mod = b.createModule(.{
        .root_source_file = b.path("cmd/minimux.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "minimux", .module = minimux_mod },
        },
    });

    const cli_envelope_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/cli_envelope_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
                .{ .name = "minimux_cli", .module = minimux_cli_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_cli_envelope_tests = b.addRunArtifact(cli_envelope_tests);

    const transport_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/transport_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_transport_tests = b.addRunArtifact(transport_tests);

    const adapter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/custom_pane_backend_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
            },
        }),
        .filters = test_filters,
    });
    const run_adapter_tests = b.addRunArtifact(adapter_tests);

    const transport_fuzz = b.addExecutable(.{
        .name = "transport-frame-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz/transport_frame_fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minimux", .module = minimux_mod },
            },
        }),
    });
    const run_transport_fuzz = b.addRunArtifact(transport_fuzz);
    if (b.args) |args| run_transport_fuzz.addArgs(args);

    const fuzz_transport_step = b.step("fuzz-transport", "Run encrypted transport frame fuzz smoke");
    fuzz_transport_step.dependOn(&run_transport_fuzz.step);

    const release_check_cmd = b.addSystemCommand(&.{ "bash", "scripts/validate-release.sh" });
    release_check_cmd.step.dependOn(b.getInstallStep());
    const release_check_step = b.step("release-check", "Run the release validation command set");
    release_check_step.dependOn(&release_check_cmd.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_root_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_spec_scope_tests.step);
    test_step.dependOn(&run_prototype_recovery_tests.step);
    test_step.dependOn(&run_session_lifecycle_tests.step);
    test_step.dependOn(&run_pty_lifecycle_tests.step);
    test_step.dependOn(&run_protocol_fixture_tests.step);
    test_step.dependOn(&run_recovery_engine_tests.step);
    test_step.dependOn(&run_snapshot_fixture_tests.step);
    test_step.dependOn(&run_observe_tests.step);
    test_step.dependOn(&run_cli_envelope_tests.step);
    test_step.dependOn(&run_transport_tests.step);
    test_step.dependOn(&run_adapter_tests.step);
}
