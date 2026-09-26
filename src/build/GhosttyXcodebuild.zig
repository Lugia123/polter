const Ghostty = @This();

const std = @import("std");
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;
const PolterVersion = @import("PolterVersion.zig");
const Config = @import("Config.zig");
const Docs = @import("GhosttyDocs.zig");
const I18n = @import("GhosttyI18n.zig");
const Resources = @import("GhosttyResources.zig");
const XCFramework = @import("GhosttyXCFramework.zig");

build: *std.Build.Step.Run,
open: *std.Build.Step.Run,
copy: *std.Build.Step.Run,
xctest: *std.Build.Step.Run,

pub const Deps = struct {
    xcframework: *const XCFramework,
    docs: *const Docs,
    i18n: ?*const I18n,
    resources: *const Resources,
};

pub fn init(
    b: *std.Build,
    config: *const Config,
    deps: Deps,
) !Ghostty {
    const xc_config = switch (config.optimize) {
        .Debug => "Debug",
        .ReleaseSafe,
        .ReleaseSmall,
        .ReleaseFast,
        => "ReleaseLocal",
    };

    const xc_arch: ?[]const u8 = switch (deps.xcframework.target) {
        // Universal is our default target, so we don't have to
        // add anything.
        .universal => null,

        // Native we need to override the architecture in the Xcode
        // project with the -arch flag.
        .native => switch (builtin.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => @panic("unsupported macOS arch"),
        },
    };

    const env = b.graph.environ_map;
    // The bundle is named for the product, not for the Xcode target: the
    // target is still called Ghostty, and renaming it would churn the
    // project file for nothing. Getting this wrong fails `zig build` at
    // the very last step, after everything has already been compiled.
    const app_path = b.fmt("macos/build/{s}/Polter.app", .{xc_config});

    // Our step to build the Ghostty macOS app.
    const build = build: {
        // External environment variables can mess up xcodebuild, so
        // we create a new empty environment.
        const env_map = try b.allocator.create(std.process.Environ.Map);
        env_map.* = .init(b.allocator);
        if (env.get("PATH")) |v| try env_map.put("PATH", v);

        const step = RunStep.create(b, "xcodebuild");
        step.has_side_effects = true;
        step.cwd = b.path("macos");
        step.environ_map = env_map;
        step.addArgs(&.{
            "xcodebuild",
            "-target",
            "Ghostty",
            "-configuration",
            xc_config,
        });

        // Polter's own version, not Ghostty's. Passed as build settings
        // rather than written into the project file so that the number
        // follows the repository -- the project file would have to be
        // edited, and committed, on every single commit.
        //
        // `POLTER_COMMIT` reaches the bundle through `$(POLTER_COMMIT)` in
        // the Info.plist. Empty is fine and means the About window leaves
        // the row out.
        //
        // `POLTER_VERSION_SOURCE` reaches it the same way, through
        // `$(POLTER_VERSION_SOURCE)` -> `PolterVersionSource`. Task 651:
        // `GitHubUpdateChecker` reads it to tell a real `0.1.x` (however
        // unlikely) apart from "this build could not say what version it
        // is" -- see `PolterVersion.Source`'s doc comment for why that
        // distinction cannot be reconstructed from `MARKETING_VERSION` alone.
        const vsn = PolterVersion.detect(b);
        step.addArgs(&.{
            b.fmt("MARKETING_VERSION={s}", .{vsn.string}),
            b.fmt("CURRENT_PROJECT_VERSION={d}", .{vsn.count}),
            b.fmt("POLTER_COMMIT={s}", .{vsn.commit}),
            b.fmt("POLTER_VERSION_SOURCE={s}", .{@tagName(vsn.source)}),
        });

        // The signing identity, read here and passed as a build setting for
        // the same reason the version is: a certificate belongs to one
        // machine, and one written into the project file would be committed
        // and then be wrong for everybody else.
        //
        // Left unset, the project's own `CODE_SIGN_IDENTITY = "-"` stands and
        // the app is signed ad-hoc -- which is what CI and anyone without a
        // certificate gets, and what this repository shipped until now.
        //
        // **Why it is worth setting.** An ad-hoc signature carries no team
        // identifier, so macOS can only identify the app by its cdhash, and a
        // cdhash is a hash of the contents: it changes on every rebuild. TCC
        // records its grants (Accessibility, Screen Recording) against that
        // identity, so **every reinstall silently voids them** -- silently
        // because System Settings keeps drawing the toggle as on. It reads
        // `auth_value`; the check uses the code identity. Measured 2026-09-26:
        // the grants were written 09-18, the binary was replaced 09-23, and
        // the three preflights had been returning false ever since while the
        // switches looked fine.
        //
        // ⚠️ The environment here is deliberately empty except for PATH (see
        // above), so this has to be read on the Zig side and handed over as an
        // argument -- exporting it for xcodebuild would not survive.
        //
        // ⚠️⚠️ `POLTER_CODESIGN_IDENTITY` must be the *generic* name
        // ("Apple Development"), not the full certificate name. The project
        // signs automatically, and automatic signing rejects a specific
        // identity outright:
        //
        //     Ghostty has conflicting provisioning settings. Ghostty is
        //     automatically signed, but code signing identity
        //     Apple Development: … has been manually specified.
        //
        // xcodebuild then exits 65 and the build fails at the very last step,
        // after everything else has compiled. Which certificate gets used is
        // decided by DEVELOPMENT_TEAM, not by naming it here.
        if (env.get("POLTER_CODESIGN_IDENTITY")) |identity| {
            step.addArgs(&.{b.fmt("CODE_SIGN_IDENTITY={s}", .{identity})});

            // Only meaningful alongside an identity: it is what lets TCC key a
            // grant to "this team's build of this bundle id" rather than to
            // one exact binary.
            if (env.get("POLTER_DEVELOPMENT_TEAM")) |team| {
                step.addArgs(&.{b.fmt("DEVELOPMENT_TEAM={s}", .{team})});
            }
        }

        // If we have a specific architecture, we need to pass it
        // to xcodebuild.
        if (xc_arch) |arch| step.addArgs(&.{ "-arch", arch });

        // We need the xcframework
        deps.xcframework.addStepDependencies(&step.step);

        // We also need all these resources because the xcode project
        // references them via symlinks.
        deps.resources.addStepDependencies(&step.step);
        if (deps.i18n) |v| v.addStepDependencies(&step.step);
        deps.docs.installDummy(&step.step);

        // Expect success
        step.expectExitCode(0);

        break :build step;
    };

    const xctest = xctest: {
        const env_map = try b.allocator.create(std.process.Environ.Map);
        env_map.* = .init(b.allocator);
        if (env.get("PATH")) |v| try env_map.put("PATH", v);

        const step = RunStep.create(b, "xcodebuild test");
        step.has_side_effects = true;
        step.cwd = b.path("macos");
        step.environ_map = env_map;
        step.addArgs(&.{
            "xcodebuild",
            "test",
            "-scheme",
            "Ghostty",
            "-skip-testing",
            "GhosttyUITests",
        });
        if (xc_arch) |arch| step.addArgs(&.{ "-arch", arch });

        // We need the xcframework
        deps.xcframework.addStepDependencies(&step.step);

        // We also need all these resources because the xcode project
        // references them via symlinks.
        deps.resources.addStepDependencies(&step.step);
        if (deps.i18n) |v| v.addStepDependencies(&step.step);
        deps.docs.installDummy(&step.step);

        // Expect success
        step.expectExitCode(0);

        break :xctest step;
    };

    // Our step to open the resulting Ghostty app.
    const open = open: {
        const disable_save_state = RunStep.create(b, "disable save state");
        disable_save_state.has_side_effects = true;
        disable_save_state.addArgs(&.{
            "/usr/libexec/PlistBuddy",
            "-c",
            // We'll have to change this to `Set` if we ever put this
            // into our Info.plist.
            "Add :NSQuitAlwaysKeepsWindows bool false",
            b.fmt("{s}/Contents/Info.plist", .{app_path}),
        });
        disable_save_state.expectExitCode(0);
        disable_save_state.step.dependOn(&build.step);

        const open = RunStep.create(b, "run Polter app");
        open.has_side_effects = true;
        open.cwd = b.path("");

        // The binary is named for the product. This said `ghostty` until
        // the rename, which made `zig build run` fail with a path that does
        // not exist -- silently, because nobody runs it on macOS.
        open.addArgs(&.{b.fmt(
            "{s}/Contents/MacOS/polter",
            .{app_path},
        )});

        // Open depends on the app
        open.step.dependOn(&build.step);
        open.step.dependOn(&disable_save_state.step);

        // This overrides our default behavior and forces logs to show
        // up on stderr (in addition to the centralized macOS log).
        open.setEnvironmentVariable("GHOSTTY_LOG", "stderr,macos");

        // Configure how we're launching
        open.setEnvironmentVariable("GHOSTTY_MAC_LAUNCH_SOURCE", "zig_run");

        if (b.args) |args| {
            open.addArgs(args);
        }

        break :open open;
    };

    // Our step to copy the app bundle to the install path.
    // We have to use `cp -R` because there are symlinks in the
    // bundle.
    const copy = copy: {
        const step = RunStep.create(b, "copy app bundle");
        step.addArgs(&.{ "cp", "-R" });
        step.addFileArg(b.path(app_path));
        step.addArg(b.fmt("{s}", .{b.install_path}));
        step.step.dependOn(&build.step);
        break :copy step;
    };

    return .{
        .build = build,
        .open = open,
        .copy = copy,
        .xctest = xctest,
    };
}

pub fn install(self: *const Ghostty) void {
    const b = self.copy.step.owner;
    b.getInstallStep().dependOn(&self.copy.step);
}

pub fn installXcframework(self: *const Ghostty) void {
    const b = self.build.step.owner;
    b.getInstallStep().dependOn(&self.build.step);
}

pub fn addTestStepDependencies(
    self: *const Ghostty,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(&self.xctest.step);
}
