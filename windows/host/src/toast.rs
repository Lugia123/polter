//! Desktop notifications as WinRT toasts, which stay in the notification
//! centre as macOS's do (task 1551). The decisions -- toast or balloon, what
//! a toast says, what its click carries -- are `polter_control_room::toast`,
//! tested off Windows; this file is the calls.
//!
//! **The balloon stays, as the way back.** `notify.rs` asks here first and
//! shows its balloon whenever this answers `Route::Balloon`: the identity was
//! not registered, toasts are turned off, or `Show` failed. Each of those
//! says why in the log.
//!
//! ⚠️ **Two limits, said here because they are not visible from the code
//! that sends:**
//!
//!  * The identity is a registry key, `HKCU\Software\Classes\AppUserModelId\`
//!    and then [`AUMID`], written at every start. **Deleting the Polter directory
//!    leaves it**; it is harmless and can be deleted by hand.
//!  * **After Polter has quit, a click on one of its notifications in the
//!    notification centre does not start it.** A click arrives as the
//!    toast's `Activated` event, which exists only while this process does;
//!    starting Polter from one needs a COM activator, left out on purpose.
//!    macOS does start the app.
//!
//! Setting the process's AppUserModelID also changes how the taskbar groups
//! it: a Polter pinned before this is a different identity, and the two show
//! as two buttons until the old one is unpinned and the new one pinned.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

use polter_control_room::toast::{self as rules, Launch, Route, Setting, AUMID, GROUP};
use windows::core::{IInspectable, Interface, HSTRING, PCWSTR};
use windows::Data::Xml::Dom::XmlDocument;
use windows::Foundation::TypedEventHandler;
use windows::UI::Notifications::{ToastActivatedEventArgs, ToastNotification, ToastNotificationManager};
use windows::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_SET_VALUE, REG_OPTION_NON_VOLATILE, REG_SZ,
};
use windows::Win32::UI::Shell::SetCurrentProcessExplicitAppUserModelID;

use crate::plogf;

/// The identity is registered and the process carries it.
static REGISTERED: AtomicBool = AtomicBool::new(false);
/// The picture the toasts show, written out at start.
static LOGO: OnceLock<Option<String>> = OnceLock::new();
/// Terminals with a toast out, so focusing one takes its toasts back
/// without asking the shell about every terminal that takes focus.
static OUT: Mutex<Option<HashSet<u64>>> = Mutex::new(None);
/// The toasts shown this run, kept so their `Activated` handlers live as
/// long as anything could still be clicked. Bounded: an old one dropped
/// here is still in the notification centre, and a click on it then does
/// what one after a quit does -- nothing.
static KEPT: Mutex<Vec<ToastNotification>> = Mutex::new(Vec::new());
const KEEP: usize = 64;

/// `%LOCALAPPDATA%\polter\polter-toast.png`: the 256-pixel picture inside the
/// icon the host is built with. A toast's picture has to be a file.
fn logo_path() -> Option<PathBuf> {
    Some(crate::plugins::user_dir()?.parent()?.join("polter-toast.png"))
}

fn write_logo() -> Option<String> {
    let png = rules::png_in_ico(include_bytes!("../polter.ico"))?;
    let path = logo_path()?;
    if std::fs::read(&path).ok().as_deref() != Some(png) {
        let _ = std::fs::create_dir_all(path.parent()?);
        std::fs::write(&path, png).ok()?;
    }
    Some(path.to_string_lossy().into_owned())
}

fn set_string(key: HKEY, name: &str, value: &str) -> bool {
    let name: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
    let data: Vec<u8> = value.encode_utf16().chain(Some(0)).flat_map(u16::to_le_bytes).collect();
    unsafe { RegSetValueExW(key, PCWSTR(name.as_ptr()), None, REG_SZ, Some(&data)) }.is_ok()
}

/// `HKCU\Software\Classes\AppUserModelId\<AUMID>`: the name and picture
/// the notification centre shows for the identity.
fn write_key(logo: Option<&str>) -> bool {
    let path: Vec<u16> = format!("Software\\Classes\\AppUserModelId\\{AUMID}").encode_utf16().chain(Some(0)).collect();
    let mut key = HKEY::default();
    let made = unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            PCWSTR(path.as_ptr()),
            None,
            None,
            REG_OPTION_NON_VOLATILE,
            KEY_SET_VALUE,
            None,
            &mut key,
            None,
        )
    };
    if made.is_err() {
        return false;
    }
    let mut ok = set_string(key, "DisplayName", "Polter");
    if let Some(logo) = logo {
        ok &= set_string(key, "IconUri", logo);
    }
    let _ = unsafe { RegCloseKey(key) };
    ok
}

/// Register the identity and give it to this process. **Before any window
/// exists**: the taskbar reads a process's identity when it first shows one.
pub fn register() {
    let logo = LOGO.get_or_init(write_logo).clone();
    let key = write_key(logo.as_deref());
    let process = unsafe { SetCurrentProcessExplicitAppUserModelID(&HSTRING::from(AUMID)) }.is_ok();
    REGISTERED.store(key && process, Ordering::Release);
    // process-wide: the identity is the process's, before any window exists
    plogf!("[toast] identity {AUMID}: registry={key} process={process} logo={logo:?}");
}

/// Show one notification as a toast, or say why it must be the balloon.
/// The window's thread only (`notify.rs`'s worker).
pub fn show(title: &str, subtitle: Option<&str>, body: &str, launch: &Launch) -> Route {
    let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(AUMID)).ok();
    let setting = notifier.as_ref().and_then(|n| n.Setting().ok()).and_then(|s| Setting::from_i32(s.0));
    if let Route::Balloon(why) = rules::before_show(REGISTERED.load(Ordering::Acquire), setting) {
        return Route::Balloon(why);
    }
    let Some(notifier) = notifier else {
        return Route::Balloon(rules::Why::SettingUnreadable);
    };
    let logo = LOGO.get().cloned().flatten();
    let xml = rules::xml(title, subtitle, body, logo.as_deref(), &launch.encode());
    let terminal = launch.terminal;
    let sent = (|| -> windows::core::Result<ToastNotification> {
        let doc = XmlDocument::new()?;
        doc.LoadXml(&HSTRING::from(xml))?;
        let toast = ToastNotification::CreateToastNotification(&doc)?;
        if terminal != 0 {
            toast.SetTag(&HSTRING::from(rules::tag(terminal)))?;
        }
        toast.SetGroup(&HSTRING::from(GROUP))?;
        // On a thread of the system's: what it carries goes to the worker.
        toast.Activated(&TypedEventHandler::<ToastNotification, IInspectable>::new(|_, args| {
            if let Ok(args) = args.ok() {
                if let Ok(a) = args.cast::<ToastActivatedEventArgs>() {
                    crate::notify::on_toast_click(a.Arguments()?.to_string());
                }
            }
            Ok(())
        }))?;
        notifier.Show(&toast)?;
        Ok(toast)
    })();
    let route = rules::after_show(sent.is_ok());
    match sent {
        Ok(toast) => {
            if let Ok(mut k) = KEPT.lock() {
                if k.len() >= KEEP {
                    k.remove(0);
                }
                k.push(toast);
            }
            if terminal != 0 {
                if let Ok(mut out) = OUT.lock() {
                    out.get_or_insert_with(HashSet::new).insert(terminal);
                }
            }
        }
        // process-wide: the notifier is the process's
        Err(e) => plogf!("[toast] Show failed: {e:?}"),
    }
    route
}

/// The person went to `terminal`: its toasts leave the notification centre,
/// as macOS takes a terminal's back when it is focused. Only for a terminal
/// with one out, so ordinary focus changes never reach the shell.
pub fn withdraw(terminal: u64) {
    let had = OUT.lock().ok().and_then(|mut o| o.as_mut().map(|s| s.remove(&terminal))).unwrap_or(false);
    if !had {
        return;
    }
    let gone = ToastNotificationManager::History().and_then(|h| {
        h.RemoveGroupedTagWithId(&HSTRING::from(rules::tag(terminal)), &HSTRING::from(GROUP), &HSTRING::from(AUMID))
    });
    // process-wide: keyed by a terminal's id, which is unique in the process
    plogf!("[toast] terminal {terminal:016x} focused; its toasts taken back -> {}", gone.is_ok());
}
