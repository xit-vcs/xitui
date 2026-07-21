const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xitui = b.addModule("xitui", .{
        .root_source_file = b.path("src/lib.zig"),
    });

    // try
    {
        const exe = b.addExecutable(.{
            .name = "try",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/try.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("xitui", xitui);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step("try", "Try the widgets");
        run_step.dependOn(&run_cmd.step);
    }

    // test
    {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        unit_tests.root_module.addImport("xitui", xitui);

        // the tests that live inside the library's own files (grid.zig,
        // width.zig, ...) are a separate module from test.zig, so they need
        // their own test compilation to be collected.
        const lib_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        const run_lib_tests = b.addRunArtifact(lib_tests);
        const test_step = b.step("test", "Run library tests");
        test_step.dependOn(&run_unit_tests.step);
        test_step.dependOn(&run_lib_tests.step);
    }
}
