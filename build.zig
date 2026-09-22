const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // When true (default), the build shells out to Node to run tsc + vite and build
    // the WebUI into webui/dist/index.html before embedding it. When false, the build
    // skips those steps and embeds whatever webui/dist/index.html already exists on
    // disk — useful for CI/Docker where the WebUI is built in a separate stage and
    // Node is not available to the Zig builder.
    const build_webui = b.option(bool, "webui", "Build the WebUI with Node (default: true)") orelse true;

    const node_cmd = if (b.graph.host.result.os.tag == .windows) "node.exe" else "node";

    // Zig module — the HTML is embedded via addAnonymousImport, which reads
    // webui/dist/index.html at compile time. So the exe compile must run AFTER the
    // WebUI build (when enabled).
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addAnonymousImport("web_index_html", .{ .root_source_file = b.path("webui/dist/index.html") });

    const exe = b.addExecutable(.{
        .name = "zed2api",
        .root_module = mod,
    });

    if (build_webui) {
        const tsc_build = b.addSystemCommand(&.{ node_cmd, "node_modules/typescript/bin/tsc" });
        tsc_build.setCwd(b.path("webui"));
        const vite_build = b.addSystemCommand(&.{ node_cmd, "node_modules/vite/bin/vite.js", "build" });
        vite_build.setCwd(b.path("webui"));
        vite_build.step.dependOn(&tsc_build.step);

        // The embedded HTML must exist before the Zig compile reads it.
        exe.step.dependOn(&vite_build.step);
    }

    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("bcrypt", .{});
        exe.root_module.linkSystemLibrary("advapi32", .{});
        exe.root_module.linkSystemLibrary("crypt32", .{});
        exe.root_module.linkSystemLibrary("ws2_32", .{});
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zed2api server");
    run_step.dependOn(&run_cmd.step);
}
