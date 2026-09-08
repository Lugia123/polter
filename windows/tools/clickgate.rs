//! A click that refuses to happen unless the pointer is over the window it was
//! aimed at -- and, with `--twice`, two of them close enough together to make
//! the `open_url` hang happen on purpose.
//!
//! # Why a separate program instead of the automation tool's own click
//!
//! **The precondition has to be checked in the same process that sends the
//! event, and between the check and the click nothing may run.** Four times in
//! one week a real-machine reading was thrown away because the pointer was
//! over a browser window that had taken the foreground since the last
//! screenshot: the clicks went somewhere else, the log stayed empty, and the
//! empty log read exactly like "the feature does not work". Checking from a
//! tool one round trip away cannot close that window -- the browser takes the
//! foreground in tens of milliseconds.
//!
//! So: `WindowFromPoint` is read here, immediately before the event, and a
//! mismatch prints `GATE FAILED` and exits **without sending anything**. A run
//! that is gated out is a SKIPPED trial and must not go into any denominator.
//!
//! # `--twice`, and why 40 milliseconds
//!
//! `docs/windows/hang-readings.md` has the reading this exists for: one
//! `open_url` never hangs, two of them close together do -- but only when the
//! first one is the process's *first*, the expensive one. `--twice <ms>` sends
//! the second click after that many milliseconds, **gating again first**,
//! which is how the second half of the pair is kept honest.
//!
//! 40 works and 160 does not, and the reason is not the defect: by 160 ms the
//! browser window is already over the point and the gate correctly refuses.
//!
//! # Ctrl has to be down while the pointer moves
//!
//! A terminal decides whether it is over a link on `WM_MOUSEMOVE`. A pointer
//! parked before ctrl went down produces no move, so no link mode, so no
//! click on a link -- and the resulting "nothing happened" is a precondition
//! that was never met, not a reading. Hence the jiggle, and hence the second
//! gate after it.
//!
//! # Its own floor
//!
//! Aim it at a point that is **not** the target and it must print
//! `GATE FAILED` and exit non-zero. Run that before trusting a green: a gate
//! that has never been seen to refuse is not known to be a gate.
//!
//! Build (from a machine that cannot run it, which is the usual case):
//!
//!     rustc --target x86_64-pc-windows-gnu -O -o clickgate.exe clickgate.rs
//!
//! Usage:
//!
//!     clickgate <expected-hwnd-hex> <x> <y> [--plain] [--twice <gap-ms>]
//!
//! `<expected-hwnd-hex>` is the pane's handle **as the process under test
//! wrote it down** (`[pane] N hwnd = 0x…`), never one read off a screenshot.
//! `--plain` sends a click with no ctrl, for handing focus back to a window.

#![allow(non_snake_case)]
use std::os::raw::{c_int, c_void};
type HWND = *mut c_void;
#[repr(C)] #[derive(Copy, Clone, Default)] struct POINT { x: c_int, y: c_int }
#[link(name = "user32")]
extern "system" {
    fn SetProcessDPIAware() -> i32;
    fn SetCursorPos(x: c_int, y: c_int) -> i32;
    fn GetCursorPos(p: *mut POINT) -> i32;
    fn WindowFromPoint(p: POINT) -> HWND;
    fn GetAncestor(h: HWND, f: u32) -> HWND;
    fn mouse_event(f: u32, dx: u32, dy: u32, d: u32, e: usize);
    fn keybd_event(vk: u8, scan: u8, f: u32, e: usize);
}
const MOUSEEVENTF_LEFTDOWN: u32 = 0x0002;
const MOUSEEVENTF_LEFTUP: u32 = 0x0004;
const KEYEVENTF_KEYUP: u32 = 0x0002;
const VK_CONTROL: u8 = 0x11;
const GA_ROOT: u32 = 2;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 4 { println!("usage: clickgate <expected-hwnd-hex> <x> <y> [--plain] [--twice <gap-ms>]"); std::process::exit(64); }
    let want = usize::from_str_radix(a[1].trim_start_matches("0x"), 16).unwrap();
    let x: c_int = a[2].parse().unwrap();
    let y: c_int = a[3].parse().unwrap();
    let plain = a.iter().any(|s| s == "--plain");
    let twice: Option<u64> = a.iter().position(|s| s == "--twice")
        .and_then(|i| a.get(i + 1))
        .and_then(|v| v.parse().ok());
    unsafe {
        SetProcessDPIAware();
        SetCursorPos(x, y);
        let mut p = POINT::default();
        GetCursorPos(&mut p);
        let h = WindowFromPoint(p);
        let root = GetAncestor(h, GA_ROOT);
        println!("cursor asked=({},{}) got=({},{}) WindowFromPoint=0x{:x} root=0x{:x} expected=0x{:x}",
                 x, y, p.x, p.y, h as usize, root as usize, want);
        if h as usize != want {
            println!("GATE FAILED: nothing was sent");
            std::process::exit(2);
        }
        if !plain {
            keybd_event(VK_CONTROL, 0, 0, 0);
            // **Ctrl must be down while the pointer moves**, or the terminal
            // never enters link mode: it decides on WM_MOUSEMOVE, and a
            // cursor parked before ctrl went down produces no move at all.
            SetCursorPos(x + 1, y);
            std::thread::sleep(std::time::Duration::from_millis(80));
            SetCursorPos(x, y);
            std::thread::sleep(std::time::Duration::from_millis(220));
            // Gate again: the hover may have moved something.
            let mut p2 = POINT::default();
            GetCursorPos(&mut p2);
            let h2 = WindowFromPoint(p2);
            if h2 as usize != want {
                keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0);
                println!("GATE FAILED after hover: 0x{:x}; no click was sent", h2 as usize);
                std::process::exit(2);
            }
        }
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
        println!("SENT: {} click #1 at ({},{})", if plain {"plain"} else {"ctrl"}, p.x, p.y);
        // `--twice <ms>`: the 320 positive control. One press used to dispatch
        // twice (task 316); this makes two dispatches happen on purpose, so
        // that "two open_url in quick succession" can be tested as a variable
        // rather than waited for.
        if let Some(gap) = twice {
            std::thread::sleep(std::time::Duration::from_millis(gap));
            let mut p3 = POINT::default();
            GetCursorPos(&mut p3);
            let h3 = WindowFromPoint(p3);
            if h3 as usize != want {
                if !plain { keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0); }
                println!("GATE FAILED before click #2: 0x{:x}; only ONE click was sent", h3 as usize);
                std::process::exit(3);
            }
            mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
            mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
            println!("SENT: {} click #2 at ({},{}) after {}ms", if plain {"plain"} else {"ctrl"}, p3.x, p3.y, gap);
        }
        if !plain { keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0); }
    }
}
