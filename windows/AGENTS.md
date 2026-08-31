# Polter on Windows

Two crates live here, deliberately separate:

| | |
| --- | --- |
| `host/` | the application shell -- windows, tabs, keyboard, IME, libghostty |
| `split-tree/` | the split layout algorithm, ported from `SplitTree.swift`. **Zero dependencies on purpose**, so it is testable with `cargo test` on the machine the port is written on rather than only on the Windows box. |

They are not wired together yet. When they are, the shape should be a **path
dependency** (and probably a workspace here, so there is one lock file), not a
copy of the algorithm into `host/src/` -- this directory already paid once for
a fork that had to be merged back by hand.

`host/` is the Windows application shell: a Rust binary that opens the windows,
owns the tabs, the keyboard and the input method, and drives the terminal
through libghostty's C API. It is to Windows what `macos/` is to macOS -- the
shared core stays in `src/`, and nothing here is built by `zig build`.

## Build

```
cd windows/host
cargo build --release --target x86_64-pc-windows-gnu
```

- **`-gnu`, not `-msvc`.** The core is built with Zig's mingw-w64 target and
  the two have to agree.
- **The target directory must not contain a space.** `dlltool` splits its
  arguments on whitespace, so a checkout under a path like
  `~/claude lugia/ghostty` fails during dependency compilation with
  `can't open ...dllh.o`, before any of this code is looked at. Build with
  `CARGO_TARGET_DIR` pointing somewhere without spaces.

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
