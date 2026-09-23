//! Which language the host draws itself in, chosen from the menu.
//!
//! # The model is macOS's, on purpose
//!
//! `macos/Sources/Features/Language/AppLanguage.swift` is the other half of
//! this file: the same two languages, the same names, the same "write it down
//! and it takes effect next launch". **Two entries, not the 32 catalogues in
//! `src/os/i18n_locales.zig`.** Offering more is a decision for both
//! platforms at once; a Windows menu with 34 rows next to a macOS menu with
//! two would undo the point of putting the two menus in the same place.
//!
//! # How a choice reaches the core
//!
//! **The core is a DLL in this process, not a child of it**, and on Windows it
//! reads the environment from the live process block: `ghostty_init` hands
//! `global.init` `.use_global = true`. `LANG` is read by exactly one function
//! there, `windowsRequestedLocale`, which only `loadWindowsCatalog` calls, which
//! only `i18n.init` calls, which only `global.init` calls -- inside
//! `ghostty_init`. The catalogue it loads is kept for the life of the process.
//!
//! So `apply_before_init` puts `LANG` in place just before `ghostty_init`, the
//! same thing `GHOSTTY_LOG` already does in `main.rs` and `main.swift` does
//! with `setenv("LANG", ...)` -- and `restore_after_init` puts it back straight
//! afterwards, **so the shells this host starts do not inherit a language the
//! person chose for the menus**. GTK does the same for its children
//! (`src/apprt/gtk/class/surface.zig`, which hands them the old `LANG`).
//!
//! Restoring is only safe because nothing reads `LANG` after `ghostty_init`
//! on this platform. `ensureLocale` also runs inside `global.init`, and on
//! Windows it only calls `setlocale(LC_ALL, "")`, which takes its answer from
//! the OS rather than from `LANG`. **If a second reader of `LANG` is ever added
//! to the core, restoring would leave the menus in one language and that
//! reader in another** -- and that is the change that must come back here.
//!
//! # A `LANG` that is already set wins
//!
//! `src/os/i18n.zig` calls `LANG` "the only way a test or a bug report can ask
//! for a specific language without changing a system setting". A saved choice
//! that overrode it would close that way, and the symptom -- "I set `LANG` and
//! nothing changed" -- points nobody at a file in `%LOCALAPPDATA%`. So a
//! non-empty `LANG` is left alone, and the log says which one won.
//!
//! This is the one place the two platforms differ: `main.swift` overwrites.
//! A process started from the Start menu or Explorer has no `LANG`, so the
//! difference only shows when somebody set one deliberately.
//!
//! # Where the choice is kept
//!
//! `%LOCALAPPDATA%\polter\language`, one line, the same value macOS keeps in
//! `AppleLanguages`: `en` or `zh-Hans`. No file means no choice. Plain text so
//! that what was saved can be read with `type`, beside `session.json`.

use std::ffi::OsString;
use std::path::PathBuf;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::Mutex;

use windows::core::PCWSTR;
use windows::Win32::Foundation::{HWND, POINT};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::app_language::{decide, notice_after_save, AppLanguage, Notice, Startup};
use crate::i18n::tr;
use crate::{plogf, wlogf};

/// `%LOCALAPPDATA%\polter\language`, the sibling of `session.json`.
fn path() -> Option<PathBuf> {
    Some(crate::plugins::user_dir()?.parent()?.join("language"))
}

/// What the next launch will use, or `None` when nothing has been chosen.
pub fn selected() -> Option<AppLanguage> {
    let text = std::fs::read_to_string(path()?).ok()?;
    AppLanguage::from_name(&text)
}

/// How a pick ended. Three outcomes because "already chosen" and "could not
/// be written" both mean no prompt, and only one of them is fine.
#[derive(Debug, PartialEq, Eq)]
enum Saved {
    Written,
    AlreadyChosen,
    Failed,
}

/// Keep `language` for the next launch.
fn select(frame: HWND, language: AppLanguage) -> Saved {
    if selected() == Some(language) {
        wlogf!(frame, "[lang] {} was already the saved choice; nothing written", language.raw());
        return Saved::AlreadyChosen;
    }
    let Some(path) = path() else {
        wlogf!(frame, "[lang] no LOCALAPPDATA; {} not saved", language.raw());
        return Saved::Failed;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // Temporary file and rename, like `session.rs`: a half-written choice is
    // read back as no choice, one launch after whatever interrupted it.
    let tmp = path.with_extension("tmp");
    if let Err(e) = std::fs::write(&tmp, language.raw().as_bytes()) {
        wlogf!(frame, "[lang] write failed: {} path={}", e, tmp.display());
        return Saved::Failed;
    }
    if let Err(e) = std::fs::rename(&tmp, &path) {
        wlogf!(frame, "[lang] rename failed: {} path={}", e, path.display());
        let _ = std::fs::remove_file(&tmp);
        return Saved::Failed;
    }
    wlogf!(frame, "[lang] saved {} -> {}", language.raw(), path.display());
    Saved::Written
}

// ------------------------------------------------------------- at startup

/// `LANG` as it was before `apply_before_init` wrote it, when it did.
/// `Some(None)` is "there was no `LANG`"; `None` is "nothing was written, so
/// there is nothing to put back".
static PRIOR_LANG: Mutex<Option<Option<OsString>>> = Mutex::new(None);

/// Put the saved choice into `LANG` for `ghostty_init` to read.
///
/// **Call immediately before `ghostty_init`, and `restore_after_init`
/// immediately after.** Anything started in between inherits the choice.
pub fn apply_before_init() {
    let inherited = std::env::var_os("LANG");
    let saved = selected();

    // The table itself is `app_language::decide`, which is pure and tested.
    // A `LANG` that is not valid Unicode is still a set `LANG`; it is passed
    // as a placeholder that is non-empty, which is all `decide` asks of it.
    let inherited_str = inherited.as_ref().map(|v| v.to_str().unwrap_or("\u{fffd}"));
    match decide(inherited_str, saved) {
        Startup::HonourInherited { saved: s } => {
            // process-wide: startup, before any window exists
            plogf!(
                "[lang] LANG={} present, honouring it over saved choice {}",
                inherited.as_ref().unwrap().to_string_lossy(),
                s.raw()
            );
        }
        Startup::InheritedNoChoice => {
            // process-wide: startup, before any window exists
            plogf!(
                "[lang] LANG={} present and no saved choice",
                inherited.as_ref().unwrap().to_string_lossy()
            );
        }
        Startup::Apply(s) => {
            std::env::set_var("LANG", s.posix_locale());
            *PRIOR_LANG.lock().unwrap() = Some(inherited);
            // process-wide: startup, before any window exists
            plogf!("[lang] saved choice {} -> LANG={} for ghostty_init", s.raw(), s.posix_locale());
        }
        Startup::FollowSystem => {
            // process-wide: startup, before any window exists
            plogf!("[lang] no saved choice and no LANG; following the system");
        }
    }
}

/// Put `LANG` back the way the process found it, so shells do not inherit it.
pub fn restore_after_init() {
    let Some(prior) = PRIOR_LANG.lock().unwrap().take() else {
        return;
    };
    match prior {
        Some(v) => {
            std::env::set_var("LANG", &v);
            // process-wide: startup, before any window exists
            plogf!("[lang] LANG restored to {:?} after ghostty_init", v);
        }
        None => {
            std::env::remove_var("LANG");
            // process-wide: startup, before any window exists
            plogf!("[lang] LANG removed again after ghostty_init");
        }
    }
}

// -------------------------------------------------------------- the picker

/// The window the pending picker belongs to, and where the pointer was.
static PENDING_FRAME: AtomicPtr<core::ffi::c_void> = AtomicPtr::new(std::ptr::null_mut());
static PENDING_AT: Mutex<POINT> = Mutex::new(POINT { x: 0, y: 0 });

const ID_BASE: usize = 1;

/// Open the picker for `frame`. **Returns at once**; the menu opens from the
/// thread's own message loop.
///
/// Deferred for the reason `settings_ui::request_about` is: `--menu-selftest`
/// dispatches this row through the same call a click makes, and a
/// `TrackPopupMenu` entered here would hold the self-test inside its modal
/// loop until somebody dismissed it. A thread timer needs no window procedure
/// to reach, and runs on the thread that set it -- the one that owns `frame`.
///
/// ⚠️ **The cost, written here so it is not mistaken for a defect:** a
/// `--menu-selftest` run puts this menu on screen once, after the run, the
/// same way it shows the about box. The self-test performs every row, and
/// performing this one is opening the picker.
pub fn request_picker(frame: HWND) -> bool {
    let mut at = POINT::default();
    let _ = unsafe { GetCursorPos(&mut at) };
    *PENDING_AT.lock().unwrap() = at;
    PENDING_FRAME.store(frame.0, Ordering::Release);
    let id = unsafe { SetTimer(None, 0, 0, Some(picker_timer)) };
    // not-gated: the condition is the event -- the timer was refused, and
    // without this line a click that opened nothing would leave no trace.
    if id == 0 {
        wlogf!(frame, "[lang] SetTimer failed; picker not opened");
        return false;
    }
    wlogf!(frame, "[lang] picker requested at {},{}", at.x, at.y);
    true
}

unsafe extern "system" fn picker_timer(_: HWND, _: u32, id: usize, _: u32) {
    let _ = KillTimer(None, id);
    let frame = HWND(PENDING_FRAME.swap(std::ptr::null_mut(), Ordering::AcqRel));
    if frame.0.is_null() {
        return;
    }
    let at = *PENDING_AT.lock().unwrap();
    show_picker(frame, at);
}

fn show_picker(frame: HWND, at: POINT) {
    let current = selected();
    let chosen = unsafe {
        let menu = match CreatePopupMenu() {
            Ok(m) => m,
            Err(e) => {
                wlogf!(frame, "[lang] CreatePopupMenu failed: {e:?}");
                return;
            }
        };
        for (i, l) in AppLanguage::ALL.iter().enumerate() {
            let mut flags = MF_STRING;
            if current == Some(*l) {
                flags |= MF_CHECKED;
            }
            let wide: Vec<u16> = l.display_name().encode_utf16().chain(Some(0)).collect();
            let _ = AppendMenuW(menu, flags, ID_BASE + i, PCWSTR(wide.as_ptr()));
        }
        wlogf!(
            frame,
            "[lang] picker open, {} languages, saved={}",
            AppLanguage::ALL.len(),
            current.map_or("none", |l| l.raw())
        );
        let c = TrackPopupMenu(menu, TPM_RETURNCMD, at.x, at.y, None, frame, None);
        let _ = DestroyMenu(menu);
        c
    };

    let id = chosen.0 as usize;
    let Some(language) = id.checked_sub(ID_BASE).and_then(|i| AppLanguage::ALL.get(i)) else {
        // "Dismissed" and "never opened" look the same from outside.
        wlogf!(frame, "[lang] picker dismissed without a choice");
        return;
    };
    if select(frame, *language) != Saved::Written {
        return;
    }

    // **No restart button.** Restarting ends every shell and agent session in
    // every window; macOS's `relaunch()` does that, and it is not copied here.
    //
    // **And no promise the next start will not keep.** A `LANG` set in the
    // environment still wins over the saved choice (see this file's module
    // comment for why), and this sentence used to say "next time" regardless
    // -- on such a machine the choice then silently did not apply, and the
    // only trace was a log line. `notice_after_save` asks the same table the
    // next start will, with the `LANG` this process was started with, and the
    // value is shown so the person can clear it. Nothing is said about where
    // that `LANG` came from: that is not something this process can read.
    let lang = std::env::var_os("LANG").map(|v| v.to_string_lossy().into_owned());
    let text = match notice_after_save(lang.as_deref(), *language) {
        Notice::NextStart => {
            wlogf!(frame, "[lang] no LANG in the environment; the choice applies at the next start");
            tr("The language changes the next time Polter starts.")
        }
        Notice::LangWins(value) => {
            wlogf!(frame, "[lang] LANG={} is set; told the person it wins over {}", value, language.raw());
            tr("LANG={} is set in the environment Polter was started from, and Polter uses it in preference to this choice. For this choice to take effect, clear LANG and start Polter again.")
                .replacen("{}", value, 1)
        }
    };
    let title: Vec<u16> = tr("Language").encode_utf16().chain(Some(0)).collect();
    let body: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
    unsafe {
        MessageBoxW(
            Some(frame),
            PCWSTR(body.as_ptr()),
            PCWSTR(title.as_ptr()),
            MB_OK | MB_ICONINFORMATION,
        );
    }
    wlogf!(frame, "[lang] told the person the change waits for the next start");
}
