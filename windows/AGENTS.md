# Polter on Windows

Two crates live here, deliberately separate:

| | |
| --- | --- |
| `host/` | the application shell -- windows, tabs, keyboard, IME, libghostty |
| `split-tree/` | the split layout algorithm, ported from `SplitTree.swift`. **Zero dependencies on purpose**, so it is testable with `cargo test` on the machine the port is written on rather than only on the Windows box. |

`host/` declares `polter-split-tree` as a **path dependency** and does not yet
call it; making the tab model use it is separate work. It is a dependency
rather than a copy because copying would throw away the reason the algorithm
is testable on macOS, and would create a second copy to keep in agreement --
this directory already paid once for a fork that had to be merged back by hand.

## One surface, one HWND -- and what that forces

A libghostty surface is bound to the `HWND` it was created with for its whole
life, and `wgl.zig` takes a `CS_OWNDC` device context for that window and keeps
it until the context is destroyed.

**So a split on Windows is necessarily several child windows, and cannot be
one surface drawing into several regions.** macOS can nest `NSView`s inside a
single surface's view, so the SwiftUI side is free to treat a split as a layout
detail; here it is a window-management fact. Anyone arriving from the macOS
code will reach for "draw two panes in one surface" first, and that wall is
where they will stop.

The same fact is why a tab is a child window rather than a repaint, and why
`tabs.rs` is a tree of leaves each owning one `HWND` plus one surface.

**Two more consequences, both of which cost a real-machine round trip to find:**

- A surface window must be **created at its final size** before
  `ghostty_surface_new`; a later `set_size` does not repair it. See
  `docs/windows/development.md` section 5.2, item 4.
- Identity is `PaneId` / `TabId` out of one shared counter, **never an index**.
  Panes and tabs are reordered and removed, and an index quietly starts naming
  a different one.

**`[profile]` belongs in `windows/Cargo.toml`, not in a member.** Cargo ignores
a member's profile inside a workspace and only warns; the symptom is a release
binary that quietly went back to unwinding panics.

`host/` is the Windows application shell: a Rust binary that opens the windows,
owns the tabs, the keyboard and the input method, and drives the terminal
through libghostty's C API. It is to Windows what `macos/` is to macOS -- the
shared core stays in `src/`, and nothing here is built by `zig build`.

## Build

`windows/` is a Cargo workspace; build from here, not from a member.

```
cd windows
cargo build --release --target x86_64-pc-windows-gnu -p polter-host
cargo test -p polter-split-tree        # native, runs anywhere
```

- **`-gnu`, not `-msvc`.** The core is built with Zig's mingw-w64 target and
  the two have to agree.
- **The target directory must not contain a space.** `dlltool` splits its
  arguments on whitespace, so a checkout under a path like
  `~/claude code/ghostty` -- **the space is the whole point of the example**
  -- fails during dependency compilation with `can't open ...dllh.o`, before
  any of this code is looked at. Build with `CARGO_TARGET_DIR` pointing
  somewhere without spaces. Two people hit this independently in one night
  and both first read it as a broken dependency.

The host loads **two** DLLs at runtime: `ghostty-internal.dll` (the surface
API) and `ghostty-vt.dll` (the width table the IME needs). Both must sit next
to `polter-host.exe`. There is no import library, which is why every entry
point is resolved with `GetProcAddress` in `main.rs`.

## Names

User-visible strings are **Polter** -- window classes, default title, log
header, binary name. Internal artifacts keep the upstream Ghostty names, so
merging upstream stays cheap. See `docs/windows/development.md` section 4.2;
the Windows-only places that are easy to miss (window class, AppUserModelID,
mutex, registry) are listed there.

## Files

| | |
| --- | --- |
| `main.rs` | libghostty startup, the frame window, the TSF-aware message pump, the action callback |
| `tabs.rs` | the tab model, one HWND per surface, the queued window mutations, the surface window procedure |
| `keys.rs` | Windows key events to `ghostty_surface_key`, and the host accelerators |
| `tsf.rs` | the `ITextStoreACP` the IME composes into |
| `ffi.rs` | the hand-written C ABI, with the measured struct sizes asserted at compile time |

Read the header comment of each before changing it: the contracts that
`wgl.zig` and TSF impose on this host are written there, and **not one of
them fails loudly** when broken.

## Where the ground truth is

`docs/windows/status.md` -- what is verified on a real machine and what is
still owed. Claims there are marked 实测 or not; unmarked means untested.

## 提交前要跑的检查

`windows/tools/` 下每一个 `.py` 都是一道闸,**提交前全部跑一遍**——不是挑着跑:

```sh
for t in windows/tools/*.py; do python3 "$t" || echo "FAILED: $t"; done
python3 tools/no-local-identifiers.py     # 仓库根,不在这个目录里
```

**这里不列它们的名字,也不列个数。** 上一版文档写了「三个 lint」并把名字抄了一遍,
**当天就多了第四个,而那句话没人改**——一份会过期的清单比没有清单更糟,
因为读的人以为它是全的。glob 不会过期。

每一道闸都带自我检查(`probe self-test: OK`),**那一行不出现就说明检查器本身没工作**;
`no-local-identifiers.py` 还带一个正控制。**读输出,不要只读退出码**:
其中一道是棘轮——数字比基线低也会失败,消息会告诉你把基线改成多少。

⚠️ **在一棵已经红的树上做地板注入时,比对具体那一行,不要看退出码**:
树本来就是红的,于是任何地板都看起来响了。
