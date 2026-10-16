// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pie = b.option(bool, "pie", "Build with PIE support (by default: target-dependant)");
    const strip = b.option(bool, "strip", "Strip debugging info (by default true)") orelse true;

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (strip) _strip(main_mod);
    main_mod.linkSystemLibrary("ncursesw", .{});
    main_mod.linkSystemLibrary("zstd", .{});

    const folly_memcpy = b.option(bool, "folly-memcpy", "override memcpy/memmove with folly AVX2 asm (x86_64+AVX2 only)") orelse true;

    const has_avx2 = target.result.cpu.arch == .x86_64 and
        std.Target.x86.featureSetHas(target.result.cpu.features, .avx2);

    if (has_avx2 and folly_memcpy) {
        main_mod.addCSourceFile(.{
            .file = b.path("deps/folly/memcpy.S"),
            .flags = &.{ "-mavx2", "-D__AVX2__=1", "-DFOLLY_MEMCPY_IS_MEMCPY" },
        });
    }

    if (has_avx2) {
        main_mod.addCSourceFile(.{
            .file = b.path("deps/folly/memset.S"),
            .flags = &.{ "-mavx2", "-D__AVX2__=1", "-DFOLLY_MEMSET_IS_MEMSET" },
        });
    }

    const exe = b.addExecutable(.{
        .name = "ncdu",
        .root_module = main_mod,
    });

    if (strip) strip_step(exe);

    exe.pie = pie;
    // https://github.com/ziglang/zig/blob/faccd79ca5debbe22fe168193b8de54393257604/build.zig#L745-L748
    if (target.result.os.tag.isDarwin()) {
        // useful for package maintainers
        exe.headerpad_max_install_names = true;
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = main_mod,
    });
    unit_tests.pie = pie;

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn strip_step(step: *std.Build.Step.Compile) void {
    if (step.root_module.optimize != .Debug and step.root_module.optimize != .ReleaseSafe) {
        step.use_llvm = true;
        step.link_eh_frame_hdr = false;
        step.link_emit_relocs = false;
        step.lto = .full;
        step.bundle_compiler_rt = true;
        step.root_module.stack_check = false;
        step.root_module.stack_protector = false;
        step.pie = false;
        if (step.root_module.optimize == .ReleaseSafe) step.bundle_ubsan_rt = true else step.bundle_ubsan_rt = false;
        step.link_gc_sections = true;
        step.link_function_sections = true;
        step.link_data_sections = true;
        step.discard_local_symbols = true;
        step.compress_debug_sections = .none;
    } else {
        step.use_llvm = true;
        step.lto = .none;
    }
    if (@hasField(std.meta.Child(@TypeOf(step)), "llvm_codegen_threads"))
        step.llvm_codegen_threads = step.llvm_codegen_threads orelse 0;
}

fn _strip(root_module: *std.Build.Module) void {
    if (root_module.optimize != .Debug and root_module.optimize != .ReleaseSafe) {
        root_module.strip = true;
        root_module.omit_frame_pointer = true;
        root_module.unwind_tables = .none;
        root_module.valgrind = false;
        root_module.sanitize_c = .off;
    } else {
        root_module.strip = false;
        root_module.omit_frame_pointer = false;
        root_module.unwind_tables = .sync;
        root_module.sanitize_c = .off;
        root_module.valgrind = true;
        // root_module.sanitize_thread = true;
    }
}
