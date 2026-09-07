# Ghostty Architecture

> Last updated against git commit: `f81dcadc8`
> (`f81dcadc82ea2afdcf2dc92929037701122f05b5`, 2026-08-14)
> How to check: `git log -1 --format='%H %h %ad %s'`
>
> English translation of [`../architecture.md`](../architecture.md), which is
> the original and wins if the two disagree. Terminology follows
> [`GLOSSARY.md`](GLOSSARY.md).

## What this document covers

- A module map of `src/`: what each subpackage is responsible for, and roughly
  how big it is.
- The three comptime interfaces — apprt, renderer backend, font backend — and
  how the target and the build options pick each one.
- The two startup paths: `src/main_ghostty.zig` on Linux and FreeBSD, and
  Swift's `main.swift` driving the Zig core through the C API on macOS.
- The per-surface thread model, and the four mailboxes between the threads.
- What `renderer.State.mutex` protects, and the `lockDemand` / `yieldToDemand`
  mechanism that keeps the renderer from starving.
- The whole hop-by-hop path from a keypress to a pixel.
- How to tell apart the two different things called "libghostty".

## What this document does not cover

- VT sequence parsing, the `Screen` / `PageList` / `Page` storage, and the
  libghostty-vt C API — see [`../terminal-core.md`](../terminal-core.md).
- Renderer backend internals, shaders, font discovery and text shaping — see
  [`../rendering-and-font.md`](../rendering-and-font.md).
- The insides of each apprt, the macOS Swift layer, and the details of
  `src/config` and `src/input` — see
  [`../platform-and-config.md`](../platform-and-config.md).
- Any build, run or debug command. [`preview-manual.md`](preview-manual.md) is
  the single authority on those.
- The full list of build options (`src/build/Config.zig` is 803 lines). This
  document only covers the three comptime interfaces that shape the
  architecture, plus the matrix of build products.

## In one sentence

Ghostty is a platform-independent Zig core plus an application runtime (apprt)
chosen at compile time. Inside the core, `App` owns some number of `Surface`s,
and each `Surface` creates and owns its own pty session, its own terminal state
and its own renderer (`src/App.zig:1-3`, `src/Surface.zig:1-11`). The apprt
abstracts away platform work — creating windows, receiving keyboard and mouse
events — so that different implementations share as much core logic as possible
(`src/apprt.zig:1-10`). Linux and FreeBSD default to the GTK4 apprt and produce
an executable directly; everywhere else, macOS included, the default is
`app_runtime = .none`, the core is compiled into a library, and an external
application links against it and drives it (`src/apprt/runtime.zig:14-24`).

## Map of the important files

| Path                             | Size                 | Responsibility                                                                     |
| -------------------------------- | -------------------- | ---------------------------------------------------------------------------------- |
| `build.zig`                      | 420 lines            | The build entry point, `pub fn build`; declares every product and step             |
| `src/build/Config.zig`           | 803 lines            | Every `-D` build option: its definition and how its default is derived             |
| `src/build_config.zig`           | 105 lines            | Turns build options into comptime constants for runtime code to use                |
| `src/main.zig`                   | —                    | Switches the entry point between ghostty/helpgen/mdgen/webgen by `exe_entrypoint`  |
| `src/main_ghostty.zig`           | 266 lines            | `main()` for the `ghostty` executable, and the logging implementation              |
| `src/main_c.zig`                 | 265 lines            | The process-level C API (`ghostty_init`, `ghostty_cli_try_action`, and so on)      |
| `src/App.zig`                    | 653 lines            | The core `App`: the surface list, the app mailbox, the shared font grid set        |
| `src/Surface.zig`                | 6121 lines           | The core `Surface`: thread orchestration, input dispatch, glue to termio/renderer  |
| `src/apprt.zig` + subdirectories | 59 lines + 63 `.zig` | The apprt abstraction and its none/gtk/embedded/browser implementations            |
| `src/termio/`                    | 9 `.zig`             | Terminal IO (termio): pty reads and writes, the writer thread, the reader pipeline |
| `src/terminal/`                  | 144 `.zig`           | The terminal core: VT parsing and screen data structures (see `terminal-core.md`)  |
| `src/renderer/`                  | 35 `.zig`            | The renderer and the renderer thread (see `rendering-and-font.md`)                 |
| `src/font/`                      | 50 `.zig`            | Font discovery, faces, shapers, the atlas                                          |
| `src/config/`                    | 20 `.zig`            | The configuration system; `src/config/Config.zig` alone is 11120 lines             |
| `src/input/`                     | 17 `.zig`            | Key encoding and keybindings; `src/input/Binding.zig` alone is 4924 lines          |
| `src/inspector/`                 | 13 `.zig`            | The terminal inspector                                                             |
| `src/cli/`                       | 28 `.zig`            | CLI actions of the form `ghostty +<action>`                                        |
| `src/os/`                        | 33 `.zig`            | The operating system adaptation layer                                              |
| `src/datastruct/`                | 11 `.zig`            | General-purpose data structures, including `BlockingQueue`                         |
| `src/build/`                     | 37 `.zig`            | The build script package (products, xcframework, i18n, …)                          |

Two naming conventions worth stating here, though the details are elsewhere:

- **`PascalCase.zig`** — the file _is_ a type, and usually has `= @This()` near
  the top; for example `const App = @This();` at `src/App.zig:4`.
- **`lowercase.zig`** — a namespace module that only imports and re-exports; for
  example `src/terminal/main.zig:8-30`. The full set of conventions is in the
  Conventions section of the root [`AGENTS.md`](../../AGENTS.md).

## The two core objects: App and Surface

### App

`App`'s own comment describes it as ghostty's main GUI application object,
responsible for creating windows and assembling renderers, with the main loop
started by `run` (`src/App.zig:1-3`). The state it holds that matters:

- **`surfaces`** — the list of live `*apprt.Surface`s (`src/App.zig:27-28`).
- **`mailbox`** — the app thread's message queue. The comment warns that a full
  queue either errors or blocks (`src/App.zig:50-51`).
- **`font_grid_set`** — a `font.SharedGridSet` shared between surfaces whose
  configuration matches (`src/App.zig:53-55`).
- **`config_conditional_state`** — the conditional state for app-level
  configuration, which doubles as the default for new surfaces
  (`src/App.zig:63-66`).
- **`focused`** / **`focused_surface`** — whether the app has focus, and the
  surface that had it last. The comment is explicit that `focused_surface` may
  already be dead and must be validated with `hasSurface` first
  (`src/App.zig:30-47`).

`App.deinit` closes every surface and then asserts
`font_grid_set.count() == 0` — teardown only happens when the app is shutting
down, by which point every surface should have exited cleanly
(`src/App.zig:132-143`).

### Surface

A `Surface` is "the minimal widget the terminal is drawn on and which responds
to keyboard and mouse events", and each one creates and owns its own pty
session. Whether it is a window, a tab, a split, or a preview pane inside a
larger window is entirely the apprt's business; this struct does not care
(`src/Surface.zig:1-11`).

Input handling returns a three-state `InputEffect`
(`src/Surface.zig:187-200`):

- **`ignored`** — Ghostty did nothing with it; hand it back to the OS or
  whatever other subsystem should see it next.
- **`consumed`** — Ghostty handled it and consumed it.
- **`closed`** — the input closed the surface. The `Surface`, the runtime
  surface and any other pointer may already be unsafe, so the caller must
  return immediately.

## The three comptime interfaces

Ghostty nails down three things once, at compile time: which apprt, which
renderer backend, which font backend. All three come out of
`BuildConfig.fromOptions()` and are exported at the top level of
`src/build_config.zig:41-43`.

### apprt: the application runtime

`apprt.runtime` branches first on the product type `build_config.artifact`, and
`exe` then subdivides on `app_runtime` (`src/apprt.zig:42-49`). `apprt.App` and
`apprt.Surface` are simply the same-named types inside whichever implementation
was chosen (`src/apprt.zig:51-52`).

| `artifact`    | `app_runtime`  | Implementation           | Source             |
| ------------- | -------------- | ------------------------ | ------------------ |
| `exe`         | `.none`        | `src/apprt/none.zig`     | `src/apprt.zig:44` |
| `exe`         | `.gtk`         | `src/apprt/gtk.zig`      | `src/apprt.zig:45` |
| `lib`         | not applicable | `src/apprt/embedded.zig` | `src/apprt.zig:47` |
| `wasm_module` | not applicable | `src/apprt/browser.zig`  | `src/apprt.zig:48` |

Things to know:

- `artifact` is not a build option. `Artifact.detect()` derives it from
  `builtin.output_mode` (`src/build_config.zig:32`,
  `src/build_config.zig:83-98`).
- `Runtime.default` returns `.gtk` only for Linux and FreeBSD, and `.none`
  everywhere else. The comment says outright that `.none` means no executable
  is produced — a library is produced instead, and on macOS Xcode builds the
  application that links it (`src/apprt/runtime.zig:14-24`).
- So on macOS the core is compiled as a `lib` and the apprt in effect is
  `embedded`: Ghostty embedded inside a host application, not owning the
  application lifecycle (`src/apprt/embedded.zig:1-5`).
- `none` is a shell and nothing more: its `App` has a single `performIpc` that
  always returns `false`, and its `Surface` is an empty struct
  (`src/apprt/none.zig:8-19`).
- The `browser` branch exists in the selection table (`src/apprt.zig:19`,
  `src/apprt.zig:48`), but this document says nothing about how it behaves
  (not verified: `src/apprt/browser.zig` has not been read and the wasm build
  path has not been exercised; to verify, read that file and build for a wasm
  target).

### Renderer backend and font backend

`renderer.Renderer` is one of `GenericRenderer(Metal)`,
`GenericRenderer(OpenGL)` or `WebGL` (`src/renderer.zig:38-42`). The default is
decided by the target (`src/renderer/backend.zig:10-22`):

| Condition          | Renderer backend | Font backend          |
| ------------------ | ---------------- | --------------------- |
| `wasm32` + browser | `webgl`          | `web_canvas`          |
| Windows            | `opengl`         | `freetype_windows`    |
| Darwin             | `metal`          | `coretext`            |
| everything else    | `opengl`         | `fontconfig_freetype` |

The font backend defaults come from `src/font/backend.zig:39-61`. The comment
there explains that Windows avoids fontconfig because its libxml2 dependency
can fail to unpack when symlinks are involved. Both backends are described from
the inside in [`../rendering-and-font.md`](../rendering-and-font.md).

## Process startup: two paths

Before either path, note that an executable's Zig entry point is not fixed.
`src/main.zig` switches between `src/main_ghostty.zig`, `src/helpgen.zig`, two
mdgen entry points and three webgen entry points according to
`build_config.exe_entrypoint`, then re-exports the chosen module's `main`
unchanged (`src/main.zig:4-16`). Only the `.ghostty` branch is described below.

### Linux and FreeBSD: an executable

1. `main(minimal)` is the entry point (`src/main_ghostty.zig:26`).
2. `global.init` sets up process-level global state
   (`src/main_ghostty.zig:31`). If it parses out a `+action`, it forcibly
   disables stderr logging so the logs cannot contaminate the action's output
   (`src/global.zig:129-141`), and then resolves the log destination from the
   `GHOSTTY_LOG` environment variable (`src/global.zig:148-155`).
3. Debug builds print three lines of "performance will be poor" warning
   (`src/main_ghostty.zig:61-65`).
4. If there is a CLI action, run it and `std.process.exit`
   (`src/main_ghostty.zig:68-75`).
5. If `build_config.app_runtime == .none`, print a block of help text and
   `exit(0)`. The text says explicitly that starting a terminal means starting
   the graphical application (`src/main_ghostty.zig:77-97`).
6. Create the core `App` (`src/main_ghostty.zig:100`; the implementation is at
   `src/App.zig:77`).
7. Then `apprt.App.init`, an optional `startQuitTimer`, and finally
   `apprt.App.run()` to enter the GUI event loop
   (`src/main_ghostty.zig:104-114`).

### macOS: a Swift application driving the Zig library

1. Swift's `main.swift` calls `ghostty_init` first
   (`macos/Sources/App/main.swift:8`). The C side is the same `global.init`,
   returning 1 on failure (`src/main_c.zig:110-135`).
2. Then `ghostty_cli_try_action()`
   (`macos/Sources/App/main.swift:31`): if there is an action it runs it and
   exits the process, otherwise it returns (`src/main_c.zig:139-148`). This is
   why `ghostty +version` and its relatives still work on macOS.
3. Only then does it enter `NSApplicationMain`
   (`macos/Sources/App/main.swift:33`).
4. The Swift side builds a runtime configuration — including `wakeup_cb` and
   `action_cb` — and calls `ghostty_app_new`
   (`macos/Sources/Ghostty/Ghostty.App.swift:61-71`). On the C side, `app_new_`
   does `CoreApp.create` and then creates and `init`s the embedded `App`
   (`src/apprt/embedded.zig:1426-1440`).
5. Swift's `appTick()` calls `ghostty_app_tick`
   (`macos/Sources/Ghostty/Ghostty.App.swift:107-109`) →
   `v.core_app.tick(v)` (`src/apprt/embedded.zig:1444-1448`) → and the entirety
   of `App.tick`'s job is to drain the app mailbox (`src/App.zig:156-159`).

Note that on the macOS path `main()` at `src/main_ghostty.zig:26` is not the
process entry point, so step 5 of the previous path — print help and exit —
only holds for the executable form. macOS defaults to `app_runtime == .none`,
and `build.zig:180-185` only installs an executable when
`app_runtime != .none`.

### The two warmup threads in App.create

After `init`, `App.create` conditionally spawns two detached threads to warm
things up: `font.Discover.warmup` (CoreText and friends have a one-off startup
cost in the milliseconds) and `renderer.Renderer.API.warmup` (Metal's framework
initialisation, for instance). Both are guarded by `@hasDecl`, so a backend
that does not declare one gets no thread (`src/App.zig:85-105`).

## The per-surface thread model

### The threads

| Thread      | Spawned at                      | Entry point                            | Responsibility                                  |
| ----------- | ------------------------------- | -------------------------------------- | ----------------------------------------------- |
| main thread | the apprt event loop            | `Surface.init` (`src/Surface.zig:466`) | Input dispatch, apprt actions, forwarding draws |
| `renderer`  | `src/Surface.zig:724-729`       | `src/renderer/Thread.zig:216`          | Update frame data and draw                      |
| `io`        | `src/Surface.zig:732-737`       | `src/termio/Thread.zig:136`            | Write to the pty, handle mode changes           |
| `io-reader` | `src/termio/Exec.zig:140-145`   | `src/termio/Exec.zig:1411` / `:1777`   | The VT parsing hot path                         |
| `io-gather` | `src/termio/Exec.zig:1461-1474` | `src/termio/Exec.zig:1525`             | POSIX only; owns fd polling and gathering       |
| `search`    | `src/Surface.zig:4991-4996`     | `src/terminal/search/Thread.zig:133`   | A search thread, created on demand              |

The corresponding fields on `Surface` are `renderer_thr`
(`src/Surface.zig:95`), `io` / `io_thread` / `io_thr`
(`src/Surface.zig:127-129`) and `search` (`src/Surface.zig:178`). The search
thread really is on demand: it is spawned and named `search` the first time it
is needed (`src/Surface.zig:4991-4996`), and passing search text of length 0
means stop searching. The `Search` struct has two fields, `state` and `thread`;
`deinit` notifies stop, joins, and only then deinits the state
(`src/Surface.zig:203-220`).

### The order Surface.init assembles things in

The threads are not spawned first. `Surface.init` (`src/Surface.zig:466`) lays
the state out in a fixed order and spawns at the end:

1. Construct the renderer instance, then separately `alloc.create` a
   `std.Io.Mutex` to protect the render state (`src/Surface.zig:567-570`).
2. Put that lock, together with `&self.io.terminal`, into `renderer_state`
   (`src/Surface.zig:609-612`).
3. Build the IO mailbox with `termio.Mailbox.initSPSC` (`src/Surface.zig:674`).
4. Call `termio.Termio.init`, injecting `renderer_state`, `renderer_wakeup`,
   `renderer_mailbox` and `surface_mailbox` all at once
   (`src/Surface.zig:677-687`).
5. Report `.cell_size` and `.size_limit` through `rt_app.performAction`
   (`src/Surface.zig:693-710`).
6. Call `renderer_impl.finalizeSurfaceInit` on the main thread. The comment
   says retina-related setup has to happen on the main thread before the
   renderer thread starts (`src/Surface.zig:720-722`).
7. Only now spawn the renderer thread and then the IO thread
   (`src/Surface.zig:724-737`).

### The picture

```text
                       ┌──────────────────────────────────────┐
                       │  main thread (apprt event loop)      │
                       │  App.drainMailbox / Surface.init     │
                       └───▲───────────────┬──────────────────┘
              app mailbox  │               │ apprt action
                           │               ▼
                       ┌───┴──────────────────────────────────┐
                       │  Surface (core)                      │
                       │  renderer_state (mutex + terminal)   │
                       └───┬───────────────┬──────────────────┘
        renderer mailbox   │               │  termio mailbox
        + renderer_wakeup  │               │  (spsc + wakeup)
                           ▼               ▼
                    ┌────────────┐   ┌────────────┐
                    │  renderer  │   │     io     │──── writes pty
                    └────────────┘   └────────────┘
                           ▲
                           │ renderer_wakeup.notify()
                    ┌──────┴─────┐   ┌────────────┐
                    │ io-reader  │◀──│ io-gather  │──── reads pty
                    │  (parse)   │   │  (POSIX)   │
                    └────────────┘   └────────────┘
```

Only thread names verified in the table above and channel names verified in the
next section appear in this diagram.

### Why the read path is two threads

On POSIX, `ReadThread` is split into a gather stage and a parse stage. The
gather thread owns all fd monitoring, including the quit fd, and fills a fixed
ring buffer. The parse stage _is_ the `io-reader` thread, calling
`Termio.processOutput` one batch at a time (`src/termio/Exec.zig:1480-1494`).
Every constant here carries a comment explaining its value
(`src/termio/Exec.zig:1304-1356`):

- **`buffer_count = 4`** — gather may run at most 4 batches ahead of parse and
  then blocks, which applies backpressure to the child process through the
  kernel's pty queue.
- **`buffer_capacity = 64 * 1024`** — a batch is also how much work parse does
  per lock acquisition, so this bounds gather latency and lock hold time
  together.
- **`bridge_threshold = 1024`**, **`bridge_spin_max = 16`**,
  **`bridge_poll_timeout_ms = 1`**, **`gather_budget_ns = 3ms`** — these let
  gather spin briefly rather than sleep across the gaps in a saturated stream's
  kernel queue refills.

Windows has no gather thread: `threadMainWindows` reads and calls
`Termio.processOutput` directly (`src/termio/Exec.zig:1788-1811`).

### What the IO writer thread does

The `//!` comment on `src/termio/Thread.zig` is blunt about it: this is the
_writer_ thread, and the reader side belongs to `Termio` itself and the
specific backend. Beyond writing bytes into the pty, the writer thread also
handles mode changes such as synchronised output and linefeed switching — the
point being to take that work off the reader thread, which is the VT parsing
hot path (`src/termio/Thread.zig:1-11`). It has three timing constants
(`src/termio/Thread.zig:27-41`):

- **`Coalesce.min_ms = 25`** — the coalescing window for messages like resize.
  The comment notes that not every message type is coalesced.
- **`sync_reset_ms = 1000`** — how long before synchronised output is reset by
  force, for a running program that never resets the flag itself.
- **`selection_scroll_ms = 15`** — the interval between moves while scrolling a
  selection.

The thread body is `threadMain_`: on Darwin it names itself `io` with
`pthread_setname_np`, sets crash metadata, takes the mailbox (the `switch` has
only a `.spsc` arm; the other is commented out), installs two asyncs — the
mailbox wakeup and stop — and then runs `loop.run(.until_done)`
(`src/termio/Thread.zig:237-280`).

### The renderer thread's timers

The renderer thread has two constants: `DRAW_INTERVAL = 8` (the comment says
120 FPS) and `CURSOR_BLINK_INTERVAL = 600` (`src/renderer/Thread.zig:21-22`).
Inside it runs a libxev event loop. `threadMain_` names itself `renderer` with
`pthread_setname_np` on Darwin, sets crash metadata and the thread QoS,
installs three asyncs — `wakeup`, `stop` and `draw_now` — notifies once so a
frame renders immediately, starts the cursor blink timer and the draw timer,
and finally runs `loop.run(.until_done)` (`src/renderer/Thread.zig:224-278`).

### The GTK exception

`drawFrame` does not draw when the surface is not visible; when the renderer
does its own vsync it only draws if `now` is true; and when
`must_draw_from_app_thread` is `true` it does not draw at all, pushing a
`redraw_surface` onto the app mailbox instead (`src/renderer/Thread.zig:527-544`).
That constant is read off the same-named declaration on `apprt.App` and
defaults to `false` (`src/renderer/Thread.zig:24-32`); the GTK side declares it
`true`, and its comment gives the reason: GTK's `GLArea` does not support
drawing from another thread (`src/apprt/gtk/App.zig:21-24`).

## The mailboxes

Three of the four channels own a real queue, all of them the same
`BlockingQueue` (`src/datastruct/blocking_queue.zig:29`, re-exported by
`src/datastruct/main.zig:10`) with a capacity hardcoded to 64. The fourth — the
surface mailbox — has no queue of its own. `BlockingQueue`'s `//!` and doc
comments state the tradeoffs: fixed size, no blocking pop (an external event
loop does the notifying), and a one-shot drain
(`src/datastruct/blocking_queue.zig:1-27`).

- **app mailbox** — `BlockingQueue(App.Message, 64)`. After `push` it calls
  `self.rt_app.wakeup()` to wake the application loop (`src/App.zig:609-625`).
  The message types are `open_config`, `new_window`, `close`, `quit`,
  `surface_message` and `redraw_surface` (`src/App.zig:569-606`), and
  `App.drainMailbox` empties the queue on the main thread. A `quit` short
  circuits immediately, deferring the remaining messages to the next tick
  (`src/App.zig:265-288`).
- **surface mailbox** — `apprt.surface.Mailbox` is not an independent queue at
  all. Its `push` wraps the message in an `App.Message.surface_message` and
  posts that to the app mailbox; the comment explains that surface messages are
  in fact implemented on the app thread (`src/apprt/surface.zig:135-155`). The
  message types are in the union starting at `src/apprt/surface.zig:14`.
- **renderer mailbox** — `BlockingQueue(rendererpkg.Message, 64)`, with a
  comment saying the capacity is hardcoded for now
  (`src/renderer/Thread.zig:34-37`). Its members include `crash`, `focus`,
  `visible`, `reset_cursor_blink`, `font_grid`, `resize`, `change_config`,
  `search_viewport_matches`, `search_selected_match`, `inspector` and
  `macos_display_id` (`src/renderer/message.zig:10-68`). Wakeup and stop are
  separate `xev.Async`es: `wakeup` can force a render safely from any thread,
  and `stop` halts the renderer on the next turn of the loop
  (`src/renderer/Thread.zig:47-54`).
- **termio mailbox** — `termio.Mailbox` is a union with, today, only the `spsc`
  variant: a `BlockingQueue(termio.Message, 64)` plus an `xev.Async` wakeup
  (`src/termio/mailbox.zig:11-45`). `Surface.init` builds it with `initSPSC`
  (`src/Surface.zig:674`). Its behaviour on a full queue is written down
  explicitly: try `.instant` first, and on failure wake the writer thread,
  temporarily release the render state lock, and retry with `.forever`. If that
  still returns 0, the message is dropped (`src/termio/mailbox.zig:63-98`).

The four channels together:

| Channel          | Type                                  | Consumer        | Woken by           |
| ---------------- | ------------------------------------- | --------------- | ------------------ |
| app mailbox      | `BlockingQueue(App.Message, 64)`      | main thread     | `rt_app.wakeup()`  |
| surface mailbox  | no queue; forwards to the app mailbox | main thread     | as above           |
| renderer mailbox | `BlockingQueue(renderer.Message, 64)` | renderer thread | `xev.Async` wakeup |
| termio mailbox   | `BlockingQueue(termio.Message, 64)`   | IO thread       | `xev.Async` wakeup |

Sources, in order: `src/App.zig:611`, `src/apprt/surface.zig:145-153`,
`src/renderer/Thread.zig:37`, `src/termio/mailbox.zig:15`. On top of these, the
renderer thread has a bare wakeup channel that bypasses any queue,
`renderer_wakeup`, which `Termio` notifies directly every time it processes
output (`src/termio/stream_handler.zig:99-101`).

`Termio` holds three outbound routes at once — `renderer_state`,
`renderer_wakeup`, `renderer_mailbox` and `surface_mailbox`
(`src/termio/Termio.zig:46-62`) — all injected in one go by `Surface.init`
(`src/Surface.zig:677-687`).

## apprt actions: the core's one-way channel back to the apprt

- `Target` is `union(Key){ app, surface: *CoreSurface }`, with a C ABI mirror
  `Target.C` / `CValue` and a `cval()` conversion. The comment says it must be
  kept in sync with `ghostty_target_s` (`src/apprt/action.zig:16-52`).
- `Action`'s doc comment is clear about what it is: a **one-way** message sent
  to the application runtime asking it to do something. The important part is
  that actions are generally **optional** for an apprt to implement — anything
  required is called directly as a function on the runtime struct, where not
  implementing it is a compile error (`src/apprt/action.zig:54-62`).
- On macOS they arrive through the `action_cb` callback
  (`macos/Sources/Ghostty/Ghostty.App.swift:62`).
- A concrete example: during creation, `Surface.init` reports `.cell_size` and
  `.size_limit` through `rt_app.performAction` (`src/Surface.zig:693-710`).

How each apprt consumes these actions is in
[`../platform-and-config.md`](../platform-and-config.md).

## The data flow: a keypress in, a pixel out

### Inbound: key to pty

Taking the macOS path as the example:

1. `ghostty_surface_key` receives the raw key event and calls
   `surface.app.keyEvent` (`src/apprt/embedded.zig:1785-1796`).
2. `embedded.App.keyEvent` converts the C event into an `input.KeyEvent`,
   dispatches it by target to either `CoreApp.keyEvent` or
   `core_surface.keyCallback`, and folds the `InputEffect` down to a bool
   (`src/apprt/embedded.zig:184-210`).
3. At the app level: `App.keyEvent` ignores release events and looks the key up
   directly in the top-level keybinding set (no sequences). When unfocused it
   handles only global bindings, and global bindings go through
   `performAllChainedAction` (`src/App.zig:360-400`).
4. At the surface level: `Surface.keyCallback` (`src/Surface.zig:2674`) remaps
   the key first, then tries the keybindings via `maybeHandleBinding`
   (`src/Surface.zig:2719`).
5. If no binding consumed it, `encodeKey` encodes it
   (`src/Surface.zig:2822-2825`), and the result becomes `write_small`,
   `write_stable` or `write_alloc` depending on whether it is small, stable or
   allocated, and goes to `queueIo`. If the child process has already exited,
   the surface is closed and `.closed` is returned instead
   (`src/Surface.zig:2826-2839`).
6. `Surface.queueIo` is the single exit for every message headed to the IO
   thread. Read-only mode drops three kinds of write message here, and the last
   thing it does is call `self.io.queueMessage` (`src/Surface.zig:867-888`).
7. `Termio.queueMessage` enqueues and notifies. When `MutexState` is `.locked`
   it hands `renderer_state.mutex` to the mailbox so that a full queue can be
   retried with the lock temporarily released
   (`src/termio/Termio.zig:397-407`).
8. The IO thread's `drainMailbox` (`src/termio/Thread.zig:290`) takes the
   messages out and turns the three write requests into `io.queueWrite`
   (`src/termio/Thread.zig:342-359`) → `Termio.queueWrite`
   (`src/termio/Termio.zig:416-423`) → the backend's `Exec.queueWrite`, which
   writes to the pty (`src/termio/Exec.zig:403`).
9. Afterwards: for a non-modifier key, and while still holding the lock, the
   selection is cleared and the view scrolled to the bottom according to
   configuration, and `queueRender` is called (`src/Surface.zig:2848-2861`).

### Outbound: pty to screen

1. The gather thread polls and reads the pty, filling one batch of the ring
   buffer (`src/termio/Exec.zig:1525`).
2. The parse stage takes a batch, obtains the slice outside the lock, and calls
   `io.processOutput(batch)` (`src/termio/Exec.zig:1480-1494`).
3. `Termio.processOutput` takes `renderer_state.mutex` — with the ordinary
   `lockUncancelable` / `unlock` — and calls `processOutputLocked`
   (`src/termio/Termio.zig:647-653`).
4. `processOutputLocked` calls `queueRender()` first
   (`src/termio/Termio.zig:658`, which is just `renderer_wakeup.notify()`; see
   `src/termio/stream_handler.zig:99-101`), then pushes a `reset_cursor_blink`
   throttled to 500ms, then feeds `terminal_stream.nextSlice(buf)` to update
   the terminal state (`src/termio/Termio.zig:695`). With an inspector attached
   it degrades to a byte-at-a-time slow path
   (`src/termio/Termio.zig:681-693`). If parsing produced any messages for the
   writer thread, it finishes with `mailbox.notify()`
   (`src/termio/Termio.zig:698-703`).
5. Back in the parse loop, `yieldToDemand` gives the lock up at every batch
   boundary (`src/termio/Exec.zig:1515-1517`).
6. The renderer thread is woken by `wakeup`: `wakeupCallback` drains the
   mailbox, then calls `renderCallback` immediately, then schedules scrollback
   compression (`src/renderer/Thread.zig:546-569`).
7. `renderCallback` disarms straight away when not visible; otherwise it calls
   `Renderer.updateFrame` and then `drawFrame(false)`
   (`src/renderer/Thread.zig:633-661`). `updateFrame` is defined at
   `src/renderer/generic.zig:1144`, wraps its snapshot critical section in
   `lockDemand` / `unlockDemand` (`src/renderer/generic.zig:1193-1194`), and
   skips the frame outright in `synchronized_output` mode
   (`src/renderer/generic.zig:1197-1200`).
8. `drawFrame` actually submits the draw — except on GTK, where it goes back
   round to the main thread through the app mailbox
   (`src/renderer/Thread.zig:527-544`).

What happens to a snapshot after that — how it becomes triangles and glyphs —
is in [`../rendering-and-font.md`](../rendering-and-font.md).

### The picture

```text
keyboard ─▶ apprt ─▶ Surface.keyCallback ─▶ queueIo ─▶ termio mailbox
                                                            │
                                                            ▼
                                                     io thread ─▶ pty ─▶ child

child ─▶ pty ─▶ io-gather ─▶ io-reader (parse)
                                   │
                                   │ holding renderer_state.mutex
                                   ▼
                            Terminal state updated
                                   │ renderer_wakeup.notify()
                                   ▼
                            renderer thread ─▶ updateFrame ─▶ drawFrame ─▶ GPU
```

## Shared state and the lock

`renderer.State`'s comment is explicit: the `mutex` protects the _values_ of
the members (`terminal`, `inspector`, `preedit`, `mouse`), and the State struct
itself is not thread safe (`src/renderer/State.zig:13-34`).

The problem is lock fairness. `lockDemand`'s comment spells it out: neither
`std.Thread.Mutex` nor os_unfair_lock is fair, and a running thread that
unlocks and immediately relocks wins every time against a waiter that has to be
woken and scheduled first. Under continuous pty output the IO parse thread is
exactly such a hot loop, so without an extra signal the renderer starves
indefinitely (`src/renderer/State.zig:54-66`).

The answer is three functions and two atomic counters:

| Member / function    | Location                        | What it does                                                                              |
| -------------------- | ------------------------------- | ----------------------------------------------------------------------------------------- |
| `demand`             | `src/renderer/State.zig:36-40`  | How many threads are waiting on the lock via `lockDemand`                                 |
| `handoff_gen`        | `src/renderer/State.zig:42-45`  | A handoff generation counter, paired with futex wakeups                                   |
| `handoff_timeout_ns` | `src/renderer/State.zig:47-52`  | 1ms; bounds how long the parse thread may pause                                           |
| `lockDemand`         | `src/renderer/State.zig:67-72`  | Increments `demand` before locking and decrements after                                   |
| `unlockDemand`       | `src/renderer/State.zig:76-80`  | After unlocking, increments `handoff_gen` and calls `futexWake`                           |
| `yieldToDemand`      | `src/renderer/State.zig:91-105` | While not holding the lock, if there is demand, futex-wait for the handoff or the timeout |

Only two places in the whole tree use this machinery: the renderer's frame
snapshot, with `lockDemand` / `unlockDemand`
(`src/renderer/generic.zig:1193-1194`), and the read thread at batch
boundaries, with `yieldToDemand` (`src/termio/Exec.zig:1517` and
`src/termio/Exec.zig:1810`).

Note that `Termio.processOutput` uses the ordinary `mutex.lockUncancelable` /
`unlock` (`src/termio/Termio.zig:650-651`), so the yield happens **between**
batches rather than within one. Put another way, `lockDemand` and
`yieldToDemand` are one agreement with two halves: the renderer's `lockDemand`
only gets the lock promptly because the parse thread deliberately steps aside
at batch boundaries. Any new code on this hot path has to keep the same
agreement.

How the search thread uses this lock is not asserted here (not verified: the
locking in `src/terminal/search/Thread.zig` has not been read; to verify, read
that file for every access to `renderer_state` or to the terminal pointer).

## Two libghosttys: the naming trap

There are two things in this repository with libghostty in the name. They share
neither headers nor a build path.

**libghostty-vt** is a standalone, pure terminal library. Its Zig module entry
point is `src/lib_vt.zig` (517 lines), whose `//!` comment describes it as the
public API of ghostty-vt and warns that the API is not guaranteed stable — the
functionality is stable, but functions and types may change without notice
(`src/lib_vt.zig:1-9`). Adding a function to the C API is a four-step process,
written down at `src/terminal/c/AGENTS.md:6-13`: define it in
`src/terminal/c/<module>.zig`, re-export it with `pub const` from
`src/terminal/c/main.zig`, add a `ghostty_`-prefixed `@export` in
`src/lib_vt.zig`, and finally declare it in a header under
`include/ghostty/vt/`. The build option field is `emit_lib_vt`
(`src/build/Config.zig:55`), and the matching `b.option` name is `emit-lib-vt`
(`src/build/Config.zig:82`).

**GhosttyLib** is the macOS glue library. `build.zig`'s comment says it in as
many words: "This is NOT libghostty (even though its named that for historical
reasons). It is just the glue between Ghostty GUI on macOS and the full Ghostty
GUI core." Its products are `ghostty-internal.dll` /
`ghostty-internal-static.lib` / `ghostty-internal.so` / `ghostty-internal.a`
(`build.zig:186-207`), and its header is `include/ghostty.h` (1235 lines).

The two are mutually exclusive in the build: when `app_runtime != .none` an
executable is produced, and only otherwise — and only when `!emit_lib_vt` — is
GhosttyLib built (`build.zig:179-207`). Wherever another document says
"libghostty", it means this section.

## The matrix of build products

| Product                           | Built when                                                                                    | Source                                              |
| --------------------------------- | --------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| the `ghostty` executable          | `emit_exe` (defaults to `!emit_lib_vt`) and `app_runtime != .none`                            | `src/build/Config.zig:405-409`, `build.zig:180-185` |
| GhosttyLib (`ghostty-internal.*`) | `app_runtime == .none` and `!emit_lib_vt`                                                     | `build.zig:186-207`                                 |
| Ghostty xcframework + macOS app   | `!emit_lib_vt`, a Darwin target, and `emit_xcframework or emit_macos_app`                     | `build.zig:209-244`, `src/build/Config.zig:510-514` |
| libghostty-vt shared / wasm       | always; a wasm target takes `initWasm`, otherwise `initShared`                                | `build.zig:119-133`                                 |
| libghostty-vt static              | always; outside a dependency build it is renamed `libghostty-vt.a` or `ghostty-vt-static.lib` | `build.zig:135-156`                                 |
| libghostty-vt xcframework         | `emit_lib_vt` and `emit_xcframework`, building Darwin on Darwin                               | `build.zig:158-174`                                 |

The steps `build.zig` declares are `run`, `run-valgrind`, `test`,
`test-lib-vt`, `test-valgrind`, `update-translations`, `dist` and `distcheck`
(`build.zig:62-79`, `build.zig:111-117`). For the commands themselves, always
see [`preview-manual.md`](preview-manual.md).

## Global state and logging

What `global.init` sets up is **process-level** state. The comment is explicit
about why it is a global at all: the C API needs access to it, and no other Zig
code should ever touch it directly (`src/main_ghostty.zig:27-30`). Both startup
paths (`src/main_ghostty.zig:31` and `src/main_c.zig:110-135`) go through the
same `global.init` and differ only in the initialisation source they pass
(`.main` versus `.c`).

The log destination is decided by the packed struct `GlobalState.Logging`.
`stderr` defaults to `build_config.app_runtime != .none` — that is, stderr
logging is off by default in the library form — and `macos` defaults to on
under Darwin (`src/global.zig:394-402`). At runtime the `GHOSTTY_LOG`
environment variable overrides it, parsed by `cli.args.parsePackedStruct`
(`src/global.zig:148-155`).

The log _level_, on the other hand, has nothing to do with `GHOSTTY_LOG`:
`std_options.log_level` is `.debug` in Debug builds and `.info` otherwise, and
the comment explains that it is not lowered so that expensive debug logging is
optimised out of non-debug builds (`src/main_ghostty.zig:201-212`). On Darwin
`logFn` goes to the unified log, and the comment hands you the predicate to
read it with: `subsystem=="com.mitchellh.ghostty"`
(`src/main_ghostty.zig:118-132`). That bundle ID is hardcoded at
`src/build_config.zig:58`.

## Traps and things to watch for

1. "libghostty" means two things; read the section above before assuming which
   (`build.zig:186-207`).
2. The surface mailbox is not a queue on another thread. `push` delivers to the
   app thread (`src/apprt/surface.zig:145-153`).
3. On macOS the process entry point is Swift's `main.swift`, not
   `src/main_ghostty.zig:26`, and CLI actions work because of
   `ghostty_cli_try_action()` (`macos/Sources/App/main.swift:31`).
4. On POSIX the read path is two threads (`io-gather` plus `io-reader`);
   changing the read path means considering both
   (`src/termio/Exec.zig:1461-1474`).
5. Before holding `renderer_state.mutex` on a hot path, understand the
   `lockDemand` semantics: releasing with a plain `mutex.unlock` is safe for
   the data, but it leaves a caller parked in `yieldToDemand` waiting out the
   full 1ms timeout (`src/renderer/State.zig:54-59`).
6. `Termio.queueWrite`'s doc comment says it: when `termio.Thread` is in use it
   may only be called on the mailbox thread, and anywhere else you want
   `queueMessage` instead (`src/termio/Termio.zig:409-423`).
7. All three real queues (app / renderer / termio) have a capacity of 64. When
   the termio mailbox is full it wakes the writer thread, releases the lock
   temporarily and retries, and only drops the message if that still fails
   (`src/termio/mailbox.zig:69-95`). What the other two do when full is not
   asserted here (not verified: `BlockingQueue.push` has not been read line by
   line for its return semantics under each `Timeout`; to verify, read the
   `push` implementation in `src/datastruct/blocking_queue.zig`).
8. `GHOSTTY_LOG` has its stderr output forcibly disabled while a CLI action
   runs (`src/global.zig:141`), and it is not leaked to child processes
   (`src/Surface.zig:648-649`). `Logging`'s own defaults depend on
   `app_runtime` (`src/global.zig:395-401`).
9. The renderer thread does not necessarily draw. Before changing the draw
   path, check `apprt.App.must_draw_from_app_thread`: when it is `true`,
   `drawFrame` only pushes a message onto the app mailbox and the real drawing
   happens on the main thread (`src/renderer/Thread.zig:535-540`).
10. In `Surface.init`, the `renderer_state` mutex is a separate `alloc.create`
    allocation rather than an inline field of `Surface`
    (`src/Surface.zig:567-570`) — worth remembering if you copy a `Surface` or
    move its address.

## Further reading

- The Repository Map and Architecture at a Glance sections of the root
  [`AGENTS.md`](../../AGENTS.md) (`CLAUDE.md` is a symlink to it).
- [`HACKING.md`](../../HACKING.md): environment dependencies, logging and lint.
- [`src/terminal/c/AGENTS.md`](../../src/terminal/c/AGENTS.md),
  [`macos/AGENTS.md`](../../macos/AGENTS.md),
  [`src/inspector/AGENTS.md`](../../src/inspector/AGENTS.md).
- The other four documents, currently Chinese only:
  [`terminal-core.md`](../terminal-core.md),
  [`rendering-and-font.md`](../rendering-and-font.md),
  [`platform-and-config.md`](../platform-and-config.md). The fifth,
  [`preview-manual.md`](preview-manual.md), is translated.
- The writing rules are in [`_conventions.md`](../_conventions.md) (Chinese),
  and the English terminology in [`GLOSSARY.md`](GLOSSARY.md).
