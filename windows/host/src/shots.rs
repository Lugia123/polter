//! Pasting what the clipboard holds when it is not text: copied files as
//! their paths, a bitmap as the path of a PNG saved from it.
//!
//! Specification: `dev-docs/poltergeist/screenshot.md` §2 and §5, shared with
//! macOS. **Every rule is in `polter-shots`**, where it has tests that run off
//! Windows -- which format wins, what a DIB decodes to, what the file is
//! called, which old files startup deletes. This file is only the Win32 on
//! either side of those rules, and should stay that way: nothing in
//! `polter-host` can be tested on the machine it is written on.
//!
//! **Nothing here runs unless the clipboard has no text.** The text path in
//! `cb_read_clipboard` is untouched, and with `clipboard-paste-image = false`
//! the answer for a clipboard without text is the `UNAVAILABLE` it has always
//! been -- which is what lets `ctrl+v` reach the program in the terminal.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use polter_shots::name::Stamp;
use polter_shots::paste::Reuse;
use windows::core::w;
use windows::Win32::Foundation::{HANDLE, HGLOBAL};
use windows::Win32::System::DataExchange::{
    CloseClipboard, GetClipboardData, GetClipboardSequenceNumber, IsClipboardFormatAvailable,
    OpenClipboard, RegisterClipboardFormatW,
};
use windows::Win32::System::Memory::{GlobalLock, GlobalSize, GlobalUnlock};
use windows::Win32::UI::Shell::HDROP;

use crate::{logf, plogf};

/// `CF_DIB` and `CF_HDROP`, spelled numerically for the reason
/// `tabs::CF_UNICODETEXT` is.
const CF_DIB: u32 = 8;
const CF_HDROP: u32 = 15;

/// The setting's name, here once.
const KEY: &str = "clipboard-paste-image";

/// The last image saved off the clipboard and the clipboard state it was.
static REUSE: Mutex<Reuse> = Mutex::new(Reuse::new());

/// Is `clipboard-paste-image` on?
///
/// **Read when used, not cached**, so a config reload is followed -- the rule
/// `capture.rs` states for its own setting.
///
/// **On when the config cannot be asked**, which is the core's default. That
/// it could not be asked is said once: a core that does not know the key
/// would otherwise say so on every paste.
pub fn enabled() -> bool {
    static SAID: AtomicBool = AtomicBool::new(false);
    let cfg = crate::config_handle();
    let mut on: bool = true;
    let ok = !cfg.is_null()
        && unsafe {
            (crate::api().config_get)(
                cfg,
                &mut on as *mut bool as *mut std::ffi::c_void,
                KEY.as_ptr(),
                KEY.len(),
            )
        };
    if !ok {
        // absence: depends -- said once per process, so a later paste that
        // could not read the key is silent; no line at all in a log means the
        // key was read every time it was asked for
        if !SAID.swap(true, Ordering::Relaxed) {
            // process-wide: a fact about the config this process loaded, not
            // about any one window
            plogf!("[shots] {KEY} could not be read; assuming on (said once)");
        }
        return true;
    }
    on
}

/// Where shots are kept: `screenshot-directory` when it is set, otherwise
/// `%LOCALAPPDATA%\polter\shots` (`XDG_STATE_HOME` first), the same root as
/// projects. Read when used, like `enabled`.
pub fn dir() -> Option<PathBuf> {
    const DIR_KEY: &str = "screenshot-directory";
    let cfg = crate::config_handle();
    // `?[:0]const u8`: the core writes a pointer, null when the key is unset.
    let mut p: *const std::os::raw::c_char = std::ptr::null();
    let ok = !cfg.is_null()
        && unsafe {
            (crate::api().config_get)(
                cfg,
                &mut p as *mut *const std::os::raw::c_char as *mut std::ffi::c_void,
                DIR_KEY.as_ptr(),
                DIR_KEY.len(),
            )
        };
    // Copied at once: the pointer is the config's, and a reload frees it.
    let configured =
        (ok && !p.is_null()).then(|| unsafe { std::ffi::CStr::from_ptr(p) }.to_string_lossy().to_string());
    let home = std::env::var_os("USERPROFILE").filter(|v| !v.is_empty()).map(PathBuf::from);
    polter_shots::store::directory(
        configured.as_deref(),
        home.as_deref(),
        crate::project::resolve_state_dir().map(|s| s.join("shots")),
    )
}

/// Record that the clipboard, as it is now numbered `seq`, holds the image
/// saved at `path` -- a screenshot just put there -- with the tiles it was
/// cut into if it is a long one, and the line that goes with it.
pub fn remember(seq: u32, path: PathBuf, tiles: Vec<PathBuf>, note: Option<String>) {
    REUSE.lock().unwrap_or_else(|e| e.into_inner()).remember(seq, path, tiles, note);
}

/// The clipboard's own `PNG` format, which browsers and image editors put
/// beside the bitmap. Registered formats are named, not numbered; 0 when the
/// registration fails.
fn png_format() -> u32 {
    unsafe { RegisterClipboardFormatW(w!("PNG")) }
}

/// A file list is on the clipboard (copied in Explorer).
pub fn has_files() -> bool {
    unsafe { IsClipboardFormatAvailable(CF_HDROP).is_ok() }
}

/// A bitmap is on the clipboard. `CF_DIB` is synthesised from `CF_BITMAP` and
/// `CF_DIBV5`, so asking for the one covers the three.
pub fn has_image() -> bool {
    let png = png_format();
    unsafe { IsClipboardFormatAvailable(CF_DIB).is_ok() || (png != 0 && IsClipboardFormatAvailable(png).is_ok()) }
}

/// The clipboard, open. Closed on drop, so no early return leaves it held --
/// a clipboard left open is broken for every program on the machine.
struct Open;

impl Open {
    fn new() -> Result<Open, &'static str> {
        unsafe { OpenClipboard(None) }
            .map(|()| Open)
            .map_err(|_| "OpenClipboard denied (another process holds it)")
    }

    /// A copy of one format's bytes. The handle is the clipboard's: locked
    /// and unlocked, never freed, never read after the clipboard is closed.
    fn bytes(&self, format: u32) -> Result<Vec<u8>, &'static str> {
        unsafe {
            let h = GetClipboardData(format).map_err(|_| "GetClipboardData failed")?;
            let hg = HGLOBAL(h.0);
            let p = GlobalLock(hg) as *const u8;
            if p.is_null() {
                return Err("GlobalLock failed");
            }
            let bytes = std::slice::from_raw_parts(p, GlobalSize(hg)).to_vec();
            let _ = GlobalUnlock(hg);
            Ok(bytes)
        }
    }

    fn files(&self) -> Result<Vec<String>, &'static str> {
        let h: HANDLE = unsafe { GetClipboardData(CF_HDROP) }.map_err(|_| "GetClipboardData failed")?;
        Ok(crate::dnd::hdrop_paths(HDROP(h.0)))
    }
}

impl Drop for Open {
    fn drop(&mut self) {
        let _ = unsafe { CloseClipboard() };
    }
}

/// The copied files as the text a drop of them would insert, or `None` (and a
/// log line saying why) when they cannot be read.
pub fn files_text(pane: u64) -> Option<String> {
    let paths = match Open::new().and_then(|c| c.files()) {
        Ok(p) if !p.is_empty() => p,
        Ok(_) => {
            logf!("[clip] read pane={} -> files: CF_HDROP is there but lists no file", pane);
            return None;
        }
        Err(why) => {
            logf!("[clip] read pane={} -> files: {}", pane, why);
            return None;
        }
    };
    logf!("[clip] read pane={} -> files: {} path(s) from CF_HDROP", pane, paths.len());
    Some(polter_droppath::join(&paths))
}

/// The clipboard's image as PNG bytes, and which format they came from.
fn image_png(pane: u64) -> Result<(Vec<u8>, &'static str), String> {
    let clip = Open::new()?;
    // The clipboard's own PNG first: it is the picture as its source encoded
    // it, alpha included, with nothing for this host to get wrong.
    let png = png_format();
    if png != 0 && unsafe { IsClipboardFormatAvailable(png).is_ok() } {
        match clip.bytes(png) {
            Ok(b) if polter_shots::encode::is_png(&b) => return Ok((b, "PNG")),
            Ok(_) => logf!("[clip] read pane={} -> image: the clipboard's PNG format does not hold a PNG; trying CF_DIB", pane),
            Err(why) => logf!(
                "[clip] read pane={} -> image: the clipboard's PNG format could not be read ({}); trying CF_DIB",
                pane, why
            ),
        }
    }
    let dib = clip.bytes(CF_DIB)?;
    drop(clip);
    let image = polter_shots::dib::decode(&dib).map_err(|e| format!("CF_DIB not decoded: {e:?}"))?;
    let bytes = polter_shots::encode::png(&image).ok_or("PNG encoding failed")?;
    Ok((bytes, "CF_DIB"))
}

fn now() -> Stamp {
    let t = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    Stamp {
        year: t.wYear,
        month: t.wMonth as u8,
        day: t.wDay as u8,
        hour: t.wHour as u8,
        minute: t.wMinute as u8,
        second: t.wSecond as u8,
        milli: t.wMilliseconds,
    }
}

/// The path of a PNG holding the clipboard's image, quoted as a dropped file
/// would be -- the whole of the pasted text, with nothing after it. `None`
/// (and a log line saying why) when there is no file to name.
///
/// Pasting the same image twice names the same file: the clipboard's sequence
/// number is what "the same" means.
pub fn image_text(pane: u64) -> Option<String> {
    let seq = unsafe { GetClipboardSequenceNumber() };
    // An image pasted into a pane whose last paste is still arriving piece by
    // piece -- a long screenshot's tiles: what was left of that one is
    // dropped. Pasted again, the pieces start over from the first; a
    // different image should not have the old one's tiles land after it.
    let dropped = crate::shot::forget_pastes(pane);
    let mut reuse = REUSE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(saved) = reuse.lookup(seq) {
        // A screenshot taken here: this paste is the one way it reaches a
        // terminal. Its path answers the paste -- a long one's first tile
        // rather than itself -- and the rest follow, each a paste of its own
        // into **this** pane, by id: a pane closed before a piece is due
        // gets none of what is left, and no other pane gets it instead.
        // Each piece ends with the separator when something follows it
        // (`Saved::texts`): the terminal's line editor joins what the pastes
        // carry, and `path[notes]` is not a path and a line.
        let (first, later) = saved.texts(|p| polter_droppath::quote(&p.to_string_lossy()));
        logf!(
            "[clip] read pane={} -> image: reusing {} (clipboard sequence {} unchanged); pasting {:?}, then {} more \
             piece(s), one every {} ms ({} tile(s) in all, a line of text: {}); {} piece(s) of an earlier paste \
             into this pane dropped",
            pane,
            saved.path.display(),
            seq,
            first,
            later.len(),
            polter_shots::paste::SECOND_PASTE_DELAY_MS,
            saved.tiles.len(),
            saved.note.is_some(),
            dropped
        );
        for piece in later {
            let what = match (piece.is_line, saved.tiles.is_empty()) {
                (false, _) => "tile path",
                (true, true) => "annotation line",
                (true, false) => "long-screenshot line",
            };
            crate::shot::paste_later(pane, piece.text, piece.delay_ms, what);
        }
        return Some(first);
    }
    let Some(dir) = dir() else {
        logf!("[clip] read pane={} -> image: no screenshot-directory and no LOCALAPPDATA, so nowhere to save it", pane);
        return None;
    };
    let (bytes, from) = match image_png(pane) {
        Ok(found) => found,
        Err(why) => {
            logf!("[clip] read pane={} -> image: {}", pane, why);
            return None;
        }
    };
    let pause = || std::thread::sleep(std::time::Duration::from_millis(1));
    let path = match polter_shots::store::write_new(&dir, now, pause, &bytes) {
        Ok(p) => p,
        Err(e) => {
            logf!("[clip] read pane={} -> image: not saved under {}: {}", pane, dir.display(), e);
            return None;
        }
    };
    logf!(
        "[clip] read pane={} -> image: saved {} ({} bytes, from {}, clipboard sequence {}); {} piece(s) of an \
         earlier paste into this pane dropped",
        pane, path.display(), bytes.len(), from, seq, dropped
    );
    let text = polter_droppath::quote(&path.to_string_lossy());
    reuse.remember(seq, path, Vec::new(), None);
    Some(text)
}

/// Delete shots older than seven days. Once, at startup.
///
/// Only files named the way this host names them: the directory can be
/// anyone's (`screenshot-directory`), and `polter_shots::sweep` is where that
/// promise is kept and tested.
pub fn sweep_old() {
    let Some(dir) = dir() else {
        // process-wide: startup housekeeping, before and apart from any window
        plogf!("[shots] sweep: no screenshot-directory and no LOCALAPPDATA, so no directory to sweep");
        return;
    };
    match polter_shots::sweep::sweep(&dir, std::time::SystemTime::now(), polter_shots::sweep::MAX_AGE) {
        // process-wide: startup housekeeping, before and apart from any window
        Ok(r) => plogf!(
            "[shots] sweep {}: {} file(s) seen, {} deleted {:?}, {} could not be deleted {:?}",
            dir.display(), r.seen, r.deleted.len(), r.deleted, r.failed.len(), r.failed
        ),
        // process-wide: startup housekeeping, before and apart from any window
        Err(e) => plogf!("[shots] sweep {}: could not be listed: {}", dir.display(), e),
    }
}
