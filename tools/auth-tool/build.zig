const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Windows-only tool. Refuse non-Windows targets up front with a clear message.
    if (target.result.os.tag != .windows) {
        std.log.err("zed2api-auth targets Windows only (got {s}). Use the original zed2api binary's login flow on other platforms.", .{@tagName(target.result.os.tag)});
    }

    const exe = b.addExecutable(.{
        .name = "zed2api-auth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Link the shared auth module from the main project instead of duplicating it.
    exe.root_module.addImport("auth", b.createModule(.{
        .root_source_file = b.path("../../src/auth.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));

    exe.root_module.linkSystemLibrary("bcrypt", .{});
    exe.root_module.linkSystemLibrary("advapi32", .{});
    exe.root_module.linkSystemLibrary("crypt32", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the auth tool");
    run_step.dependOn(&run_cmd.step);
}
