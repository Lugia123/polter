//! The list of shells under the chevron beside the strip's `+` (task 1804,
//! the 1778 v1 design's B): each shell this machine has, the one a new tab
//! starts by default marked so, and "Change Default Shell…" at the end.
//! Choosing a shell opens a tab running it, in the directory the terminal
//! being typed in last said it was in.
//!
//! **What there is and in what order is `polter_settings_shell::
//! shell_profiles`**, tested off Windows; the settings window's "Default
//! Shell" row reads the same rows, so the two lists are one list. This file
//! only looks at the machine and draws the menu.

use std::path::{Path, PathBuf};

use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::{HWND, POINT, RECT};
use windows::Win32::Graphics::Gdi::ClientToScreen;
use windows::Win32::System::Registry::{
    RegCloseKey, RegEnumKeyExW, RegGetValueW, RegOpenKeyExW, HKEY, HKEY_CURRENT_USER, KEY_READ, RRF_RT_REG_DWORD, RRF_RT_REG_SZ,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, DestroyMenu, TrackPopupMenu, MF_SEPARATOR, MF_STRING, TPM_LEFTALIGN, TPM_RETURNCMD, TPM_TOPALIGN,
};

use polter_settings_shell::shell_profiles::{self, Line, Machine, Profile, WslEntry};
use polter_settings_shell::{Route, Section};

use crate::i18n::tr;
use crate::wlogf;

/// Where the WSL distributions are registered, one subkey each.
const LXSS: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Lxss";

/// The shells this machine has, in the list's order.
pub fn detected() -> Vec<Profile> {
    let pwsh = pwsh_path();
    let winps = windows_powershell_path();
    let wsl = wsl_entries();
    shell_profiles::profiles(&Machine {
        pwsh: pwsh.as_deref().and_then(Path::to_str),
        windows_powershell: winps.as_deref().and_then(Path::to_str),
        wsl: &wsl,
    })
}

/// PowerShell 7, looked for where the core looks (`default_shell.zig`'s
/// `pwsh_locations`): `%ProgramFiles%`, then the Store's execution alias.
/// The alias is a reparse point the file system will not open as a file,
/// so being there is asked of the entry itself, not of what it points to.
fn pwsh_path() -> Option<PathBuf> {
    [("ProgramFiles", "PowerShell\\7\\pwsh.exe"), ("LOCALAPPDATA", "Microsoft\\WindowsApps\\pwsh.exe")]
        .into_iter()
        .filter_map(|(var, rel)| std::env::var_os(var).map(|base| PathBuf::from(base).join(rel)))
        .find(|p| std::fs::symlink_metadata(p).is_ok())
}

/// Windows PowerShell, under `%SystemRoot%` (`default_shell.zig`'s
/// `powershell_relative`).
fn windows_powershell_path() -> Option<PathBuf> {
    let root = std::env::var_os("SystemRoot")?;
    let p = PathBuf::from(root).join("System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    std::fs::symlink_metadata(&p).is_ok().then_some(p)
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Every `Lxss\{guid}` subkey's `DistributionName` and `State`. Nothing
/// when WSL was never installed: the key is not there.
fn wsl_entries() -> Vec<WslEntry> {
    let mut out = Vec::new();
    let path = wide(LXSS);
    let mut key = HKEY::default();
    if unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, PCWSTR(path.as_ptr()), Some(0), KEY_READ, &mut key) }.is_err() {
        return out;
    }
    let mut index = 0u32;
    loop {
        let mut name = [0u16; 256];
        let mut len = name.len() as u32;
        let r = unsafe { RegEnumKeyExW(key, index, Some(PWSTR(name.as_mut_ptr())), &mut len, None, None, None, None) };
        if r.is_err() {
            break;
        }
        index += 1;
        let sub = String::from_utf16_lossy(&name[..len as usize]);
        let sub_w = wide(&sub);
        let Some(distribution) = read_sz(key, &sub_w, "DistributionName") else { continue };
        out.push(WslEntry { name: distribution, state: read_dword(key, &sub_w, "State") });
    }
    let _ = unsafe { RegCloseKey(key) };
    out
}

fn read_sz(key: HKEY, sub: &[u16], value: &str) -> Option<String> {
    let value_w = wide(value);
    let mut buf = [0u16; 512];
    let mut bytes = (buf.len() * 2) as u32;
    let r = unsafe {
        RegGetValueW(key, PCWSTR(sub.as_ptr()), PCWSTR(value_w.as_ptr()), RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as *mut _), Some(&mut bytes))
    };
    if r.is_err() {
        return None;
    }
    let n = (bytes as usize / 2).min(buf.len());
    let s = String::from_utf16_lossy(&buf[..n]);
    Some(s.trim_end_matches('\0').to_string())
}

fn read_dword(key: HKEY, sub: &[u16], value: &str) -> Option<u32> {
    let value_w = wide(value);
    let mut v = 0u32;
    let mut bytes = std::mem::size_of::<u32>() as u32;
    let r = unsafe {
        RegGetValueW(key, PCWSTR(sub.as_ptr()), PCWSTR(value_w.as_ptr()), RRF_RT_REG_DWORD, None, Some(&mut v as *mut u32 as *mut _), Some(&mut bytes))
    };
    r.is_ok().then_some(v)
}

/// The command id of "Change Default Shell…": past every row's.
const CHANGE_DEFAULT: usize = 0x7FF0;

/// Show the list under `button` (the chevron, client coordinates of
/// `frame`) and do what was chosen.
pub fn show(frame: HWND, button: RECT) {
    let rows = detected();
    let configured = crate::general_ui::command_set();
    let sel = shell_profiles::selection(&rows, configured.as_deref());
    let lines = shell_profiles::menu(&rows, sel, &|m| tr(m));
    let chosen = unsafe {
        let Ok(menu) = CreatePopupMenu() else {
            wlogf!(frame, "[strip] shell chevron clicked but CreatePopupMenu failed");
            return;
        };
        for line in &lines {
            match line {
                Line::Row { index, text } => {
                    let w = wide(text);
                    let _ = AppendMenuW(menu, MF_STRING, index + 1, PCWSTR(w.as_ptr()));
                }
                Line::Separator => {
                    let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
                }
                Line::ChangeDefault(text) => {
                    let w = wide(text);
                    let _ = AppendMenuW(menu, MF_STRING, CHANGE_DEFAULT, PCWSTR(w.as_ptr()));
                }
            }
        }
        let mut pt = POINT { x: button.left, y: button.bottom };
        let _ = ClientToScreen(frame, &mut pt);
        // Handed back rather than posted, as the overflow menu's is.
        let cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN, pt.x, pt.y, None, frame, None);
        let _ = DestroyMenu(menu);
        cmd.0 as usize
    };
    if chosen == 0 {
        // silent-ok: Esc or a click elsewhere, the commonest way out of a menu.
        return;
    }
    if chosen == CHANGE_DEFAULT {
        wlogf!(frame, "[strip] shell list -> Change Default Shell");
        crate::settings_win::request(Route::to(Section::General, Some("terminal")), frame);
        return;
    }
    let Some(row) = rows.get(chosen - 1) else {
        wlogf!(frame, "[strip] shell list chose entry {chosen}, which is past its {} row(s); nothing opened", rows.len());
        return;
    };
    let cwd = crate::tabs::typing_cwd(frame);
    wlogf!(frame, "[strip] shell list -> {:?} ({:?})", row.name, row.kind);
    crate::tabs::post_op(frame, crate::tabs::Op::NewTabRunning { command: row.command.clone(), cwd }, "strip shell list");
}
