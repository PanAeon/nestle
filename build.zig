const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("nestle", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                // Here "nestle" is the name you will use in your source code to
                // import this module (e.g. `@import("gui_test_wgpu")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "nestle", .module = mod },
            },
        });
    const exe = b.addExecutable(.{
        .name = "nestle",
        .root_module = exe_mod,
    });
    // This is where the interesting part begins.
// As you can see we are re-defining the same executable but
// we're binding it to a dedicated build step.
const exe_check = b.addExecutable(.{
    .name = "foo",
    .root_module = exe_mod,
});
// There is no `b.installArtifact(exe_check);` here.

// Finally we add the "check" step which will be detected
// by ZLS and automatically enable Build-On-Save.
// If you copy this into your `build.zig`, make sure to rename 'foo'
const check = b.step("check", "Check if foo compiles");
check.dependOn(&exe_check.step);

    const zgui = b.dependency("zgui", .{
        .target = target,
        .backend = .glfw_opengl3,
        .shared = true,
        // .with_implot = true,
         .with_freetype = false
    });

    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    const zglfw = b.dependency("zglfw", .{
     .target = target,
    });
        exe.root_module.addImport("zglfw", zglfw.module("root"));
        exe.linkLibrary(zglfw.artifact("glfw"));

     const zopengl = b.dependency("zopengl", .{});
    exe.root_module.addImport("zopengl", zopengl.module("root"));
    
    const zmath = b.dependency("zmath", .{});
    exe.root_module.addImport("zmath", zmath.module("root"));

    const zaudio = b.dependency("zaudio", .{});
    exe.root_module.addImport("zaudio", zaudio.module("root"));
    exe.linkLibrary(zaudio.artifact("miniaudio"));


    const exe_options = b.addOptions();
    exe.root_module.addOptions("build_options", exe_options);
    exe_options.addOption([]const u8, "content_dir", "content/");
    
    const install_content_step = b.addInstallDirectory(.{
        .source_dir = b.path("content"),
        .install_dir = .{ .custom = "" },
        .install_subdir = b.pathJoin(&.{ "bin", "content" }),
    });
    exe.step.dependOn(&install_content_step.step);

    // if (options.target.result.os.tag == .linux) {
    //     if (b.lazyDependency("system_sdk", .{})) |system_sdk| {
    //         exe.addLibraryPath(system_sdk.path("linux/lib/x86_64-linux-gnu"));
    //     }
    // }



        // const zpool = b.dependency("zpool", .{});
        // exe.root_module.addImport("zpool", zpool.module("root"));

     exe.addIncludePath(b.path("src"));
     exe.linkLibC();

    // const zsdl = b.dependency("zsdl", .{});

    // exe.root_module.addImport("zsdl2", zsdl.module("zsdl2"));
    // exe.root_module.addImport("zsdl2_ttf", zsdl.module("zsdl2_ttf"));
    // exe.root_module.addImport("zsdl2_image", zsdl.module("zsdl2_image"));

    // Link against SDL libs
    // linkSdlLibs(exe);

        // const zgpu = b.dependency("zgpu", .{});
        // exe.root_module.addImport("zgpu", zgpu.module("root"));
        // exe.linkLibrary(zgpu.artifact("zdawn"));

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
