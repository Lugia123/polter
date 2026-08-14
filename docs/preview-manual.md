# 开发预览手册

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`

## 本文覆盖什么

- 构建 Ghostty 所需的环境依赖与最低版本要求。
- 从「改一行代码」到「看到效果」的最短命令路径：Linux/FreeBSD、macOS、libghostty-vt 三条线。
- `zig build` 的构建选项速查，以及缩短迭代周期的关键开关。
- 日志（`GHOSTTY_LOG`）、inspector、单元测试、Valgrind、benchmark 等观察与验证手段。
- 提交前的格式化与 lint 清单，以及构建/运行环节最容易踩的坑。

本仓库的构建与运行命令以本篇为唯一权威，根 `AGENTS.md:96` 也是这么写的。

## 本文不覆盖什么

- 线程模型、模块职责、启动调用链 —— 见 [architecture.md](architecture.md)。
- VT 解析、`Screen`/`PageList`/`Page`、kitty 与 OSC 协议 —— 见 [terminal-core.md](terminal-core.md)。
- 渲染后端、着色器、字体与字形（glyph）栈 —— 见 [rendering-and-font.md](rendering-and-font.md)。
- 应用运行时（apprt）、`macos/` Swift 侧、配置系统、键绑定内部结构 —— 见 [platform-and-config.md](platform-and-config.md)。
- 贡献流程与 AI 使用政策 —— 见 [CONTRIBUTING.md](../CONTRIBUTING.md)、[AI_POLICY.md](../AI_POLICY.md)，本文不复述。
- 面向最终用户的配置项手册（在上游站点，不在本仓库）。

## 关于本文命令的可信度声明

本文列出的每条命令都标注了仓库内出处（`build.zig`、`src/build/*.zig`、`AGENTS.md`、`macos/AGENTS.md`、`HACKING.md`、各子目录 `AGENTS.md`、`.github/workflows/test.yml`）。

撰写本文的机器 PATH 中没有 `zig`、`nu`、`swiftlint`、`prettier`、`pandoc`（只有 `/usr/bin/xcodebuild`），仓库里也不存在 `zig-out/`。因此：

- **本文所有命令均未在撰写环境实际执行（未核实）**，全文不给出任何命令输出、耗时数字或泄漏计数。
- 所有产物路径都来自对构建脚本的静态阅读，而不是对实际构建结果的观察（未核实）。
- 想确认某个选项当前是否存在、默认值是什么，以 `zig build --help` 的实际输出和 `src/build/Config.zig` 为准 —— 这也是 `build.zig:20-22` 注释本身的建议。

## 一句话概括

Ghostty 的核心是 Zig，`zig build` 是唯一构建入口（`build.zig:19`）；Linux/FreeBSD 上 `app_runtime` 默认是 `gtk`，一条 `zig build run` 就能跑起来；macOS 上 `app_runtime` 默认是 `none`（`src/apprt/runtime.zig:14-24`），GUI 由 Xcode 单独构建，所以是「先 Zig、后 Xcode」的两段式。

## 关键文件地图

| 路径                              | 行数 | 职责                                               |
| --------------------------------- | ---- | -------------------------------------------------- |
| `build.zig`                       | 420  | 构建入口，声明全部 build step                      |
| `src/build/Config.zig`            | 803  | 全部 `-D` 选项的定义与默认值                       |
| `src/build/GhosttyXcodebuild.zig` | 203  | macOS app 的 xcodebuild / open / xctest step       |
| `macos/build.nu`                  | 32   | 推荐的 macOS app 构建脚本                          |
| `HACKING.md`                      | 487  | 依赖、日志、lint、Valgrind、Nix VM                 |
| `AGENTS.md`                       | 121  | agent 用的最短命令表（`CLAUDE.md` 是它的符号链接） |
| `Makefile`                        | 28   | 只有 `clean` 对日常开发有用                        |
| `nix/devShell.nix`                | 247  | 工具版本的对齐基准                                 |

行数由 `grep -c "" <file>` 实际统计得到。

## 环境准备

### 通用

- Zig 最低版本 `0.16.0`（`build.zig.zon:6`），`build.zig:13-17` 在 comptime 用 `buildpkg.requireZig` 强制校验，版本不对会直接编译失败。
- 应用版本当前为 `1.3.2-dev`（`build.zig.zon:3`）。
- CI 用 `sed` 从 `build.zig.zon` 里提取 `minimum_zig_version` 作为所需 Zig 版本（`.github/workflows/test.yml:1270`），所以 zon 是版本要求的唯一权威。

### Linux / FreeBSD

- 从 Git checkout 构建需要额外依赖 `blueprint-compiler`（0.16.0 或更新，`HACKING.md:43-48`）。
- 这两个平台上 `app_runtime` 默认就是 `gtk`（`src/apprt/runtime.zig:16-19`），不需要显式加 `-Dapp-runtime=gtk`。
- GTK 侧的完整运行时依赖清单未逐条核实（未核实：只核实了 `blueprint-compiler`，以及 `nix/devShell.nix:145-146` 列了 `libadwaita` 与 `gtk4`）。本文不给发行版包管理器的安装命令，请以 `HACKING.md` 与 `nix/devShell.nix` 为准。

### macOS

- 构建 macOS app 需要 Xcode、macOS SDK 和 Metal Toolchain 都已安装（`HACKING.md:50-53`）。
- main 分支开发要求 **Xcode 26 和 macOS 26 SDK**；但不要求你跑在 macOS 26 上，Xcode 26 装在 macOS 15 也行（`HACKING.md:63-68`）。
- 选错 Xcode 版本是常见问题，用 `xcode-select` 切换（`HACKING.md:55-61`）：

```sh
sudo xcode-select --switch /Applications/Xcode.app
```

CI 里的对应做法是指向具体版本（`.github/workflows/test.yml:1143`）：

```sh
sudo xcode-select -s /Applications/Xcode_26.6.app
```

### Nix / direnv（可选）

- 仓库根 `.envrc` 在检测到 nix 时执行 `use flake`，并 watch `nix/{devShell,package,wraptest}.nix`（`.envrc:1-6`）。
- `nix/devShell.nix` 提供并锁定工具版本：`pandoc`（`:105`）、`zig`（`:108`）、`prettier`（`:116`）、`alejandra`（`:117`）、`shellcheck`（`:120`）、`hyperfine`（`:126`）、`nushell`（`:140`）、`blueprint-compiler`（`:144`）。`valgrind`（`:161`）与 `poop`（`:203`）只在 Linux 分支，`swiftlint`（`:206`）只在 Darwin 分支。
- lint 工具版本必须与 devShell 对齐，`HACKING.md:140`、`:165`、`:200` 三处都强调了这一点。

## 最短预览路径

以下命令一律**在仓库根目录执行**。`macos/build.nu` 内部用 `$env.FILE_PWD` 定位工程（`macos/build.nu:11-12`），从仓库根用相对路径调用即可。

### Linux / FreeBSD：zig build run

```sh
zig build run
```

出处：step 声明在 `build.zig:62`，实现在 `build.zig:247-263`。

`app_runtime` 不是 `none` 时，`run` 直接 `addRunArtifact(exe.exe)`（`build.zig:249`），并把 `GHOSTTY_RESOURCES_DIR` 指向安装前缀下的 `share/ghostty`（`build.zig:256-259`）。`build.zig:252-255` 的注释说明这么做是为了让 shell integration 正常工作，同时覆盖系统上已安装的 release 版。

产物与资源位置：

- 可执行文件 `zig-out/bin/ghostty`（名字定义在 `src/build/GhosttyExe.zig:15`，安装见 `:27`）。
- `zig-out/share/ghostty/shell-integration`（`src/build/GhosttyResources.zig:117-124`）。
- `zig-out/share/ghostty/themes`（`src/build/GhosttyResources.zig:129-138`，受 `-Demit-themes` 控制）。

`--` 之后的参数会原样透传给 Ghostty（`build.zig:250`），配置项的 CLI 语法是 `--key=value`（`src/cli/args.zig:112-134`，不支持位置参数、也不支持用空格分隔值）：

```sh
zig build run -- --font-size=20
```

`font-size` 是真实存在的配置字段（`src/config/Config.zig:267`）。

### macOS：zig build run 同样可用

```sh
zig build run
```

macOS 上这条命令走的是完全不同的分支，逐跳如下：

1. `app_runtime` 在 macOS 默认为 `.none`（`src/apprt/runtime.zig:20-23`），于是 `build.zig:265` 断言后进入另一分支。
2. 为求最快，用 `.native`（而非 `universal`）重建 xcframework（`build.zig:267-277`）。
3. `run` step 依赖 `macos_app_native_only.open`（`build.zig:290`）。
4. `open` 依赖的 build step 执行 `xcodebuild -target Ghostty -configuration <配置>`，cwd 为 `macos/`（`src/build/GhosttyXcodebuild.zig:62-72`）；配置名映射是 Debug→`Debug`、其余优化级别→`ReleaseLocal`（`:29-35`）。
5. 用 PlistBuddy 往 app 的 `Info.plist` 写 `Add :NSQuitAlwaysKeepsWindows bool false`（`:132-137`）。
6. 直接执行 `macos/build/<配置>/Ghostty.app/Contents/MacOS/ghostty`（路径拼装见 `:52`，执行见 `:145-148`）。
7. 强制设置 `GHOSTTY_LOG=stderr,macos`（`:156`）与 `GHOSTTY_MAC_LAUNCH_SOURCE=zig_run`（`:159`），并透传 `--` 之后的参数（`:161-163`）。

**结论：macOS 上 `zig build run` 天然把日志打到当前终端**（第 7 跳强制开了 stderr 目标），是最省事的预览方式，不必另开 `log stream`。

### macOS：只改 Swift 或需要完整 app 的两段式

```sh
zig build -Demit-macos-app=false
```

```sh
macos/build.nu --scheme Ghostty --configuration Debug --action build
```

出处：第一条见 `AGENTS.md:7-10` 与 `macos/AGENTS.md:4-6`；第二条的三个参数默认值定义在 `macos/build.nu:6-10`（`--scheme` 可选 `Ghostty`/`DockTilePlugin`，`--configuration` 可选 `Debug`/`Release`/`ReleaseLocal`），用法见 `macos/AGENTS.md:9`。

产物在 `macos/build/<configuration>/Ghostty.app`，例如 `macos/build/Debug/Ghostty.app`（`macos/AGENTS.md:10`；`SYMROOT` 设定见 `macos/build.nu:12` 与 `macos/build.nu:29`）。启动它可以用 macOS 系统命令 `open`（该命令本身不在仓库任何文档里，`src/main_ghostty.zig:86-87` 的用法说明里出现的是 `open -na Ghostty.app` 形式）：

```sh
open macos/build/Debug/Ghostty.app
```

为什么不要自己敲 `xcodebuild`：`macos/AGENTS.md:7-8` 明确要求用 `build.nu`。根因是 Nix 环境变量会污染 xcodebuild —— `macos/build.nu:3-4` 的注释点名了 `NIX_LDFLAGS`、`NIX_CFLAGS_COMPILE`，脚本用 `env -i` 只保留 `HOME` 和一个干净 `PATH`（`macos/build.nu:22-24`）；`src/build/GhosttyXcodebuild.zig:56-60` 做的是同一件事；CI 注释也写着「Nix breaks xcodebuild so this has to be run outside」（`.github/workflows/test.yml:1158-1160`）。

中间产物是 `macos/GhosttyKit.xcframework`（`src/build/GhosttyXCFramework.zig:40-41`）。

### libghostty-vt

```sh
zig build -Demit-lib-vt
```

```sh
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

出处：`AGENTS.md:21-22`；选项定义在 `src/build/Config.zig:80-84`，装配逻辑在 `build.zig:119-155`。wasm 变体同时是 `src/terminal/compress/AGENTS.md:26-28` 要求 codec 必须通过的验证命令。

产物：静态库在非 Windows 平台安装为 `libghostty-vt.a`（Windows 为 `ghostty-vt-static.lib`，`build.zig:148-151`）；pkg-config 文件为 `share/pkgconfig/libghostty-vt.pc` 与 `share/pkgconfig/libghostty-vt-static.pc`（`src/build/GhosttyLibVt.zig:641,648`）；公开头文件在 `include/ghostty/vt/`。

## 加速迭代的关键开关

- 开发用 debug 构建，这已是 Zig 默认，直接 `zig build` 且**不要**加任何 `-Doptimize` 标志（`HACKING.md:25-27`）。
- 只改 Zig 核心、不需要 app bundle 时，跳过 Xcode 构建（`AGENTS.md:7-10`；CI 也这么干，`.github/workflows/test.yml:1155`）：

```sh
zig build -Demit-macos-app=false
```

- 需要清理时用 `make clean`，它删除 `zig-out`、`.zig-cache`、`macos/build`、`macos/GhosttyKit.xcframework` 四处（`Makefile:23-27`）—— 这四个位置也正是「怀疑没重建」时该先看的地方。

改动位置与对应命令：

| 改动位置        | 命令                                   | 产物                                       |
| --------------- | -------------------------------------- | ------------------------------------------ |
| `src/` 核心     | `zig build -Demit-macos-app=false`     | `zig-out/`、`macos/GhosttyKit.xcframework` |
| `macos/` Swift  | `macos/build.nu`                       | `macos/build/Debug/Ghostty.app`            |
| `src/apprt/gtk` | `zig build run`（在 Linux/FreeBSD 上） | `zig-out/bin/ghostty`                      |
| `src/terminal`  | `zig build -Demit-lib-vt`              | `libghostty-vt.a` 等                       |
| `src/build`     | `zig build`                            | 视所改 step 而定                           |

出处依次为 `AGENTS.md:7-10`、`macos/AGENTS.md:7-9`、`src/apprt/runtime.zig:16-19`、`AGENTS.md:21`、`build.zig:20-22`。注意：改了 `macos/` 之外的代码后，必须先跑 `zig build -Demit-macos-app=false` 刷新底层库，再构建 app（`macos/AGENTS.md:4-6`）。

## 构建选项速查

权威是 `zig build --help` 的实际输出与 `src/build/Config.zig`（`build.zig:20-22` 注释原话）。下表只列开发中最常碰到的。

| 选项                   | 默认值                               | 出处（`src/build/Config.zig`） |
| ---------------------- | ------------------------------------ | ------------------------------ |
| `-Doptimize`           | `Debug`                              | `:75`                          |
| `-Dtarget`             | native（macOS 上改写为 generic CPU） | `:86-95`                       |
| `-Dapp-runtime`        | Linux/FreeBSD 为 `gtk`，其余 `none`  | `:174-178`                     |
| `-Drenderer`           | 按平台                               | `:180-184`                     |
| `-Dfont-backend`       | 按平台                               | `:168-172`                     |
| `-Dxcframework-target` | `universal`                          | `:160-164`                     |
| `-Demit-macos-app`     | `!emit_lib_vt and emit_xcframework`  | `:510-514`                     |
| `-Demit-xcframework`   | 见下文                               | `:489-508`                     |
| `-Demit-lib-vt`        | `is_dep`（被当依赖引用时为真）       | `:80-84`                       |
| `-Demit-exe`           | `!emit_lib_vt`                       | `:405-409`                     |
| `-Demit-bench`         | `false`                              | `:423-427`                     |
| `-Demit-docs`          | 找得到 `pandoc` 才为真               | `:435-454`                     |

`-Dtest-filter` 不在 `src/build/Config.zig` 里，它直接定义在 `build.zig:43-47`，类型是 `[][]const u8`，可以重复给多个。

### 其余常见开关

- **`-Demit-test-exe`** — 默认 `false`，安装测试可执行文件（`src/build/Config.zig:411-415`）。
- **`-Demit-terminfo` / `-Demit-termcap`** — terminfo 在 Windows 恒为真，其余平台与 termcap 一样，Debug 下真、release 下假（`src/build/Config.zig:456-475`）。
- **`-Demit-themes`** — 默认 `true`，安装内置的 iTerm2 配色主题（`src/build/Config.zig:477-481`）。
- **`-Dsentry`** — macOS/iOS 默认真，其他平台默认假；注释说明 Linux 上崩溃报告信息量不足（`src/build/Config.zig:201-213`）。
- **`-Dsimd`** — 默认真，wasm 架构下为假（`src/build/Config.zig:215-225`）。
- **`-Dgtk-wayland` / `-Dgtk-x11`** — 默认取自探测结果。**注意选项名带 `gtk-` 前缀**，不是 `-Dwayland`/`-Dx11`（`src/build/Config.zig:227-237`）。
- **`-Di18n`** — macOS/iOS 真；Linux/FreeBSD 取决于是否 glibc；其余为假（`src/build/Config.zig:239-247`）。
- **`-Dflatpak` / `-Dsnap`** — 默认均为 `false`，只对 Linux 目标有效（`src/build/Config.zig:189-199`）。
- **`-Dpie`** — 默认等于 `system_package`，不是恒 `false`（`src/build/Config.zig:384-388`）。
- **`-Dstrip`** — Debug/ReleaseSafe 下假，ReleaseFast/ReleaseSmall 下真（`src/build/Config.zig:390-398`）。
- **`-Dversion-string`** — 显式指定语义化版本，不给则用 git 推导（`src/build/Config.zig:252-257`）。
- **`-Dpatch-interp` / `-Dpatch-rpath`** — 注入动态链接器与 rpath，Nix 环境下有默认值（`src/build/Config.zig:349`、`src/build/Config.zig:368`）。

`-Demit-xcframework` 的默认逻辑值得单独记：非 Darwin 或非 macOS 目标一律为假；lib-vt 模式下取决于 PATH 里有没有 `xcodebuild`；否则要求 `app_runtime == .none` 且没有在 emit bench / test-exe / helpgen（`src/build/Config.zig:489-508`）。

## 日志与调试

### GHOSTTY_LOG

Ghostty 定义两个日志目标：`stderr` 与 `macos`（后者在非 macOS 上无效）。用逗号组合多个目标，用 `no-` 前缀关闭，可以同时启用和关闭；设为 `true` 全开、`false` 全关（`HACKING.md:114-124`）。

```sh
GHOSTTY_LOG=stderr,no-macos zig build run
```

实现上它被解析成 packed struct `GlobalState.Logging`（`src/global.zig:395-401`），由 `cli.args.parsePackedStruct` 解析，解析失败回退到默认值（`src/global.zig:149-154`）。默认值本身就依赖构建配置：`stderr` 默认为 `build_config.app_runtime != .none`（`src/global.zig:398`），`macos` 默认为 `builtin.os.tag.isDarwin()`（`src/global.zig:401`）。

**坑**：执行 `+action` 形式的 CLI 命令时，stderr 日志会被强制关掉，以免污染输出（`src/global.zig:141`）。

### 日志级别与启动信息

- Debug 构建的 `log_level` 是 `.debug`，其他构建模式是 `.info`（`src/main_ghostty.zig:208-211`）；`HACKING.md:109-112` 描述的是同一件事。`src/main_ghostty.zig:202-207` 的注释解释了为什么不靠 `GHOSTTY_LOG` 来降级：debug 日志计算代价高，需要保证在非 Debug 构建里被优化掉。
- 启动时会打出一批 info 日志：version、build optimize、runtime、font_backend、renderer、libxev default backend（`src/global.zig:167-178`）。想确认自己跑的到底是哪个构建，看这几行最快。

### 平台查看方式

- macOS 统一日志（`HACKING.md:107`）：

```sh
sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'
```

- Linux systemd user service（`HACKING.md:103-104`）：

```sh
journalctl --user --unit app-com.mitchellh.ghostty.service
```

如前所述，macOS 上用 `zig build run` 启动时已强制 `GHOSTTY_LOG=stderr,macos`（`src/build/GhosttyXcodebuild.zig:156`），一般不需要再开 `log stream`。

### Inspector

inspector 的作用类似浏览器开发者工具，可以检视并修改终端状态（`src/inspector/AGENTS.md:3-5`）。

- 默认键绑定：非 Darwin 是 `ctrl+shift+i`（`src/config/Config.zig:6875-6880`，位于 `src/config/Config.zig:6685` 开头的非 Darwin 分支）；Darwin 是 `cmd+opt+i`（`src/config/Config.zig:7222-7227`，位于 `src/config/Config.zig:6987` 开头的 Darwin 分支）。两处注释都写着 "Inspector, matching Chromium"。
- 键绑定动作是 `inspector: InspectorMode`，取值 `toggle` / `show` / `hide`（`src/input/Binding.zig:691-694`、`:1196-1200`）。
- 不要和 `show_gtk_inspector` 混淆，后者显示的是 GTK 自己的 inspector，且在 macOS 上无效（`src/input/Binding.zig:696-699`）。
- 实现在 `src/inspector/`；该包内**没有单元测试**（`src/inspector/AGENTS.md:12`）。在 macOS 上改 inspector 时用 `-Demit-macos-app=false` 构建来验证 API 用法（`src/inspector/AGENTS.md:11`）。
- 没有找到配置文件级别的 inspector 开关，只有键绑定（未核实：`inspector` 在 `src/config/Config.zig` 只有三处命中，其余两处是上述键绑定、一处是 GTK inspector 的文档说明；不要臆造 `inspector = true` 之类的配置项）。

## 测试

```sh
zig build test -Dtest-filter=<test name>
```

出处：step 声明在 `build.zig:67`，`AGENTS.md:11-14` 明确要求优先用 `-Dtest-filter`，因为全量测试很慢。`-Dtest-filter` 是 `[][]const u8`，可以给多个（`build.zig:43-47`）。

测试可执行文件叫 `ghostty-test`，用 baseline CPU target、`.Debug`、`use_llvm = true` 构建（`build.zig:344-357`）；注释写明不开 `use_llvm` 在 x86_64 上会崩。

**macOS 坑**：不带 `-Dtest-filter` 时，`zig build test` 会额外挂上 xctest 依赖（`build.zig:292-295`），实际去跑 `xcodebuild test -scheme Ghostty -skip-testing GhosttyUITests`（`src/build/GhosttyXcodebuild.zig:103-108`）。想只跑 Zig 单元测试就传空 filter，CI 正是这么做的（`.github/workflows/test.yml:1246-1248`）：

```sh
zig build test -Dtest-filter=""
```

libghostty-vt 的测试单独有 step，它跑 `mod.vt` 与 `mod.vt_c` 两个模块（`build.zig:68-71`、`:325-338`）。改动落在 libghostty-vt 文件里时优先用它（`AGENTS.md:23-24`）：

```sh
zig build test-lib-vt -Dtest-filter=<filter>
```

macOS 侧的 Swift 单元测试（`macos/AGENTS.md:11`）；脚本在 action 为 `test` 时自动追加 `-skip-testing GhosttyUITests`，因为 UI 测试需要特殊权限（`macos/build.nu:14-20`）：

```sh
macos/build.nu --action test
```

有些慢测试由环境变量门控，例如 LZ4 的穷尽差分测试（`src/terminal/compress/AGENTS.md:86`）：

```sh
GHOSTTY_LZ4_SLOW=1 zig build test -Dtest-filter="lz4 differential"
```

## 内存检查

```sh
zig build run-valgrind
```

出处：step 声明在 `build.zig:63-66`，说明见 `HACKING.md:238-255`。

实现上它先用 baseline CPU target 重建可执行文件（`build.zig:301-310`），再用固定参数集运行：`valgrind --leak-check=full --num-callers=50 --suppressions=<repo>/valgrind.supp --gen-suppressions=all`（`build.zig:312-317`）。抑制文件 `valgrind.supp` 在仓库根（2441 行）。和 `run` 一样，`--` 之后可以追加配置参数（`build.zig:320`、`HACKING.md:257-258`）。

**限制**：整个 Valgrind 分支被 `if (config.app_runtime != .none)` 包住（`build.zig:300`），所以 macOS 默认配置下 `run-valgrind` 不会挂任何依赖，等于空跑；实际只在 Linux 有意义（`nix/devShell.nix:161` 也只在 Linux 分支提供 `valgrind`）。

另有一个跑测试的变体，参数集相同（`build.zig:72-75`、`:375-385`）：

```sh
zig build test-valgrind
```

## Benchmark

benchmark 工具分两个角色：`ghostty-gen` 生成合成输入数据，`ghostty-bench` 消费已有数据并跑基准（`src/benchmark/AGENTS.md:3-6`）。两个二进制（`ghostty-gen` 定义在 `src/build/GhosttyBench.zig:17-31`，`ghostty-bench` 在 `:33-46`）都被硬编码为 `.optimize = .ReleaseFast` 构建，并安装到 `zig-out/bin`（`:52-54`）。

```sh
zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false
```

出处：`src/benchmark/AGENTS.md:34-35`、`build.zig:104-107`。`AGENTS.md` 强调必须指定 `-Doptimize=ReleaseFast`，否则 debug 构建极慢、不能代表真实性能（`src/benchmark/AGENTS.md:36-38`）。

纪律（全部出自 `src/benchmark/AGENTS.md:10-30`）：

1. 先生成数据、后跑基准；**不要**把 `ghostty-gen` 直接管道接进 `ghostty-bench`，那会把生成开销混进测量。
2. 跨版本比较时复用完全相同的生成文件，优先用固定 seed。
3. 用 `hyperfine` 比较，基准对象是 `ghostty-bench` 命令行而不是生成器。
4. 多次 warmup、重复测量取中位数；跨分支比较时保持输入与 CLI 参数（含终端尺寸）完全一致。
5. **绝不**在同一台机器上并行跑多个 benchmark。
6. 大语料放在仓库外。

跨分支比较的做法是各分支分别构建后把 `zig-out/bin/ghostty-bench` 改名为 `ghostty-bench-branch1` / `ghostty-bench-branch2`，再用 `hyperfine` 比较这几个二进制（`src/benchmark/AGENTS.md:40-48`）。

可用的 benchmark 名共 14 个（`src/benchmark/cli.zig:9-23`）：`apc-parser`、`codepoint-width`、`grapheme-break`、`hyperlink-map`、`page-compression`、`scrollback-compression`、`screen-clone`、`terminal-formatter`、`terminal-parser`、`terminal-resize`、`terminal-snapshot`、`terminal-stream`、`is-symbol`、`osc-parser`。合成数据生成器可用类型共 5 个（`src/synthetic/cli.zig:8-13`）：`ascii`、`kitty`、`osc`、`styled`、`utf8`。

以下示例原样引自源码注释（出处：`src/benchmark/PageCompression.zig:51-59`）：

```sh
ghostty-bench +page-compression --mode=report --data=/tmp/pages.raw
```

`+page-compression` 的模式有 `compress`、`decompress`、`store`、`report`（`src/terminal/compress/AGENTS.md:50-51`）；`+scrollback-compression` 测的是 `PageList` 在 codec 周边的状态转换，而不是 codec 本身（`src/terminal/compress/AGENTS.md:58-59`）。

## 提交前自检

在仓库根依次执行（按改动范围取用）：

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

出处：前三条见 `AGENTS.md:15-17`；`HACKING.md:197` 给的 SwiftLint 命令是不带 `--strict` 的 `swiftlint lint --fix`，`HACKING.md:210-212` 给了只检查不修复的 `--strict` 版本；`alejandra .` 只在改了 `.nix` 文件时需要（`HACKING.md:159-163`）。CI 对应的检查是 `zig fmt --check .`（`.github/workflows/test.yml:1653`）、`prettier --check .`（`:1714`）、`swiftlint lint --strict`（`:1744`）、`alejandra --check .`（`:1772`）。

Shell 脚本用 ShellCheck，命令原样引自 `HACKING.md:183-186`（CI 版多一个 `--color=always`，`.github/workflows/test.yml:1829-1833`）：

```sh
shellcheck --check-sourced --severity=warning $(find . \( -name "*.sh" -o -name "*.bash" \) -type f ! -path "./zig-out/*" ! -path "./macos/build/*" ! -path "./.git/*" | sort)
```

其余情形：

- Nix 用户统一加前缀 `nix develop -c <tool> ...`（`HACKING.md:142-146`、`:153-157`、`:171-178`、`:202-212`）。工具版本要与 `nix/devShell.nix` 对齐（`HACKING.md:140`、`:165`、`:200`）。
- 改了 `build.zig.zon` 之后跑 `./nix/build-support/check-zig-cache.sh --update`，它会写出 `nix/zigCacheHash.nix`，需要一并提交（`HACKING.md:225-232`）。
- 改了 i18n 字符串跑 `zig build update-translations`（`build.zig:76-79`、`:388-394`）；注意 `-Di18n=false` 时这个 step 会直接报错 "cannot update translations when i18n is disabled"（`build.zig:392-394`）。细节见 [po/README_CONTRIBUTORS.md](../po/README_CONTRIBUTORS.md)。
- 发布相关的 `zig build dist` 与 `zig build distcheck`（`build.zig:112`、`:114`）；产物路径未核实（本文未构建过）。
- 贡献流程见 [CONTRIBUTING.md](../CONTRIBUTING.md)，本文不复述。

## 常见坑与排错

- **Debug 构建性能极差** — 启动就会打三行 warn（`src/main_ghostty.zig:61-65`）。不要拿 debug 构建测性能，测性能一律 `-Doptimize=ReleaseFast`（`src/benchmark/AGENTS.md:36-38`）。
- **macOS 上 `zig-out/bin/ghostty` 不是终端本体** — `app_runtime` 默认 `.none`（`src/apprt/runtime.zig:20-23`），直接跑只会打印 `Usage: ghostty +<action> [flags]` 和一段说明然后 `exit(0)`（`src/main_ghostty.zig:77-96`）。真正的终端在 `Ghostty.app`，说明里给出的命令行启动方式是 `open -na Ghostty.app --args --foo=bar --baz=qux`（`src/main_ghostty.zig:86-87`）。
- **改了 `src/` 但 macOS app 行为没变** — 忘了先跑 `zig build -Demit-macos-app=false` 刷新 `macos/GhosttyKit.xcframework`（`macos/AGENTS.md:4-6`、`src/build/GhosttyXCFramework.zig:40-41`）。
- **手敲 `xcodebuild` 报怪错** — Nix 环境变量污染。用 `macos/build.nu`（`env -i`，`macos/build.nu:22-24`），或参考 `src/build/GhosttyXcodebuild.zig:56-60` 只保留 `PATH`；CI 注释同样警告（`.github/workflows/test.yml:1158-1160`）。
- **Xcode 版本选错** — 用 `sudo xcode-select --switch /Applications/Xcode.app` 切换（`HACKING.md:55-61`）；main 分支需要 Xcode 26 与 macOS 26 SDK（`HACKING.md:65`）。
- **`zig build test` 在 macOS 上莫名去跑 Xcode** — 不带 `-Dtest-filter` 时会附加 xctest 依赖（`build.zig:292-295`），传 `-Dtest-filter=""` 规避。
- **`-Demit-docs` 悄悄关掉了** — 默认只有 PATH 里找得到 `pandoc` 才为真；而且只要已经在 emit bench / test-exe / helpgen / lib-vt，就一律为假（`src/build/Config.zig:435-454`）。文档由 `pandoc` 生成（`src/build/GhosttyDocs.zig:60` 与 `src/build/GhosttyDocs.zig:75`）；不 emit docs 且目标是 Darwin 时会安装一个占位目录，因为 Xcode 工程期望 `share/man` 存在（`build.zig:90-97`、`src/build/GhosttyDocs.zig:111-116`）。
- **「libghostty」这个名字有歧义** — `-Demit-lib-vt` 产出的是终端库 libghostty-vt（`src/lib_vt.zig`，头文件在 `include/ghostty/vt/`）。macOS 侧那个历史同名物只是 GUI 与核心之间的胶水，`build.zig:189-191` 的注释原话是 "This is NOT libghostty (even though its named that for historical reasons)"，它的头文件是 `include/ghostty.h`。
- **`zig build run` 在 macOS 上不等于「像用户那样启动」** — 它设了 `GHOSTTY_MAC_LAUNCH_SOURCE=zig_run`（`src/build/GhosttyXcodebuild.zig:159`），而 `launchedFromDesktop()` 只在该值为 `"app"` 时返回真（`src/os/desktop.zig:28-35`），这会影响 `probableCliEnvironment()` 一类启发式（`src/config/Config.zig:5196-5207`）。要复现「从 Finder 启动」的行为，请用 `open` 打开 app bundle。
- **`zig build run-valgrind` 在 macOS 上是空操作** — 整个分支被 `app_runtime != .none` 包住（`build.zig:300`）。
- **改完 `build.zig.zon` 后 CI 挂** — Zig 缓存哈希漂移，跑 `./nix/build-support/check-zig-cache.sh --update`（`HACKING.md:221-232`）。
- **`HACKING.md:83` 提到的 `/gh-issue` 命令并不存在** — `.agents/` 下当前只有 `.agents/commands/review-branch` 与 `.agents/skills/writing-commit-messages/SKILL.md` 两个文件，该段文档已过时。
- **铁律** — 本仓库 `AGENTS.md:34-39` 明令：永远不要创建 issue，永远不要创建 PR。

## 在没有完整 Xcode 的 macOS 上开发

只装了 Command Line Tools（没装 Xcode.app）时，`zig build` 和 `zig build test` **都会失败**，报：

```text
xcrun: error: unable to find utility "metal", not a developer tool or in PATH
```

原因是 metallib 这一步对任何 Darwin 目标都无条件挂接（`src/build/SharedDeps.zig:499-505`，构造在 `:131-136`），`-Drenderer=opengl` 也绕不过——它是按目标操作系统挂的，不是按渲染后端。

根治办法是装完整 Xcode 26 加 Metal Toolchain。装不了的时候，纯 Zig 改动仍有两条可用的验证路径：

### 1. 跑独立模块的单元测试

不依赖 build 系统注入模块（如 `terminal_options`）的文件，可以直接跑：

```sh
zig test src/poltergeist/Watcher.zig
```

注意 `zig test` 的模块根是**该文件所在目录**，所以文件里不能 `@import("../…")`，否则会报 `import of file outside module path`。跨目录 import 的文件只能走下面第 2 条。

### 2. 交叉编译做全量类型检查

编到非 Darwin 目标就不会挂 metallib：

```sh
zig build test -Dtarget=x86_64-linux-gnu -Dapp-runtime=none -Demit-test-exe
```

- `-Dapp-runtime=none` 是必需的：Linux 默认 `gtk`（`src/apprt/runtime.zig:16-19`），会去找本机没有的 `gtk/gtk.h` 与 `adwaita.h`。
- 末尾必然报 `the host system ... is unable to execute binaries from the target`。那是**运行**步骤失败，不是编译失败。只看 `^src/` 开头的行来判断有没有真错误。

这条能覆盖全部 Zig 代码的类型检查，但**覆盖不到 macOS 专有的条件编译分支**。实测遇到过只在 macOS 目标下才暴露的编译错误，所以只跑 Linux 目标是不够的。

> 如果你确实需要验证 macOS 目标的编译，可以临时把 `src/build/MetallibStep.zig` 里那两条 `xcrun` 调用换成 `/usr/bin/touch`（产出空的假 metallib），跑 `zig build test -Dtarget=aarch64-macos -Demit-test-exe` 做类型检查，然后**立刻还原该文件**。假 metallib 只够骗过编译，链接和运行都会失败，绝不可提交。

## Nix VM 与集成测试

本文只指路，不展开。

- 桌面环境 VM：`nix run .#<vmtype>`，`<vmtype>` 是 `nix/vm` 目录下去掉 `.nix` 后缀的文件名，排除以 `common` 或 `create` 为前缀的文件；源码目录会挂到 VM 的 `/tmp/shared`（`HACKING.md:350-360`）。
- 集成测试：`nix run .#checks.<system>.<test-name>.driver`，`<system>` 取 `x86_64-linux` 或 `aarch64-linux`，`<test-name>` 来自 `nix/tests.nix`；`nix flake check` 跑全部（`HACKING.md:441-451`）。
- macOS 上运行这些需要在 nix-darwin 里启用 Linux builder，交互式与 SSH 调试细节见 `HACKING.md:453` 及其后续章节。

## 延伸阅读

- 仓库内：[HACKING.md](../HACKING.md)、[AGENTS.md](../AGENTS.md)、[macos/AGENTS.md](../macos/AGENTS.md)、[src/benchmark/AGENTS.md](../src/benchmark/AGENTS.md)、[src/inspector/AGENTS.md](../src/inspector/AGENTS.md)、[src/terminal/compress/AGENTS.md](../src/terminal/compress/AGENTS.md)、[po/README_CONTRIBUTORS.md](../po/README_CONTRIBUTORS.md)
- 同目录：[README.md](README.md)、[architecture.md](architecture.md)、[terminal-core.md](terminal-core.md)、[rendering-and-font.md](rendering-and-font.md)、[platform-and-config.md](platform-and-config.md)、[\_conventions.md](_conventions.md)
