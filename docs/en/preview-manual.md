# Development Preview Manual

> Last updated against git commit: `f81dcadc8`
> (`f81dcadc82ea2afdcf2dc92929037701122f05b5`, 2026-08-14)
> How to check: `git log -1 --format='%H %h %ad %s'`
>
> English translation of [`../preview-manual.md`](../preview-manual.md), which
> is the original and wins if the two disagree. Terminology follows
> [`GLOSSARY.md`](GLOSSARY.md).

## What this document covers

- The dependencies and minimum versions needed to build Ghostty.
- The shortest path from "I changed a line" to "I can see it": three of them,
  for Linux/FreeBSD, for macOS, and for libghostty-vt.
- A quick reference for `zig build` options, and the switches that actually
  shorten the iteration loop.
- The ways to observe and verify what you built: logging (`GHOSTTY_LOG`), the
  inspector, unit tests, Valgrind, benchmarks.
- The formatting and lint checklist to run before committing, and the traps
  people most often fall into when building or running.

**This document is the single authority for this repository's build and run
commands.** [`CONTRIBUTING.md:22`](../../CONTRIBUTING.md) says the same, and
so does [`docs/README.md:20`](../README.md).

## What this document does not cover

- The thread model, module responsibilities and startup call chains — see
  [`architecture.md`](architecture.md).
- VT parsing, `Screen`/`PageList`/`Page`, the kitty and OSC protocols — see
  [`terminal-core.md`](../terminal-core.md).
- Renderer backends, shaders, and the font and glyph stack — see
  [`rendering-and-font.md`](../rendering-and-font.md).
- The application runtime (apprt), the Swift side under `macos/`, the
  configuration system, the internals of keybindings — see
  [`platform-and-config.md`](../platform-and-config.md).
- The contribution process and the AI policy — see
  [`CONTRIBUTING.md`](../../CONTRIBUTING.md) and
  [`AI_POLICY.md`](../../AI_POLICY.md). Not repeated here.
- The end-user configuration reference, which lives on the upstream site and
  not in this repository.

## How much to trust the commands in here

Every command below is annotated with where in the repository it came from:
`build.zig`, `src/build/*.zig`, `AGENTS.md`, `macos/AGENTS.md`, `HACKING.md`,
the various subdirectory `AGENTS.md` files, and
`.github/workflows/test.yml`.

This document was first written on a machine with no zig installed, so at the
time every command here had been read out of a build script and nothing more.
Zig 0.16.0 was installed later and a good deal of it has since actually been
run, so there are now two categories:

- **Actually run**: `zig build`, `zig build test` (with assorted `-D`
  combinations), `zig test <file>`, the full test suite inside a container,
  `swiftc -typecheck`. Every command in "Developing on macOS without a full
  Xcode" below has been run.
- **Still not run (not verified)**: `macos/build.nu` (needs a full Xcode),
  `zig build run`, Valgrind, the Nix VMs, and actually running the benchmarks.
  These rest on reading the build scripts and nothing else.

To confirm whether an option exists today and what its default is, the actual
output of `zig build --help` and `src/build/Config.zig` win — which is what the
comment at `build.zig:20-22` recommends too.

## In one sentence

Ghostty's core is Zig and `zig build` is the only build entry point
(`build.zig:19`). On Linux and FreeBSD `app_runtime` defaults to `gtk` and a
single `zig build run` gets you running; on macOS `app_runtime` defaults to
`none` (`src/apprt/runtime.zig:14-24`) and the GUI is built separately by
Xcode, which makes it a two-stage build: Zig first, Xcode second.

## Map of the important files

| Path                              | Lines | Responsibility                                                      |
| --------------------------------- | ----- | ------------------------------------------------------------------- |
| `build.zig`                       | 420   | The build entry point; declares every build step                    |
| `src/build/Config.zig`            | 803   | Every `-D` option and its default                                   |
| `src/build/GhosttyXcodebuild.zig` | 203   | The xcodebuild / open / xctest steps for the macOS app              |
| `macos/build.nu`                  | 32    | The recommended build script for the macOS app                      |
| `HACKING.md`                      | 487   | Dependencies, logging, lint, Valgrind, the Nix VMs                  |
| `AGENTS.md`                       | 39    | The shortest command table, for agents (`CLAUDE.md` symlinks to it) |
| `Makefile`                        | 28    | Only `clean` is of any use day to day                               |
| `nix/devShell.nix`                | 247   | The reference point for tool versions                               |

Line counts are `grep -c "" <file>` **as of the stamped commit above**, not
today's values. The tree has moved a long way since — `build.zig` is 459 lines
today and `src/build/Config.zig` is 989 — so read the column for magnitude and
re-run the command when you want the number.

## Setting up

### Everywhere

- The minimum Zig version is `0.16.0` (`build.zig.zon:6`). `build.zig:13-17`
  enforces it at comptime with `buildpkg.requireZig`, so the wrong version is a
  compile error rather than a mystery.
- The application version is currently `1.3.2-dev` (`build.zig.zon:3`).
- CI extracts `minimum_zig_version` out of `build.zig.zon` with `sed` to decide
  which Zig it needs (`.github/workflows/test.yml:1270`), which makes the zon
  file the single authority on the version requirement.

### Linux / FreeBSD

- Building from a Git checkout needs one extra dependency,
  `blueprint-compiler` (0.16.0 or newer, `HACKING.md:43-48`).
- On these two platforms `app_runtime` already defaults to `gtk`
  (`src/apprt/runtime.zig:16-19`), so there is no need to pass
  `-Dapp-runtime=gtk`.
- The full list of GTK runtime dependencies has not been checked item by item
  (not verified: only `blueprint-compiler` was confirmed, plus `libadwaita` and
  `gtk4` as listed at `nix/devShell.nix:145-146`). This document deliberately
  gives no distribution package-manager command; take `HACKING.md` and
  `nix/devShell.nix` as authoritative.

### macOS

- Building the macOS app requires Xcode, the macOS SDK and the Metal Toolchain
  to all be installed (`HACKING.md:50-53`).
- Development on main requires **Xcode 26 and the macOS 26 SDK** — but not that
  you are running macOS 26. Xcode 26 on macOS 15 is fine
  (`HACKING.md:63-68`).
- Having the wrong Xcode selected is a common problem; switch with
  `xcode-select` (`HACKING.md:55-61`):

```sh
sudo xcode-select --switch /Applications/Xcode.app
```

CI does the same thing but names an exact version
(`.github/workflows/test.yml:1143`):

```sh
sudo xcode-select -s /Applications/Xcode_26.6.app
```

### Nix / direnv (optional)

- The repository's `.envrc` runs `use flake` when it detects nix, and watches
  `nix/{devShell,package,wraptest}.nix` (`.envrc:1-6`).
- `nix/devShell.nix` provides and pins the tool versions: `pandoc` (`:105`),
  `zig` (`:108`), `prettier` (`:116`), `alejandra` (`:117`), `shellcheck`
  (`:120`), `hyperfine` (`:126`), `nushell` (`:140`), `blueprint-compiler`
  (`:144`). `valgrind` (`:161`) and `poop` (`:203`) are in the Linux branch
  only; `swiftlint` (`:206`) is in the Darwin branch only.
- Lint tool versions must match the devShell. `HACKING.md:140`, `:165` and
  `:200` all make the same point.

## The shortest path to a preview

Every command below is **run from the repository root**. `macos/build.nu`
locates the project through `$env.FILE_PWD` internally
(`macos/build.nu:11-12`), so calling it by relative path from the root is
enough.

### Linux / FreeBSD: zig build run

```sh
zig build run
```

Source: the step is declared at `build.zig:62` and implemented at
`build.zig:247-263`.

When `app_runtime` is not `none`, `run` simply does
`addRunArtifact(exe.exe)` (`build.zig:249`) and points
`GHOSTTY_RESOURCES_DIR` at `share/ghostty` under the install prefix
(`build.zig:256-259`). The comment at `build.zig:252-255` explains why: it is
what makes shell integration work, and it overrides any release version
installed on the system.

Where the products and resources land:

- The executable, `zig-out/bin/ghostty` (the name is defined at
  `src/build/GhosttyExe.zig:15`, installed at `:27`).
- `zig-out/share/ghostty/shell-integration`
  (`src/build/GhosttyResources.zig:117-124`).
- `zig-out/share/ghostty/themes` (`src/build/GhosttyResources.zig:129-138`,
  controlled by `-Demit-themes`).

Arguments after `--` are passed through to Ghostty unchanged
(`build.zig:250`). The CLI syntax for a configuration option is `--key=value`
(`src/cli/args.zig:112-134`; there are no positional arguments and a value
cannot be separated by a space):

```sh
zig build run -- --font-size=20
```

`font-size` is a real configuration field (`src/config/Config.zig:267`).

### macOS: zig build run works too

```sh
zig build run
```

On macOS this command takes an entirely different branch. Hop by hop:

1. `app_runtime` defaults to `.none` on macOS
   (`src/apprt/runtime.zig:20-23`), so the assertion at `build.zig:265` passes
   and the other branch is taken.
2. For speed, the xcframework is rebuilt as `.native` rather than `universal`
   (`build.zig:267-277`).
3. The `run` step depends on `macos_app_native_only.open`
   (`build.zig:290`).
4. The build step behind `open` runs
   `xcodebuild -target Ghostty -configuration <configuration>` with `macos/` as
   the working directory (`src/build/GhosttyXcodebuild.zig:62-72`). The
   configuration name mapping is Debug→`Debug` and every other optimisation
   level→`ReleaseLocal` (`:29-35`).
5. PlistBuddy writes `Add :NSQuitAlwaysKeepsWindows bool false` into the app's
   `Info.plist` (`:132-137`).
6. It then executes
   `macos/build/<configuration>/Ghostty.app/Contents/MacOS/ghostty` directly
   (path assembly at `:52`, execution at `:145-148`).
7. It forces `GHOSTTY_LOG=stderr,macos` (`:156`) and
   `GHOSTTY_MAC_LAUNCH_SOURCE=zig_run` (`:159`), and passes through anything
   after `--` (`:161-163`).

**So on macOS `zig build run` puts the logs in your current terminal by
construction** — hop 7 turns the stderr destination on — which makes it the
least-effort way to preview a change. There is no need to open a separate
`log stream`.

### macOS: the two-stage build, for Swift-only changes or a complete app

```sh
zig build -Demit-macos-app=false
```

```sh
macos/build.nu --scheme Ghostty --configuration Debug --action build
```

Sources: the first is from `AGENTS.md:7-10` and `macos/AGENTS.md:4-6`; the
three arguments to the second have their defaults defined at
`macos/build.nu:6-10` (`--scheme` takes `Ghostty` or `DockTilePlugin`,
`--configuration` takes `Debug`, `Release` or `ReleaseLocal`), and the usage is
at `macos/AGENTS.md:9`.

The product is `macos/build/<configuration>/Ghostty.app` — for example
`macos/build/Debug/Ghostty.app` (`macos/AGENTS.md:10`; `SYMROOT` is set at
`macos/build.nu:12` and `macos/build.nu:29`). Launch it with the macOS `open`
command. That command is not itself documented anywhere in this repository; the
usage text at `src/main_ghostty.zig:86-87` shows the `open -na Ghostty.app`
form:

```sh
open macos/build/Debug/Ghostty.app
```

Why not type `xcodebuild` yourself: `macos/AGENTS.md:7-8` requires `build.nu`.
The root cause is that Nix environment variables contaminate xcodebuild — the
comment at `macos/build.nu:3-4` names `NIX_LDFLAGS` and `NIX_CFLAGS_COMPILE`,
and the script uses `env -i` to keep only `HOME` and a clean `PATH`
(`macos/build.nu:22-24`). `src/build/GhosttyXcodebuild.zig:56-60` does the same
thing, and CI carries the same warning in a comment: "Nix breaks xcodebuild so
this has to be run outside" (`.github/workflows/test.yml:1158-1160`).

The intermediate product is `macos/GhosttyKit.xcframework`
(`src/build/GhosttyXCFramework.zig:40-41`).

### libghostty-vt

```sh
zig build -Demit-lib-vt
```

```sh
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

Sources: `AGENTS.md:21-22`; the option is defined at
`src/build/Config.zig:80-84` and wired up at `build.zig:119-155`. The wasm
variant is also the command a codec must pass according to
`src/terminal/compress/AGENTS.md:26-28`.

Products: the static library installs as `libghostty-vt.a` everywhere except
Windows, where it is `ghostty-vt-static.lib` (`build.zig:148-151`); the
pkg-config files are `share/pkgconfig/libghostty-vt.pc` and
`share/pkgconfig/libghostty-vt-static.pc`
(`src/build/GhosttyLibVt.zig:641,648`); the public headers are in
`include/ghostty/vt/`.

## The switches that shorten the loop

- Develop against a debug build. That is already Zig's default: run
  `zig build` and pass **no** `-Doptimize` flag at all (`HACKING.md:25-27`).
- When the change is confined to the Zig core and you do not need an app
  bundle, skip the Xcode build (`AGENTS.md:7-10`; CI does the same,
  `.github/workflows/test.yml:1155`):

```sh
zig build -Demit-macos-app=false
```

- To clean, use `make clean`. It removes four things — `zig-out`, `.zig-cache`,
  `macos/build` and `macos/GhosttyKit.xcframework` (`Makefile:23-27`) — which
  are also the four places to look first when you suspect something did not
  rebuild.

Where you changed something, and what to run:

| Changed         | Command                            | Product                                    |
| --------------- | ---------------------------------- | ------------------------------------------ |
| `src/` core     | `zig build -Demit-macos-app=false` | `zig-out/`, `macos/GhosttyKit.xcframework` |
| `macos/` Swift  | `macos/build.nu`                   | `macos/build/Debug/Ghostty.app`            |
| `src/apprt/gtk` | `zig build run` (on Linux/FreeBSD) | `zig-out/bin/ghostty`                      |
| `src/terminal`  | `zig build -Demit-lib-vt`          | `libghostty-vt.a` and friends              |
| `src/build`     | `zig build`                        | depends on which step you touched          |

Sources, in order: `AGENTS.md:7-10`, `macos/AGENTS.md:7-9`,
`src/apprt/runtime.zig:16-19`, `AGENTS.md:21`, `build.zig:20-22`. Note that
after changing anything outside `macos/`, you have to run
`zig build -Demit-macos-app=false` first to refresh the underlying library, and
only then build the app (`macos/AGENTS.md:4-6`).

## Build options, quick reference

The authorities are the real output of `zig build --help` and
`src/build/Config.zig` — the comment at `build.zig:20-22` says exactly that.
The table below lists only what comes up regularly during development.

| Option                 | Default                                      | Source (`src/build/Config.zig`) |
| ---------------------- | -------------------------------------------- | ------------------------------- |
| `-Doptimize`           | `Debug`                                      | `:75`                           |
| `-Dtarget`             | native (rewritten to a generic CPU on macOS) | `:86-95`                        |
| `-Dapp-runtime`        | `gtk` on Linux/FreeBSD, `none` elsewhere     | `:174-178`                      |
| `-Drenderer`           | by platform                                  | `:180-184`                      |
| `-Dfont-backend`       | by platform                                  | `:168-172`                      |
| `-Dxcframework-target` | `universal`                                  | `:160-164`                      |
| `-Demit-macos-app`     | `!emit_lib_vt and emit_xcframework`          | `:510-514`                      |
| `-Demit-xcframework`   | see below                                    | `:489-508`                      |
| `-Demit-lib-vt`        | `is_dep` (true when used as a dependency)    | `:80-84`                        |
| `-Demit-exe`           | `!emit_lib_vt`                               | `:405-409`                      |
| `-Demit-bench`         | `false`                                      | `:423-427`                      |
| `-Demit-docs`          | true only if `pandoc` can be found           | `:435-454`                      |

`-Dtest-filter` is not in `src/build/Config.zig`. It is defined directly at
`build.zig:43-47`, its type is `[][]const u8`, and it may be given more than
once.

### Other switches worth knowing

- **`-Demit-test-exe`** — defaults to `false`; installs the test executable
  (`src/build/Config.zig:411-415`).
- **`-Demit-terminfo` / `-Demit-termcap`** — terminfo is always true on
  Windows; everywhere else it behaves like termcap: true in Debug, false in
  release (`src/build/Config.zig:456-475`).
- **`-Demit-themes`** — defaults to `true`; installs the bundled iTerm2 colour
  themes (`src/build/Config.zig:477-481`).
- **`-Dsentry`** — true by default on macOS/iOS, false elsewhere. The comment
  explains that crash reports on Linux do not carry enough information
  (`src/build/Config.zig:201-213`).
- **`-Dsimd`** — true by default, false on wasm architectures
  (`src/build/Config.zig:215-225`).
- **`-Dgtk-wayland` / `-Dgtk-x11`** — defaults come from detection. **Note the
  `gtk-` prefix**: these are not `-Dwayland` / `-Dx11`
  (`src/build/Config.zig:227-237`).
- **`-Di18n`** — true on macOS/iOS; true on Windows; on Linux/FreeBSD it
  depends on whether you are on glibc; false elsewhere
  (`src/build/Config.zig:372-392`). The Windows arm does not link libintl:
  `src/os/i18n.zig` reads the installed `.mo` itself, so after `zig build`
  the catalogue has to be under `share/locale/<locale>/LC_MESSAGES/` or every
  string falls back to its English msgid.
- **`-Dflatpak` / `-Dsnap`** — both default to `false` and only apply to Linux
  targets (`src/build/Config.zig:189-199`).
- **`-Dpie`** — defaults to whatever `system_package` is, not to a constant
  `false` (`src/build/Config.zig:384-388`).
- **`-Dstrip`** — false under Debug/ReleaseSafe, true under
  ReleaseFast/ReleaseSmall (`src/build/Config.zig:390-398`).
- **`-Dversion-string`** — sets the semantic version explicitly; without it the
  version is derived from git (`src/build/Config.zig:252-257`).
- **`-Dpatch-interp` / `-Dpatch-rpath`** — inject the dynamic linker and the
  rpath; they have defaults under Nix (`src/build/Config.zig:349`,
  `src/build/Config.zig:368`).

`-Demit-xcframework`'s default logic is worth writing down on its own: false
for any non-Darwin host or non-macOS target; in lib-vt mode it depends on
whether `xcodebuild` is on `PATH`; otherwise it requires
`app_runtime == .none` and that you are not emitting bench, test-exe or helpgen
(`src/build/Config.zig:489-508`).

## Logging and debugging

### GHOSTTY_LOG

Ghostty defines two log destinations, `stderr` and `macos` (the latter does
nothing off macOS). Combine them with commas, turn one off with a `no-` prefix,
and mix enabling and disabling freely; `true` turns everything on and `false`
turns everything off (`HACKING.md:114-124`).

```sh
GHOSTTY_LOG=stderr,no-macos zig build run
```

Under the hood it is parsed into the packed struct `GlobalState.Logging`
(`src/global.zig:395-401`) by `cli.args.parsePackedStruct`, falling back to the
defaults if parsing fails (`src/global.zig:149-154`). Those defaults depend on
the build configuration: `stderr` defaults to
`build_config.app_runtime != .none` (`src/global.zig:398`) and `macos` to
`builtin.os.tag.isDarwin()` (`src/global.zig:401`).

**Trap**: while a `+action` CLI command runs, stderr logging is forcibly
disabled so it cannot contaminate the output (`src/global.zig:141`).

### Log level, and what startup prints

- `log_level` is `.debug` in Debug builds and `.info` in every other build mode
  (`src/main_ghostty.zig:208-211`); `HACKING.md:109-112` describes the same
  thing. The comment at `src/main_ghostty.zig:202-207` explains why
  `GHOSTTY_LOG` is not used to lower it: debug logging is expensive to compute
  and has to be optimised out of non-Debug builds.
- Startup emits a batch of info lines: version, build optimize, runtime,
  font_backend, renderer, and libxev's default backend
  (`src/global.zig:167-178`). Those lines are the fastest way to confirm which
  build you are actually running.

### How to read the logs per platform

- The macOS unified log (`HACKING.md:107`):

```sh
sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'
```

- A Linux systemd user service (`HACKING.md:103-104`):

```sh
journalctl --user --unit app-com.mitchellh.ghostty.service
```

As already noted, starting with `zig build run` on macOS already forces
`GHOSTTY_LOG=stderr,macos` (`src/build/GhosttyXcodebuild.zig:156`), so you
usually do not need a `log stream` at all.

### The inspector

The inspector does roughly what a browser's developer tools do: it lets you
inspect and modify terminal state (`src/inspector/AGENTS.md:3-5`).

- Default keybinding: `ctrl+shift+i` off Darwin
  (`src/config/Config.zig:6875-6880`, inside the non-Darwin branch that starts
  at `src/config/Config.zig:6685`); `cmd+opt+i` on Darwin
  (`src/config/Config.zig:7222-7227`, inside the Darwin branch that starts at
  `src/config/Config.zig:6987`). Both carry the comment "Inspector, matching
  Chromium".
- The keybinding action is `inspector: InspectorMode`, whose values are
  `toggle` / `show` / `hide` (`src/input/Binding.zig:691-694`, `:1196-1200`).
- Do not confuse it with `show_gtk_inspector`, which shows GTK's own inspector
  and does nothing on macOS (`src/input/Binding.zig:696-699`).
- The implementation is in `src/inspector/`, and that package has **no unit
  tests** (`src/inspector/AGENTS.md:12`). When changing the inspector on macOS,
  verify your API usage by building with `-Demit-macos-app=false`
  (`src/inspector/AGENTS.md:11`).
- There is no configuration-file switch for the inspector, only the keybinding
  (not verified: `inspector` has only three hits in `src/config/Config.zig` —
  the two keybindings above and one documentation line about the GTK
  inspector. Do not invent an `inspector = true` option).

## Testing

```sh
zig build test -Dtest-filter=<test name>
```

Source: the step is declared at `build.zig:67`. `AGENTS.md:11-14` explicitly
asks you to prefer `-Dtest-filter`, because the full suite is slow.
`-Dtest-filter` is a `[][]const u8` and may be given several times
(`build.zig:43-47`).

The test executable is called `ghostty-test` and is built with a baseline CPU
target, `.Debug`, and `use_llvm = true` (`build.zig:344-357`); the comment
notes that leaving `use_llvm` off crashes on x86_64.

**macOS trap**: without `-Dtest-filter`, `zig build test` also pulls in an
xctest dependency (`build.zig:292-295`) and goes off to run
`xcodebuild test -scheme Ghostty -skip-testing GhosttyUITests`
(`src/build/GhosttyXcodebuild.zig:103-108`). To run only the Zig unit tests,
pass an empty filter, which is exactly what CI does
(`.github/workflows/test.yml:1246-1248`):

```sh
zig build test -Dtest-filter=""
```

libghostty-vt has its own test step, which runs the two modules `mod.vt` and
`mod.vt_c` (`build.zig:68-71`, `:325-338`). Prefer it when the change lands in
a libghostty-vt file (`AGENTS.md:23-24`):

```sh
zig build test-lib-vt -Dtest-filter=<filter>
```

The Swift unit tests on the macOS side (`macos/AGENTS.md:11`). When the action
is `test` the script appends `-skip-testing GhosttyUITests` automatically,
because the UI tests need special permissions (`macos/build.nu:14-20`):

```sh
macos/build.nu --action test
```

Some slow tests are gated behind an environment variable — the exhaustive LZ4
differential test, for instance (`src/terminal/compress/AGENTS.md:86`):

```sh
GHOSTTY_LZ4_SLOW=1 zig build test -Dtest-filter="lz4 differential"
```

### A declaration nobody references may never have been compiled

`locales_map` and `staticLocale` in `src/os/i18n.zig` held **five compile
errors** between them, from three unrelated causes, while the full test suite
stayed green. **Zig analyses container-level declarations lazily**: nothing
referenced these two, so nothing ever evaluated them, and no amount of being
wrong would have said so. The fix is the test at the bottom of that file.

**Not every kind of error can hide.** Every cell below was measured in this
repository -- put a broken declaration in a file, run `zig build test`, read
the exit code -- rather than reasoned about:

| How it is referenced | Error in a `const` initialiser | Error in a `fn` body |
| --- | --- | --- |
| not referenced at all | **not reported** (lazy, never analysed) | **not reported** |
| `_ = x;` | reported | **not reported** (only the name is taken) |
| `_ = &x;` | reported | reported |
| `std.testing.refAllDecls(@This())` | reported | reported |

⚠️ **The trap that inverts this experiment**: if the "broken declaration" you
plant uses an undeclared identifier, **every cell goes red** -- name resolution
happens per file, eagerly, whether or not anything references the declaration.
To reproduce this class the defect has to be a *type* error (using a module
where an array was meant, say), which is what gets deferred with the
declaration.

**So the gate already exists in the language**: `std.testing.refAllDecls(@This())`.
In a file that calls it, container-level declarations are always analysed; in a
file that does not, only the ones something references.

Readings over `src/` as of 2026-09-08, **each with the method that produced it**:

- **607** `.zig` files.
- **A = 45**: the file itself calls `refAllDecls(@This())` or
  `refAllDeclsRecursive(@This())` -- its declarations are always evaluated.
- **B = 110**: reached only by an `_ = <namespace>;` somewhere else, with no A
  of its own -- **no guarantee**. `src/os/i18n.zig` was in this class.
- **C = 452**: everything else. ⚠️ **Coverage of these 452 was not measured;
  do not read it as "ruled out".**
- **114** container-level declarations have no second textual reference
  anywhere in `src/` (74 `fn`, 40 `const`/`var`). Method: after blanking `//`
  comments and string literals, take the name of every `const`/`var`/`fn`
  declared at indentation zero, and keep those appearing exactly once as an
  identifier across all of `src/`; `export`/`extern` declarations are excluded
  because an exported symbol is always analysed.
  ⚠️ **This number is wrong in both directions**: it over-counts declarations
  reached through `@field`, through a type, or only from `build.zig`; it
  under-counts transitively dead code -- a declaration referenced only by
  another declaration that itself is never compiled.
- **114 ∩ B = 4**, the declarations in exactly `locales_map`'s position:
  `src/lib/allocator.zig:6 convenience`, `src/os/macos.zig:9 isAtLeastVersion`,
  `src/os/macos.zig:50 SetQosClassError`, and
  `src/renderer/shadertoy.zig:429 test_focus`. All four were compiled by hand
  once each, and **all four are fine**.

**Whether adding `refAllDecls` to the B files would shake out other failures is
not known** -- no reading taken today says it is safe -- so it was not done, and
no new checker was written for it.

## Memory checking

```sh
zig build run-valgrind
```

Source: the step is declared at `build.zig:63-66` and described at
`HACKING.md:238-255`.

It first rebuilds the executable with a baseline CPU target
(`build.zig:301-310`), then runs it with a fixed argument set:
`valgrind --leak-check=full --num-callers=50 --suppressions=<repo>/valgrind.supp --gen-suppressions=all`
(`build.zig:312-317`). The suppression file `valgrind.supp` is in the
repository root and is 2441 lines. As with `run`, anything after `--` is
appended as configuration arguments (`build.zig:320`, `HACKING.md:257-258`).

**Limitation**: the whole Valgrind branch is wrapped in
`if (config.app_runtime != .none)` (`build.zig:300`), so under the default
macOS configuration `run-valgrind` attaches no dependencies at all and does
nothing. It is only meaningful on Linux — and `nix/devShell.nix:161` likewise
only offers `valgrind` in the Linux branch.

There is a test variant with the same argument set (`build.zig:72-75`,
`:375-385`):

```sh
zig build test-valgrind
```

## Benchmarks

The benchmark tooling splits into two roles: `ghostty-gen` generates synthetic
input data, and `ghostty-bench` consumes existing data and runs the benchmark
(`src/benchmark/AGENTS.md:3-6`). Both binaries (`ghostty-gen` is defined at
`src/build/GhosttyBench.zig:17-31`, `ghostty-bench` at `:33-46`) are hardcoded
to build with `.optimize = .ReleaseFast` and install into `zig-out/bin`
(`:52-54`).

```sh
zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false
```

Sources: `src/benchmark/AGENTS.md:34-35`, `build.zig:104-107`. `AGENTS.md`
insists on `-Doptimize=ReleaseFast`: a debug build is extremely slow and does
not represent real performance (`src/benchmark/AGENTS.md:36-38`).

The discipline, all of it from `src/benchmark/AGENTS.md:10-30`:

1. Generate the data first, benchmark second. **Do not** pipe `ghostty-gen`
   straight into `ghostty-bench` — that folds generation cost into the
   measurement.
2. When comparing across versions, reuse the exact same generated file, and
   prefer a fixed seed.
3. Compare with `hyperfine`, benchmarking the `ghostty-bench` command line
   rather than the generator.
4. Warm up several times and take the median of repeated measurements; when
   comparing branches keep the input and the CLI arguments — terminal size
   included — identical.
5. **Never** run two benchmarks in parallel on the same machine.
6. Keep large corpora outside the repository.

The way to compare branches is to build each branch separately, rename
`zig-out/bin/ghostty-bench` to `ghostty-bench-branch1` / `ghostty-bench-branch2`,
and then compare those binaries with `hyperfine`
(`src/benchmark/AGENTS.md:40-48`).

There are 14 benchmark names (`src/benchmark/cli.zig:9-23`): `apc-parser`,
`codepoint-width`, `grapheme-break`, `hyperlink-map`, `page-compression`,
`scrollback-compression`, `screen-clone`, `terminal-formatter`,
`terminal-parser`, `terminal-resize`, `terminal-snapshot`, `terminal-stream`,
`is-symbol`, `osc-parser`. The synthetic data generator offers 5 types
(`src/synthetic/cli.zig:8-13`): `ascii`, `kitty`, `osc`, `styled`, `utf8`.

The example below is quoted verbatim from a source comment
(`src/benchmark/PageCompression.zig:51-59`):

```sh
ghostty-bench +page-compression --mode=report --data=/tmp/pages.raw
```

`+page-compression` has the modes `compress`, `decompress`, `store` and
`report` (`src/terminal/compress/AGENTS.md:50-51`). `+scrollback-compression`
measures `PageList`'s state transitions around the codec rather than the codec
itself (`src/terminal/compress/AGENTS.md:58-59`).

## Before you commit

Run these from the repository root, taking whichever apply to what you changed:

```sh
zig fmt .
```

```sh
prettier -w .
```

```sh
swiftlint lint --strict --fix
```

```sh
alejandra .
```

Sources: the first three are from `AGENTS.md:15-17`. The SwiftLint command in
`HACKING.md:197` is `swiftlint lint --fix` without `--strict`, and
`HACKING.md:210-212` gives the `--strict` check-only form. `alejandra .` is
only needed when you changed a `.nix` file (`HACKING.md:159-163`). The
corresponding CI checks are `zig fmt --check .`
(`.github/workflows/test.yml:1653`), `prettier --check .` (`:1714`),
`swiftlint lint --strict` (`:1744`) and `alejandra --check .` (`:1772`).

Shell scripts go through ShellCheck. The command is quoted verbatim from
`HACKING.md:183-186` (CI's version adds `--color=always`,
`.github/workflows/test.yml:1829-1833`):

```sh
shellcheck --check-sourced --severity=warning $(find . \( -name "*.sh" -o -name "*.bash" \) -type f ! -path "./zig-out/*" ! -path "./macos/build/*" ! -path "./.git/*" | sort)
```

The rest:

- Nix users prefix everything with `nix develop -c <tool> ...`
  (`HACKING.md:142-146`, `:153-157`, `:171-178`, `:202-212`). Tool versions
  must match `nix/devShell.nix` (`HACKING.md:140`, `:165`, `:200`).
- After changing `build.zig.zon`, run
  `./nix/build-support/check-zig-cache.sh --update`. It writes
  `nix/zigCacheHash.nix`, which has to be committed alongside
  (`HACKING.md:225-232`).
- After changing i18n strings, run `zig build update-translations`
  (`build.zig:76-79`, `:388-394`). Note that with `-Di18n=false` this step
  errors outright with "cannot update translations when i18n is disabled"
  (`build.zig:392-394`). The details are in
  [`po/README_CONTRIBUTORS.md`](../../po/README_CONTRIBUTORS.md).
- The release-related `zig build dist` and `zig build distcheck`
  (`build.zig:112`, `:114`); their output paths are not verified (this
  document has never built them).
- The contribution process is in
  [`CONTRIBUTING.md`](../../CONTRIBUTING.md) and is not repeated here.

## Traps and troubleshooting

- **Debug builds are extremely slow** — three warning lines are printed at
  startup (`src/main_ghostty.zig:61-65`). Never measure performance on a debug
  build; performance work is always `-Doptimize=ReleaseFast`
  (`src/benchmark/AGENTS.md:36-38`).
- **`zig-out/bin/ghostty` is not the terminal on macOS** — `app_runtime`
  defaults to `.none` (`src/apprt/runtime.zig:20-23`), so running it directly
  prints `Usage: ghostty +<action> [flags]` and a block of explanation, then
  `exit(0)` (`src/main_ghostty.zig:77-96`). The real terminal is in
  `Ghostty.app`, and the command line form given in that explanation is
  `open -na Ghostty.app --args --foo=bar --baz=qux`
  (`src/main_ghostty.zig:86-87`).
- **You changed `src/` and the macOS app behaves the same** — you forgot to run
  `zig build -Demit-macos-app=false` first to refresh
  `macos/GhosttyKit.xcframework` (`macos/AGENTS.md:4-6`,
  `src/build/GhosttyXCFramework.zig:40-41`).
- **Hand-typed `xcodebuild` fails oddly** — Nix environment variables. Use
  `macos/build.nu` (`env -i`, `macos/build.nu:22-24`), or follow
  `src/build/GhosttyXcodebuild.zig:56-60` and keep only `PATH`. The CI comment
  warns about the same thing (`.github/workflows/test.yml:1158-1160`).
- **The wrong Xcode is selected** — switch with
  `sudo xcode-select --switch /Applications/Xcode.app` (`HACKING.md:55-61`);
  main needs Xcode 26 and the macOS 26 SDK (`HACKING.md:65`).
- **`zig build test` inexplicably runs Xcode on macOS** — without
  `-Dtest-filter` it attaches an xctest dependency (`build.zig:292-295`). Pass
  `-Dtest-filter=""` to avoid it.
- **`-Demit-docs` quietly turned itself off** — by default it is true only if
  `pandoc` is on `PATH`, and it is false outright whenever you are already
  emitting bench, test-exe, helpgen or lib-vt
  (`src/build/Config.zig:435-454`). The docs are generated by `pandoc`
  (`src/build/GhosttyDocs.zig:60` and `src/build/GhosttyDocs.zig:75`); when
  docs are not emitted and the target is Darwin, a placeholder directory is
  installed anyway, because the Xcode project expects `share/man` to exist
  (`build.zig:90-97`, `src/build/GhosttyDocs.zig:111-116`).
- **The name "libghostty" is ambiguous** — `-Demit-lib-vt` produces the
  terminal library libghostty-vt (`src/lib_vt.zig`, headers in
  `include/ghostty/vt/`). The identically named thing on the macOS side is a
  historical accident and is only glue between the GUI and the core; the
  comment at `build.zig:189-191` says "This is NOT libghostty (even though its
  named that for historical reasons)", and its header is `include/ghostty.h`.
- **`zig build run` on macOS is not "launching it the way a user would"** — it
  sets `GHOSTTY_MAC_LAUNCH_SOURCE=zig_run`
  (`src/build/GhosttyXcodebuild.zig:159`), while `launchedFromDesktop()` only
  returns true when that value is `"app"` (`src/os/desktop.zig:28-35`), which
  in turn affects heuristics such as `probableCliEnvironment()`
  (`src/config/Config.zig:5196-5207`). To reproduce the behaviour of launching
  from Finder, use `open` on the app bundle.
- **`zig build run-valgrind` is a no-op on macOS** — the whole branch is
  wrapped in `app_runtime != .none` (`build.zig:300`).
- **CI fails after you changed `build.zig.zon`** — the Zig cache hash has
  drifted; run `./nix/build-support/check-zig-cache.sh --update`
  (`HACKING.md:221-232`).
- **The `/gh-issue` command mentioned at `HACKING.md:83` does not exist** —
  `.agents/` currently holds exactly two things,
  `.agents/commands/review-branch` and
  `.agents/skills/writing-commit-messages/SKILL.md`. That paragraph is out of
  date.
- **The hard rule against filing issues has been retired.** At the stamped
  commit it was real and sat at `AGENTS.md:34-39`, the
  `## Issue and PR Guidelines` section: never create an issue, never create a
  PR. That section was deleted in `438a2e352` ("The rule against filing issues was written to
  protect a repository this is no longer"), at the owner's instruction. The
  commit message gives the reason: the rule came from upstream (`00c33eaf7`),
  and it had stopped matching in both directions — upstream has since closed
  issue creation entirely, so the thing it guarded is guarded from the other
  side, while its unconditional wording also covered this repository's own
  tracker, "where the owner wanting a record filed is an ordinary request
  about their own project, and the rule answered it with a joke and a
  refusal". The unconditional ban has not come back. What the rules are today
  — where to file, and whether you may — is `AGENTS.md`'s own to state and is
  deliberately not repeated here: a rule restated in a second file gets
  changed in only one of them. This much is written out rather than dropped
  because a reader who met the old rule somewhere else needs to know it was
  retired deliberately, not lost.

## Developing on macOS without a full Xcode

With only the Command Line Tools installed and no Xcode.app, **both**
`zig build` and `zig build test` fail with:

```text
xcrun: error: unable to find utility "metal", not a developer tool or in PATH
```

The cause is that the metallib step is attached unconditionally for any Darwin
target (`src/build/SharedDeps.zig:499-505`, constructed at `:131-136`), and
`-Drenderer=opengl` does not get you around it — it is attached by target OS,
not by renderer backend.

The real fix is to install a full Xcode 26 plus the Metal Toolchain. When you
cannot, there are still two verification paths for pure-Zig changes.

### 1. Run a standalone module's unit tests (no container needed)

Any file that does not depend on the build system injecting a module (such as
`terminal_options`) can be run directly:

```sh
zig test src/poltergeist/Watcher.zig
```

Note that `zig test`'s module root is **the directory the file is in**, so the
file must not `@import("../…")` — that gives you
`import of file outside module path`. Files that import across directories can
only go through option 2 below.

### 2. Run the full test suite in a Linux container

If you have Docker, this is the **only way to genuinely run the complete test
suite**, and it needs no Xcode at all:

```sh
# Download the Linux zig, matching minimum_zig_version in build.zig.zon
curl -L https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz | tar xJ

docker run --rm \
  -v "$PWD:/repo" -v "$PWD/zig-aarch64-linux-0.16.0:/zig:ro" \
  -v /tmp/zigcache:/cache -v /tmp/zigglobal:/gcache \
  -w /repo debian:bookworm-slim \
  sh -c 'apt-get -qq update >/dev/null && \
         apt-get -qq install -y fontconfig fonts-dejavu-core >/dev/null && \
         /zig/zig build test -Dapp-runtime=none \
           --cache-dir /cache --global-cache-dir /gcache'
```

- `fontconfig` and at least one font are required, or the three tests in
  `src/font/discovery.zig` fail (the image ships no font configuration).
- Mount persistent cache directories, or every run recompiles every dependency
  from scratch (about ten minutes the first time).
- You may see a trailing line reading `failed command: ... ghostty-test` while
  `exit=0`. This is Zig 0.16 behaviour: any test that writes to stderr triggers
  that line. The comment at `src/main.zig:30-35` says so verbatim. To decide
  whether anything really failed, look for a line matching
  `^error: '...' failed`.

To build GTK as well, swap the image for `debian:trixie-slim`
(`blueprint-compiler` needs to be ≥ 0.16.0) and add
`libgtk-4-dev libadwaita-1-dev pkg-config gettext`. (Not verified: on that
path translate-c could not find the GTK headers, and it was not pursued
further.)

### 3. Type-check the Swift code

**No full Xcode required.** `swiftc` ships with the Command Line Tools, and the
SDK carries AppKit and SwiftUI:

```sh
swiftc -typecheck -sdk "$(xcrun --show-sdk-path)" path/to/File.swift
```

One caveat: doing this directly to a file under `macos/Sources/` fails on
`import GhosttyKit`, which is the xcframework `zig build` produces. The way
round it is to copy the file, replace `import GhosttyKit` with stub
declarations for the handful of symbols it uses, and check that. This catches
SwiftUI type errors; it does not catch anything about the real C ABI boundary.

Building the `.app` still needs a full Xcode, and there is no way around it.

### 4. Cross-compile for a full type check

Compiling for a non-Darwin target does not attach metallib:

```sh
zig build test -Dtarget=x86_64-linux-gnu -Dapp-runtime=none -Demit-test-exe
```

- `-Dapp-runtime=none` is required: Linux defaults to `gtk`
  (`src/apprt/runtime.zig:16-19`), which sends it looking for `gtk/gtk.h` and
  `adwaita.h`, neither of which is on this machine.
- It will certainly end with
  `the host system ... is unable to execute binaries from the target`. That is
  the **run** step failing, not the compile. Only lines beginning with `^src/`
  tell you whether there was a real error.

This covers the type checking of all the Zig code, but it **does not cover the
macOS-only conditional compilation branches**. Compile errors that only show
up under a macOS target have been hit in practice, so running the Linux target
alone is not enough.

> If you genuinely need to verify compilation for a macOS target, you can
> temporarily replace the two `xcrun` calls in `src/build/MetallibStep.zig`
> with `/usr/bin/touch` (producing an empty fake metallib), run
> `zig build test -Dtarget=aarch64-macos -Demit-test-exe` as a type check, and
> then **restore that file immediately**. The fake metallib is only good enough
> to fool the compiler; linking and running both fail, and it must never be
> committed.

## Nix VMs and integration tests

This section points the way and no further.

- Desktop-environment VMs: `nix run .#<vmtype>`, where `<vmtype>` is a filename
  under `nix/vm` with the `.nix` suffix removed, excluding anything prefixed
  `common` or `create`. The source directory is mounted into the VM at
  `/tmp/shared` (`HACKING.md:350-360`).
- Integration tests: `nix run .#checks.<system>.<test-name>.driver`, where
  `<system>` is `x86_64-linux` or `aarch64-linux` and `<test-name>` comes from
  `nix/tests.nix`. `nix flake check` runs all of them
  (`HACKING.md:441-451`).
- Running these on macOS requires a Linux builder enabled in nix-darwin;
  interactive and SSH debugging details are at `HACKING.md:453` and the
  sections that follow it.

## Further reading

- In this repository: [`HACKING.md`](../../HACKING.md),
  [`AGENTS.md`](../../AGENTS.md),
  [`macos/AGENTS.md`](../../macos/AGENTS.md),
  [`src/benchmark/AGENTS.md`](../../src/benchmark/AGENTS.md),
  [`src/inspector/AGENTS.md`](../../src/inspector/AGENTS.md),
  [`src/terminal/compress/AGENTS.md`](../../src/terminal/compress/AGENTS.md),
  [`po/README_CONTRIBUTORS.md`](../../po/README_CONTRIBUTORS.md)
- In English, beside this file: [`architecture.md`](architecture.md),
  [`GLOSSARY.md`](GLOSSARY.md), [`README.md`](README.md)
- Chinese only, one directory up: [`README.md`](../README.md),
  [`terminal-core.md`](../terminal-core.md),
  [`rendering-and-font.md`](../rendering-and-font.md),
  [`platform-and-config.md`](../platform-and-config.md),
  [`_conventions.md`](../_conventions.md)
