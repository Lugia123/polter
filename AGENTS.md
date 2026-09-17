# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
  - If you're on macOS and don't need to build the macOS app, use
    `-Demit-macos-app=false` to skip building the app bundle and speed up
    compilation.
- **Test (Zig):** `zig build test`
  - Prefer to run targeted tests with `-Dtest-filter` because the full
    test suite is slow to run.
  - ⚠️ **但交付前必须跑一次不带 filter 的 `zig build test`。** 带 filter 的构建
    **不编译没被选中的测试**，所以它的绿连「这棵树编得过」都不证明。见下一节。
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (Swift)**: `swiftlint lint --strict --fix`
- **Formatting (other)**: `prettier -w .`

## 验证：这个仓栽过的几条

**这一节的每一条都对应一次真实的返工，不是通用建议。**

1. **带 filter 的绿几乎不证明什么。** `-Dtest-filter` 确实在过滤，但**匹配不到时
   不是 0 pass，是一个健康的三位数 + exit 0**（那批测试无论 filter 写什么都跑）。
   而且带 filter 的构建**不编译**其它测试——一次全量 `zig build test` 曾在六个
   「全绿」的提交之后，红在一条从没被编译过的穷举 switch 上。
   ⇒ **报计数要同时报基线**（`-Dtest-filter=zz-nothing`），差值才是你的测试；
   ⇒ **报读数一律带 `--summary all`**，`--summary` 的默认值随「短命/长命」变，
   全绿时可能一个字节都不打印。

2. **绿不是证据，地板才是。** 一条判据要先**故意打坏被测对象、看它红在哪一条**，
   才算数。⚠️ 而且**要读红的是哪一行**：本仓已三次出现「编译错误冒充地板」——
   把守卫整行删掉会得到 `unused function parameter`，那一格其实一次都没跑到断言。
   拆守卫时要让代码**仍然编得过**（用 `if (...) {}` 而不是删行）。

3. **「我读到了代码」≠「我编的是那份代码」。** 在提交 A 上建树、却用工作副本
   （已经是 B）确认「修复在不在里面」——于是量到的全是修复前的读数，而它会被
   报成「修好了还是不对」。⇒ 证据要取自**被测的那棵树/那个产物本身**
   （在建好的树里 grep，或 `nm` 查产物的符号）。

4. **闸是两个集合。** `windows/tools/` 那十六道**不覆盖仓根 `tools/`**，而公开仓的
   泄密闸在仓根。⚠️ 泄密闸**只扫已跟踪的文件**，所以顺序固定是
   **`git add` → 跑闸 → `git commit`**；判据是 `scanned N tracked files` 的 N 变了。

5. **两件事长得一样时，加一个状态位把它们分开。** 判据：这个标志是不是同时在说
   「我不知道」和「我知道，答案是没有」？或者同时在说「会自己好」和「永远不会好」？
   任一为是就该分。

6. **失败的形式是「某处沉默」时，让沉默编不过。** 结构体字段取消默认值 + 给一个
   写全了的具名常量（`X.none`），于是漏填当场是编译错误、编译器点名缺哪个。
   **消费端的判据永远看不见生产端的沉默**，再加一个观察者没用。

7. **多 agent 同一棵树时**：**一次构建读到的树，必须在整个构建期间没有人写。**
   要构建就独占并说一声；不构建不用排队。⚠️ `zig build`（**任何形态，包括
   `-Demit-macos-app=false`**）会**先删后建** `macos/GhosttyKit.xcframework`，
   期间任何 `xcodebuild` 都会死在一个与你的改动毫无关系的路径上。

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Dtest-filter=<filter>`
  - Prefer this when the change is in a libghostty-vt file
- All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`
  sentinel as the last entry to force int enum sizing (pre-C23 portability).

## Directory Structure

- Shared Zig core: `src/`
- macOS app: `macos/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`

## Repository Map

`src/` shared Zig core, `macos/` Swift app, `include/` public C headers,
`pkg/` and `vendor/` third-party, plus `test/`, `nix/`, `po/`, `dev-docs/`.

Inside `src/`: `main_ghostty.zig` (entrypoint), `App.zig` / `Surface.zig`
(one surface per terminal), `apprt/` (runtime abstraction: `none`, `gtk`,
`embedded`), `termio/` (pty IO), `terminal/` (VT core), `renderer/`,
`font/`, `config/`, `input/`, `cli/`, `build/`.

Nested `AGENTS.md` files carry rules for their own subtree; read the nearest
one before editing. They exist under `macos/`, `example/`, `src/benchmark/`,
`src/inspector/`, `src/terminal/c/`, `src/terminal/snapshot/`,
`src/terminal/compress/`, `src/terminal/apc/glyph/`, `test/fuzz-libghostty/`.

## Conventions

- `PascalCase.zig` means the file itself is a type (`src/Surface.zig`,
  `src/font/Atlas.zig`); most alias it with `const X = @This();`.
- `lowercase.zig` is a namespace module that re-exports types. A directory
  package uses `main.zig` as its namespace.
- GTK GObject classes are the exception: lowercase files under
  `src/apprt/gtk/class/` that export a PascalCase type.
- Module-level documentation goes in `//!` comments at the top of the file.

## Docs

`dev-docs/README.md` is the index. Start with `dev-docs/preview-manual.md` to build,
run or debug, and `dev-docs/architecture.md` for how the pieces fit together.
Code is always the source of truth; if a doc disagrees, fix the doc.

Where a keypress actually goes on Windows -- split by whether the host or the
core handles it, the known cases where a menu's label and the key's behaviour
disagree, and why most work on the test machine should never touch the GUI:
`dev-docs/windows/keys.md`. Read it before changing the accelerator table in
`keys.rs` or `Keybinds.init` in `Config.zig`.

## Issues and PRs

**File them here, never upstream.** `upstream` is a configured remote
(`ghostty-org/ghostty`) with a push URL, so nothing mechanical stops a mistake
that would arrive on somebody else's project under this repository owner's
name. Upstream has closed issue creation anyway, so there is nothing to file
into and no judgement call to make: the answer is always this repository.

Filing into **this** repository is ordinary and needs no permission. An
unreproduced bug, a limitation worth stating, a fix believed rather than
proven -- all of those are better in the tracker than in a commit message
nobody will search.

> This replaces an unconditional "never create an issue" that came from
> upstream and was retired in `438a2e352`. That commit named the guard going
> missing with it, and left the narrow version available "if the first agent
> to try makes the case for it". Opening the repository to outside
> contributors is that case.
