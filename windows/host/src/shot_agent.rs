//! The host's half of the agent screenshot tools.
//!
//! Specification: `dev-docs/poltergeist/screenshot.md` §10.1. The core
//! checks permission, validates paths and annotations, and performs one
//! action with a JSON request and an out cell; this answers it. What the
//! request means -- which rectangle, what is painted black, what the answer
//! looks like -- is `polter_shots::agent`, tested off Windows. This file is
//! the screen, the files and the one thread a long screenshot needs.
//!
//! **Nothing here touches the clipboard or the paste cache** (`shots.rs`'s
//! `remember`): the clipboard is the user's, and an agent that wants its
//! picture reads the path it is given.
//!
//! **A shielded terminal is painted black before anything else happens to
//! the picture** -- before the mosaics are computed, before a long
//! screenshot's frames are compared. The original pixels of such a pane
//! never reach a `Composed`, so they cannot reach a file.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use polter_shots::agent::{self, Caller, DisplayInfo, Raw, Refusal, Request, Stopped, Target, WindowInfo};
use polter_shots::annot::{self, By, Display, Item, Meta, Shape, Source, Terminal, Tile};
use polter_shots::editor::Window;
use polter_shots::geom::Rect;
use polter_shots::pixels::{self, Composed, Frozen, TILE_HEIGHT, TILE_OVERLAP};
use polter_shots::stitch::{Step, Stitcher};
use windows::Win32::Foundation::{HWND, LPARAM, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{BitBlt, EnumDisplayMonitors, GetDC, ReleaseDC, CAPTUREBLT, SRCCOPY};
use windows::Win32::System::SystemInformation::GetSystemTime;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_WHEEL, MOUSEINPUT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetCursorPos, GetWindowRect, IsIconic, IsWindowVisible, PostMessageW, SetCursorPos, WM_APP,
};

use crate::ffi;
use crate::plogf;
use crate::shot::{self, Canvas, Gdi};

/// Posted to the screenshot control window when a long screenshot's thread
/// has finished and its answer is waiting. `WM_APP + 35`, private to that
/// window's class.
pub const WM_AGENT_DONE: u32 = WM_APP + 35;

/// One long screenshot at a time: it moves the pointer and turns the wheel,
/// and two of them would be turning it for each other.
static LONG_BUSY: AtomicBool = AtomicBool::new(false);

/// Answers computed off the window thread, waiting to be handed to the core
/// on it: `(token, result, json)`.
static FINISHED: Mutex<Vec<(u64, i32, String)>> = Mutex::new(Vec::new());

/// Write `json` into the core's buffer as the answer.
///
/// **Never half an answer.** One that does not fit is replaced by a refusal
/// saying so -- which always fits -- rather than cut where the room ran out.
unsafe fn answer(out: *mut ffi::ScreenshotOut, result: i32, json: &str) {
    unsafe {
        let cell = &mut *out;
        let (result, json) = if json.len() <= cell.cap {
            (result, json.to_string())
        } else {
            let r = Refusal::new(
                "HostFault",
                format!("The host's answer was {} bytes and the buffer holds {}.", json.len(), cell.cap),
            );
            (ffi::SCREENSHOT_REFUSED, r.json())
        };
        let n = json.len().min(cell.cap);
        std::ptr::copy_nonoverlapping(json.as_ptr(), cell.buf, n);
        cell.len = n;
        cell.result = result;
    }
}

/// The displays, primary first, and the top-level windows front to back --
/// the same windows the overlay lets a person pick.
fn screen() -> (Vec<DisplayInfo>, Vec<WindowInfo>) {
    let mut found: Vec<(Rect, u32)> = Vec::new();
    let mut wins: Vec<Window> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(shot::monitor_cb), LPARAM(&mut found as *mut _ as isize));
        let _ = EnumWindows(Some(shot::window_cb), LPARAM(&mut wins as *mut _ as isize));
    }
    // The primary display is the one whose corner is the virtual screen's
    // origin: that is what "primary" means to the window system.
    let displays = agent::ordered(
        found
            .into_iter()
            .map(|(rect, dpi)| DisplayInfo { rect, scale: f64::from(dpi.max(96)) / 96.0, primary: rect.x == 0 && rect.y == 0 })
            .collect(),
    );
    let windows = wins
        .into_iter()
        .map(|w| {
            let (app, title, pid) = shot::window_names(w.id);
            WindowInfo { id: w.id, app, title, pid, rect: w.rect }
        })
        .collect();
    (displays, windows)
}

/// Where the shielded panes are on the screen right now: every pane whose
/// terminal is shielded and whose window is showing. **Covered or not** --
/// see the module documentation and `agent::redactions`.
fn shielded_panes() -> Vec<Rect> {
    crate::tabs::shielded_pane_hwnds()
        .into_iter()
        .filter_map(|h| {
            let hwnd = HWND(h as *mut std::ffi::c_void);
            unsafe {
                // A pane of a tab that is not the active one is hidden; a
                // minimised frame reports its panes off screen.
                if !IsWindowVisible(hwnd).as_bool() {
                    return None;
                }
                let root = windows::Win32::UI::WindowsAndMessaging::GetAncestor(
                    hwnd,
                    windows::Win32::UI::WindowsAndMessaging::GA_ROOT,
                );
                if IsIconic(root).as_bool() {
                    return None;
                }
                let mut r = RECT::default();
                GetWindowRect(hwnd, &mut r).ok()?;
                let rect = Rect::from_ltrb(r.left, r.top, r.right, r.bottom);
                (!rect.is_empty()).then_some(rect)
            }
        })
        .collect()
}

/// The frame window of the terminal an action was addressed to.
fn terminal_window(surface: Option<ffi::Surface>) -> Option<u64> {
    crate::tabs::frame_of_surface(surface?).map(|h| h.0 as usize as u64)
}

fn terminal_of(caller: &Caller) -> Option<Terminal> {
    let (id, cwd) = caller.terminal.clone()?;
    let git = cwd.as_deref().and_then(shot::git_of);
    Some(Terminal { id, cwd, git })
}

fn write_failed(what: &str, e: impl std::fmt::Display) -> Refusal {
    Refusal::new("WriteFailed", format!("{what}: {e}."))
}

/// Draw the annotations that are not mosaics onto a composed image.
fn draw_on(composed: &mut Composed, items: &[Item], scale: f64) -> bool {
    let mut drawn = false;
    composed.draw(|bits, rect| unsafe {
        let screen = GetDC(None);
        let canvas = Canvas::new(screen, rect);
        ReleaseDC(None, screen);
        let Some(canvas) = canvas else { return };
        canvas.bits().copy_from_slice(bits);
        let others = items.iter().enumerate().filter(|(_, it)| !matches!(it.shape, Shape::Mosaic(_)));
        shot::draw_items(&canvas, others, scale, None);
        bits.copy_from_slice(canvas.bits());
        drawn = true;
    });
    drawn
}

/// Save `png` as a new shot in the screenshots directory. The path, and the
/// local time and UTC offset its name was made from.
fn save(png: &[u8]) -> Result<(PathBuf, polter_shots::name::Stamp, i32), Refusal> {
    let dir = crate::shots::dir().ok_or_else(|| {
        Refusal::new("WriteFailed", "There is no screenshots directory: neither screenshot-directory nor LOCALAPPDATA is set.")
    })?;
    let taken = std::cell::Cell::new(shot::now());
    let utc = shot::stamp(unsafe { GetSystemTime() });
    let clock = || {
        taken.set(shot::now());
        taken.get()
    };
    let pause = || std::thread::sleep(std::time::Duration::from_millis(1));
    let path = polter_shots::store::write_new(&dir, clock, pause, png)
        .map_err(|e| write_failed(&format!("The picture could not be written to {}", dir.display()), e))?;
    let taken = taken.get();
    Ok((path, taken, polter_shots::name::utc_offset_minutes(&taken, &utc)))
}

fn file_name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()
}

/// What a capture is of, for the sidecar: a window when the target was one.
fn source_of(target: Target, windows: &[WindowInfo], terminal_window: Option<u64>, rect: Rect) -> Source {
    let id = match target {
        Target::Window { id } => Some(id),
        Target::Terminal => terminal_window,
        _ => None,
    };
    match id.and_then(|id| windows.iter().find(|w| w.id == id)) {
        Some(w) => Source::Window {
            app: w.app.clone(),
            title: w.title.clone(),
            pid: w.pid,
            window_rect: Some(w.rect),
            selection_rect: rect,
        },
        None => Source::Region { selection_rect: rect },
    }
}

fn source_names(source: &Source) -> (Option<String>, Option<String>) {
    match source {
        Source::Window { app, title, .. } => (app.clone(), title.clone()),
        Source::Region { .. } => (None, None),
    }
}

/// `capture`: one display's picture, cut to the target, shielded panes
/// black, annotations on; a new file and its sidecar.
fn capture(
    target: Target,
    raw: &[Raw],
    caller: &Caller,
    surface: Option<ffi::Surface>,
) -> Result<(String, String), Refusal> {
    let (displays, windows) = screen();
    let terminal_window = terminal_window(surface);
    let (index, rect) = agent::resolve(target, &displays, &windows, terminal_window)?;
    let display = displays[index];
    let frozen = unsafe {
        let dc = GetDC(None);
        let frozen = shot::grab(dc, display.rect);
        ReleaseDC(None, dc);
        frozen
    }
    .ok_or_else(|| Refusal::new("CaptureFailed", format!("Display {index} could not be read.")))?;

    let panes = shielded_panes();
    let items = agent::items(raw, rect.origin(), display.scale, &Gdi)?;
    let mut composed = Composed::new(&frozen, rect, &items, display.scale, &panes)
        .ok_or_else(|| Refusal::new("BadRegion", "The target has no area on that display."))?;
    if !draw_on(&mut composed, &items, display.scale) {
        return Err(Refusal::new("CaptureFailed", "The annotations could not be drawn."));
    }
    let png = composed.png().ok_or_else(|| Refusal::new("CaptureFailed", "The picture could not be encoded."))?;
    let (path, taken, offset) = save(&png)?;

    let source = source_of(target, &windows, terminal_window, rect);
    let (app, title) = source_names(&source);
    let image = file_name(&path);
    let meta = Meta {
        previous: path.parent().and_then(|d| shot::previous_in(d, &image, app.as_deref(), title.as_deref())),
        image,
        taken,
        utc_offset_minutes: offset,
        size: composed.size(),
        scale: display.scale,
        by: By::Agent { terminal: caller.agent_terminal.clone() },
        display: Some(Display { index, size: (display.rect.w as u32, display.rect.h as u32), scale: display.scale }),
        appearance: Some(shot::appearance()),
        source,
        terminal: terminal_of(caller),
        tiles: Vec::new(),
        redacted: agent::redactions(&panes, rect),
    };
    let json = path.with_extension("json");
    std::fs::write(&json, annot::sidecar(&meta, &annot::exported(&items, rect, display.scale)))
        .map_err(|e| write_failed(&format!("The sidecar {} could not be written", json.display()), e))?;
    Ok((
        agent::capture_json(&path.to_string_lossy(), &json.to_string_lossy(), meta.size),
        format!("{} ({}x{}, {} redacted)", path.display(), meta.size.0, meta.size.1, meta.redacted.len()),
    ))
}

/// `annotate`: a saved shot with annotations added, as a **new** file. The
/// original is read and never written.
fn annotate(original: &str, raw: &[Raw], caller: &Caller) -> Result<(String, String), Refusal> {
    let original = Path::new(original);
    let bytes = std::fs::read(original)
        .map_err(|e| Refusal::new("BadImage", format!("{} could not be read: {e}.", original.display())))?;
    let (image, _) = polter_shots::encode::decode(&bytes)
        .ok_or_else(|| Refusal::new("BadImage", format!("{} is not a PNG this host can read.", original.display())))?;
    let rect = Rect::new(0, 0, image.width as i32, image.height as i32);
    let old_sidecar = std::fs::read_to_string(original.with_extension("json")).ok();
    // Sizes are in points: the scale the picture was taken at turns them
    // into its pixels. A picture with no record of one is taken as 100%.
    let scale = old_sidecar
        .as_deref()
        .and_then(|t| serde_json::from_str::<serde_json::Value>(t).ok())
        .and_then(|v| v["scale"].as_f64())
        .filter(|s| s.is_finite() && *s > 0.0)
        .unwrap_or(1.0);
    let frozen = Frozen::new(rect, image.to_bgrx())
        .ok_or_else(|| Refusal::new("BadImage", "The picture has no pixels."))?;
    let items = agent::items(raw, rect.origin(), scale, &Gdi)?;
    let mut composed = Composed::new(&frozen, rect, &items, scale, &[])
        .ok_or_else(|| Refusal::new("BadImage", "The picture has no area."))?;
    if !draw_on(&mut composed, &items, scale) {
        return Err(Refusal::new("CaptureFailed", "The annotations could not be drawn."));
    }
    let png = composed.png().ok_or_else(|| Refusal::new("CaptureFailed", "The picture could not be encoded."))?;
    let (path, taken, offset) = save(&png)?;
    let original_name = file_name(original);
    let meta = Meta {
        image: file_name(&path),
        taken,
        utc_offset_minutes: offset,
        size: composed.size(),
        scale,
        by: By::Agent { terminal: caller.agent_terminal.clone() },
        display: None,
        appearance: None,
        source: Source::Region { selection_rect: rect },
        terminal: terminal_of(caller),
        previous: Some(original_name.clone()),
        tiles: Vec::new(),
        redacted: Vec::new(),
    };
    let json = path.with_extension("json");
    let text = agent::annotated_sidecar(old_sidecar.as_deref(), &original_name, &meta, &annot::exported(&items, rect, scale));
    std::fs::write(&json, text)
        .map_err(|e| write_failed(&format!("The sidecar {} could not be written", json.display()), e))?;
    Ok((
        agent::capture_json(&path.to_string_lossy(), &json.to_string_lossy(), meta.size),
        format!("{} from {}", path.display(), original_name),
    ))
}

/// One frame of `rect` as it is on the screen now, with the shielded panes
/// black. Any thread.
fn frame_of(rect: Rect, panes: &[Rect]) -> Option<Vec<u8>> {
    unsafe {
        let screen = GetDC(None);
        let frame = Canvas::new(screen, rect).and_then(|canvas| {
            BitBlt(canvas.dc, 0, 0, rect.w, rect.h, Some(screen), rect.x, rect.y, SRCCOPY | CAPTUREBLT)
                .ok()
                .map(|()| canvas.bits().to_vec())
        });
        ReleaseDC(None, screen);
        let mut frame = frame?;
        // Before the frame is compared with anything: a frame is where the
        // pane's pixels would first leave this function.
        for pane in panes {
            pixels::black_out(&mut frame, rect, *pane);
        }
        Some(frame)
    }
}

/// Turn the wheel one notch down at the pointer.
pub(crate) fn wheel_down() {
    let input = INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT { dx: 0, dy: 0, mouseData: (-120i32) as u32, dwFlags: MOUSEEVENTF_WHEEL, time: 0, dwExtraInfo: 0 },
        },
    };
    unsafe { SendInput(&[input], std::mem::size_of::<INPUT>() as i32) };
}

/// Everything a long screenshot's thread needs, gathered on the window
/// thread before it starts.
struct LongJob {
    token: u64,
    rect: Rect,
    display: usize,
    display_info: DisplayInfo,
    pages: u32,
    panes: Vec<Rect>,
    source: Source,
    caller: Caller,
}

/// How many captures a notch is given to hold still, and how far apart.
const STEADY_TRIES: u32 = 10;
const STEADY_GAP_MS: u64 = 60;

/// Capture the region until two captures in a row are the same, and say
/// what that frame did to the picture. `None` when the screen could not be
/// read or the region kept changing through every try.
fn steady_step(stitcher: &mut Stitcher, rect: Rect, panes: &[Rect], moving: &mut u32) -> Option<Step> {
    for _ in 0..STEADY_TRIES {
        let frame = frame_of(rect, panes)?;
        match stitcher.offer(&frame) {
            Step::Moving => {
                *moving += 1;
                std::thread::sleep(std::time::Duration::from_millis(STEADY_GAP_MS));
            }
            step => return Some(step),
        }
    }
    None
}

/// The body of a long screenshot: scroll, take frames, stitch, save.
///
/// The pointer is put in the middle of the region (the wheel goes to the
/// window under it) and put back afterwards. Each page is scrolled a notch
/// at a time, with a frame after every notch, until that page's worth of new
/// rows has come into view -- how far a notch scrolls is the application's
/// business and is not assumed.
fn run_long(job: &LongJob) -> Result<(String, String), Refusal> {
    let LongJob { rect, .. } = *job;
    let mut stitcher = Stitcher::new(rect.w as usize, rect.h as usize)
        .ok_or_else(|| Refusal::new("BadRegion", "The region has no area."))?;
    let mut moving = 0u32;
    // The first frame is taken like every other: when the region has held
    // still for two captures (screenshot.md §9.7).
    let steady = steady_step(&mut stitcher, rect, &job.panes, &mut moving).is_some();
    if !steady && !stitcher.never_steady() {
        return Err(Refusal::new("CaptureFailed", "The screen could not be read."));
    }

    let mut before = POINT::default();
    unsafe {
        let _ = GetCursorPos(&mut before);
        let _ = SetCursorPos(rect.x + rect.w / 2, rect.y + rect.h / 2);
    }
    let settle = std::time::Duration::from_millis(150);
    let (mut pages, mut stopped) = (0u32, Stopped::Pages);
    let (mut frames, mut lost) = (1u32, 0u32);
    // A region that never held still (a video, a spinner) is not scrolled:
    // nothing could be joined to it. Its first frame is the picture, and
    // the answer says why there is no more (`stopped: "moving"`).
    if !steady {
        stopped = Stopped::Moving;
    }
    'pages: for _ in 0..if steady { job.pages } else { 0 } {
        let (mut scrolled, mut still, mut blind) = (0usize, 0u32, 0u32);
        // Forty notches is far more than a page; it bounds a page that
        // never reports progress.
        for _ in 0..40 {
            if scrolled >= rect.h as usize {
                break;
            }
            wheel_down();
            std::thread::sleep(settle);
            // `None`: the region did not hold still for two captures in a
            // row within the tries allowed -- counted with the frames that
            // could not be followed.
            let step = steady_step(&mut stitcher, rect, &job.panes, &mut moving).unwrap_or(Step::Lost);
            frames += 1;
            match step {
                Step::Added(n) => {
                    scrolled += n;
                    still = 0;
                    blind = 0;
                }
                Step::Unchanged => {
                    still += 1;
                    // Three notches with nothing moving: the bottom.
                    if still >= 3 {
                        stopped = Stopped::Bottom;
                        break 'pages;
                    }
                }
                Step::Full => {
                    stopped = Stopped::Limit;
                    break 'pages;
                }
                Step::Lost => {
                    lost += 1;
                    blind += 1;
                    // The page moves in a way that cannot be followed
                    // (animation, a notch longer than the region). What was
                    // joined so far is kept and returned.
                    if blind >= 6 {
                        stopped = Stopped::Bottom;
                        break 'pages;
                    }
                }
                _ => {}
            }
        }
        pages += 1;
    }
    unsafe {
        let _ = SetCursorPos(before.x, before.y);
    }

    let (width, rows) = stitcher.finish().ok_or_else(|| Refusal::new("CaptureFailed", "No frame was taken."))?;
    let composed = Composed::from_stitched(width, rows)
        .ok_or_else(|| Refusal::new("CaptureFailed", "The frames could not be joined."))?;
    let png = composed.png().ok_or_else(|| Refusal::new("CaptureFailed", "The picture could not be encoded."))?;
    let (path, taken, offset) = save(&png)?;
    let image = file_name(&path);
    let tiles = composed.tiles(TILE_HEIGHT, TILE_OVERLAP);
    let tiles = if tiles.len() > 1 { tiles } else { Vec::new() };
    let mut entries = Vec::new();
    let mut answered = Vec::new();
    for (i, (y, height, bytes)) in tiles.iter().enumerate() {
        let name = polter_shots::name::tile(&image, i + 1);
        let tile_path = path.with_file_name(&name);
        std::fs::write(&tile_path, bytes)
            .map_err(|e| write_failed(&format!("The tile {} could not be written", tile_path.display()), e))?;
        // By file name in the answer as in the sidecar: the core refuses an
        // answer whose tile is named by a path (`agent::long_json`).
        answered.push((name.clone(), *y, *height));
        entries.push(Tile { image: name, y: *y, height: *height });
    }
    let (app, title) = source_names(&job.source);
    let meta = Meta {
        previous: path.parent().and_then(|d| shot::previous_in(d, &image, app.as_deref(), title.as_deref())),
        image,
        taken,
        utc_offset_minutes: offset,
        size: composed.size(),
        scale: job.display_info.scale,
        by: By::Agent { terminal: job.caller.agent_terminal.clone() },
        display: Some(Display {
            index: job.display,
            size: (job.display_info.rect.w as u32, job.display_info.rect.h as u32),
            scale: job.display_info.scale,
        }),
        appearance: Some(shot::appearance()),
        source: job.source.clone(),
        terminal: terminal_of(&job.caller),
        tiles: entries,
        // Where the panes were in each frame. In the joined picture the
        // black is wherever those rows ended up; this records the frame's.
        redacted: agent::redactions(&job.panes, rect),
    };
    let json = path.with_extension("json");
    std::fs::write(&json, annot::sidecar(&meta, &[]))
        .map_err(|e| write_failed(&format!("The sidecar {} could not be written", json.display()), e))?;
    Ok((
        agent::long_json(&path.to_string_lossy(), &json.to_string_lossy(), meta.size, &answered, pages, stopped),
        format!(
            "{} ({}x{}, {} page(s), stopped={stopped:?}, {frames} frame(s), {lost} dropped, {moving} held back as still moving, {} tile(s))",
            path.display(),
            meta.size.0,
            meta.size.1,
            pages,
            answered.len()
        ),
    ))
}

/// Hand the answers of finished long screenshots to the core. **On the
/// window thread**, which is the only place the core takes them: the
/// control window calls this when `WM_AGENT_DONE` arrives.
pub fn deliver_finished() {
    let done = std::mem::take(&mut *FINISHED.lock().unwrap_or_else(|e| e.into_inner()));
    let app = crate::app_handle();
    for (token, result, json) in done {
        unsafe { (crate::api().app_poltergeist_screenshot_complete)(app, token, result, json.as_ptr(), json.len()) };
        // process-wide: an agent's request is not about a terminal window
        plogf!("[shot-agent] long: answer for token {token} handed to the core (result={result}, {} bytes)", json.len());
    }
}

/// Answer one `poltergeist_screenshot` action. `true` when the out cell was
/// written.
pub fn perform(action: &ffi::Action, surface: Option<ffi::Surface>) -> bool {
    let (spec, out) = action.as_poltergeist_screenshot();
    if out.is_null() {
        // process-wide: an agent's request is not about a terminal window
        plogf!("[shot-agent] the request has no out cell; not answered");
        return false;
    }
    let request = match agent::parse(&spec) {
        Ok(r) => r,
        Err(refusal) => {
            // process-wide: an agent's request is not about a terminal window
            plogf!("[shot-agent] request not understood -> {}: {}", refusal.code, refusal.message);
            unsafe { answer(out, ffi::SCREENSHOT_REFUSED, &refusal.json()) };
            return true;
        }
    };
    let op = request.op();
    // A session of the user's own has the screen: its overlays would be in
    // the picture, and its frozen image is not the screen.
    let busy = || {
        if shot::is_active() {
            Some(Refusal::new("Busy", "The user's own screenshot is open. Try again when it is done."))
        } else if LONG_BUSY.load(Ordering::Acquire) {
            Some(Refusal::new("Busy", "Another long screenshot is still being taken. Try again shortly."))
        } else {
            None
        }
    };
    let (who, what, outcome): (String, String, Result<(String, String), Refusal>) = match request {
        Request::Directory => {
            let outcome = crate::shots::dir()
                .map(|d| (agent::directory_json(&d.to_string_lossy()), d.display().to_string()))
                .ok_or_else(|| {
                    Refusal::new("WriteFailed", "There is no screenshots directory: neither screenshot-directory nor LOCALAPPDATA is set.")
                });
            (String::new(), String::new(), outcome)
        }
        Request::Windows => {
            let (displays, windows) = screen();
            let cap = unsafe { (*out).cap };
            let json = agent::windows_json(&displays, &windows, cap);
            let summary = format!("{} display(s), {} window(s), {} bytes", displays.len(), windows.len(), json.len());
            (String::new(), String::new(), Ok((json, summary)))
        }
        Request::Capture { target, annotations, caller } => {
            let outcome = match busy() {
                Some(r) => Err(r),
                None => capture(target, &annotations, &caller, surface),
            };
            (caller.agent_terminal, format!("{target:?}, {} annotation(s)", annotations.len()), outcome)
        }
        Request::Annotate { path, annotations, caller } => {
            let outcome = annotate(&path, &annotations, &caller);
            (caller.agent_terminal, format!("{path}, {} annotation(s)", annotations.len()), outcome)
        }
        Request::Long { target, pages, caller } => {
            let who = caller.agent_terminal.clone();
            let what = format!("{target:?}, {pages} page(s)");
            let started = match busy() {
                Some(r) => Err(r),
                None => start_long(target, pages, caller, unsafe { (*out).token }),
            };
            match started {
                Ok(()) => {
                    unsafe { (*out).result = ffi::SCREENSHOT_PENDING };
                    // process-wide: an agent's request is not about a terminal window
                    plogf!("[shot-agent] long by {who}: {what} -> pending (token {})", unsafe { (*out).token });
                    return true;
                }
                Err(r) => (who, what, Err(r)),
            }
        }
    };
    match outcome {
        Ok((json, summary)) => {
            unsafe { answer(out, ffi::SCREENSHOT_DONE, &json) };
            // process-wide: an agent's request is not about a terminal window
            plogf!("[shot-agent] {op} by {who:?}: {what} -> done: {summary}");
        }
        Err(refusal) => {
            unsafe { answer(out, ffi::SCREENSHOT_REFUSED, &refusal.json()) };
            // process-wide: an agent's request is not about a terminal window
            plogf!("[shot-agent] {op} by {who:?}: {what} -> refused {}: {}", refusal.code, refusal.message);
        }
    }
    true
}

/// Begin a long screenshot on a thread of its own. The answer comes later,
/// through `FINISHED` and `deliver_finished`.
fn start_long(target: Target, pages: u32, caller: Caller, token: u64) -> Result<(), Refusal> {
    let (displays, windows) = screen();
    let (display, rect) = agent::resolve(target, &displays, &windows, None)?;
    let job = LongJob {
        token,
        rect,
        display,
        display_info: displays[display],
        pages,
        panes: shielded_panes(),
        source: source_of(target, &windows, None, rect),
        caller,
    };
    if LONG_BUSY.swap(true, Ordering::AcqRel) {
        return Err(Refusal::new("Busy", "Another long screenshot is still being taken. Try again shortly."));
    }
    let control = shot::control_window().0 as isize;
    let spawned = std::thread::Builder::new().name("polter-shot-long".into()).spawn(move || {
        crate::name_this_thread("polter-shot-long");
        let outcome = run_long(&job);
        let who = &job.caller.agent_terminal;
        let (result, json) = match &outcome {
            Ok((json, summary)) => {
                // process-wide: an agent's request is not about a terminal window
                plogf!("[shot-agent] long by {who}: {:?} -> done: {summary}", job.rect);
                (ffi::SCREENSHOT_DONE, json.clone())
            }
            Err(refusal) => {
                // process-wide: an agent's request is not about a terminal window
                plogf!("[shot-agent] long by {who}: {:?} -> refused {}: {}", job.rect, refusal.code, refusal.message);
                (ffi::SCREENSHOT_REFUSED, refusal.json())
            }
        };
        FINISHED.lock().unwrap_or_else(|e| e.into_inner()).push((job.token, result, json));
        LONG_BUSY.store(false, Ordering::Release);
        // The core takes the answer on the window thread only.
        let _ = unsafe {
            PostMessageW(Some(HWND(control as *mut std::ffi::c_void)), WM_AGENT_DONE, WPARAM(0), LPARAM(0))
        };
    });
    if let Err(e) = spawned {
        LONG_BUSY.store(false, Ordering::Release);
        return Err(Refusal::new("CaptureFailed", format!("The long screenshot's thread could not be started: {e}.")));
    }
    Ok(())
}
