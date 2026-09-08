//! Handing something to the shell, from a thread the window loop does not
//! wait for.
//!
//! # Why this call must leave the window thread
//!
//! **Task 292, and the cause is constructed rather than guessed.** Ctrl+click
//! an OSC 8 link and the main thread stopped for good. Two things together
//! produce it, and neither alone does:
//!
//!   * **two `open_url` dispatches close together**, and
//!   * **the first one is a cold call** -- around 155 ms, the shell's first
//!     use in this process, against 14 ms once warm.
//!
//! Two adjacent *warm* calls do not hang. One *cold* call alone does not
//! hang.
//!
//! ⚠️ **"Both hangs stopped at a byte-identical RIP" is not the evidence it
//! looks like, and this comment used to lean on it.** `ntdll.dll+0x163fd4`
//! turns out to be a **generic wait point**: each dump has *three* threads
//! sitting on it (19412 / 6804 / 22216 in the 14840 one). Identical across
//! two runs is true and does not, by itself, say the two are one fault.
//!
//! What actually picks the main thread out of the three is narrower, and it
//! is what makes this change *the* repair rather than *a* repair: **the
//! stopped thread's tid equals the `watching main tid=` the watchdog printed
//! in the same log**, in both dumps --
//! `hang-14840` stopped on 19412 with `watching main tid=19412`, `hang-6776`
//! on 12728 with `watching main tid=12728` -- plus the `Windows.Storage.dll`
//! address band on its stack. **The thread that stopped was the main thread
//! itself, not some background one**, so "run this somewhere that is not the
//! main thread" is the definition of the fix and not a formality.
//!
//! **So the fix is not a timeout and not a retry.** The call is a shell
//! operation that can take arbitrarily long and, on this path, can stop
//! returning at all; what is wrong is that the thread which owns every window
//! in this process was the one waiting for it. Nothing that the person can
//! see is downstream of the shell finishing, so nothing is lost by not
//! waiting -- and the thread that paints, pumps and dispatches gets to carry
//! on.
//!
//! # What the boolean means now, which is not what it meant before
//!
//! It used to answer *did the shell accept this*. It cannot: the answer is
//! not known when this function returns. It now answers **did this host take
//! the request on**, and the outcome arrives in the log a moment later.
//!
//! That is the same trade `polterclose.rs` makes, and it is only honest
//! because of the line below: the result is *reported*, not dropped. A caller
//! that answers `true` to the core is claiming the request was accepted, and
//! the log is where the acceptance is redeemed.
//!
//! # Who reports a failure now
//!
//! **The worker does, and it reports more than the old code did.** Before,
//! `ok=false` was written by the thread that called it; now the worker writes
//! the same verdict plus how long the call took, tagged with the window the
//! request came from. Nothing that used to be logged has stopped being
//! logged -- that was the one thing this change was not allowed to cost.
//!
//! A failure of the *thread* itself (the spawn) is reported by the caller,
//! synchronously, because at that point there is no worker to do it.

use windows::core::PCWSTR;
use windows::Win32::Foundation::HWND;
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

use crate::{plogf, wlogf};

/// One number per request, so two opens close together can be told apart.
///
/// **Not decoration: the recipe that reproduces task 292 is two adjacent
/// opens** (`hang-readings.md` §7's `--twice`), and the reading that clears
/// this defect -- the window thread's own elapsed against the worker's --
/// only means anything **per pair**. Without a number on the lines, pairing
/// two interleaved timelines is guesswork, and a criterion that has to be
/// guessed at is not one. It is derived from the scenario the criterion will
/// be used in, which is the only place a criterion has to hold.
static REQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Hand `target` to the shell on a worker thread.
///
/// `tag` is the log prefix the call site uses (`[link]`, `[osk]`,
/// `[action] open_config`), so one reader grepping for a site finds both of
/// its lines. `frame` is only ever used to attribute those lines.
///
/// Returns whether the worker started. **A `false` here is the one failure
/// the caller must report itself**, and it is reported below as well.
pub fn detached(frame: Option<HWND>, tag: &'static str, target: String) -> bool {
    // **The window thread's own clock.** See the positive-criterion note on
    // this module: the point of this change is what happens to *this* thread,
    // and until now nothing measured it. The worker's duration was always
    // logged; the caller's never was, because before 324 the two were the
    // same number.
    let entered = std::time::Instant::now();
    // **The window travels as an integer.** `HWND` is a raw pointer and
    // therefore not `Send`; `tabs.rs` moves pane and window identities across
    // its queue the same way and says why. Rebuilt on the far side purely to
    // tag a log line.
    let frame_raw = frame.map(|f| f.0 as isize).unwrap_or(0);
    let announce = target.clone();

    let req = REQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);

    let worker = std::thread::Builder::new()
        .name("polter-shell-open".into())
        .spawn(move || {
            // **COM, per thread, and this is a new thread.** `ShellExecuteW`
            // goes through the shell's COM surface; the window thread has had
            // `CoInitializeEx(COINIT_APARTMENTTHREADED)` since `ime_init`, and
            // a thread that has not is a thread the call may refuse on, in a
            // way that reads as "the file would not open". Apartment-threaded
            // because that is what the shell expects of a caller that may put
            // UI up.
            let co = unsafe {
                windows::Win32::System::Com::CoInitializeEx(
                    None,
                    windows::Win32::System::Com::COINIT_APARTMENTTHREADED,
                )
            };
            // **① of three, and it is emitted here rather than by the caller
            // on purpose.** A line printed before the *spawn* says the request
            // was dispatched; this one says the call actually started. That
            // difference is what makes the three-tier reading in
            // `docs/windows/hang-readings.md` §7 possible at all: ① present
            // with ② absent means the window thread never came back, and ①
            // absent means nothing was triggered.
            //
            // `worker tid=` and never a bare `tid=`: the watchdog's line
            // carries two of them (`[wd] pid=… tid=<watchdog> up, watching
            // main tid=<main>`), so a pattern anchored on the bare word picks
            // the watchdog out of that line. The word `worker` is the anchor.
            let me = unsafe {
                windows::Win32::System::Threading::GetCurrentThreadId()
            };
            let f = HWND(frame_raw as *mut std::ffi::c_void);
            if frame_raw != 0 {
                wlogf!(
                    f,
                    "{} req={} worker tid={} calling ShellExecuteW now for {:?}",
                    tag, req, me, target
                );
            } else {
                // process-wide: the request named no surface, so there is no
                // window this line could belong to
                plogf!(
                    "{} req={} worker tid={} calling ShellExecuteW now for {:?}",
                    tag, req, me, target
                );
            }

            let wide: Vec<u16> = target.encode_utf16().chain(Some(0)).collect();
            let started = std::time::Instant::now();
            let r = unsafe {
                ShellExecuteW(
                    None,
                    windows::core::w!("open"),
                    PCWSTR(wide.as_ptr()),
                    PCWSTR::null(),
                    PCWSTR::null(),
                    SW_SHOWNORMAL,
                )
            };
            // `ShellExecuteW` answers with a fake `HINSTANCE`; `<= 32` is an
            // error code. The same reading every call site took before.
            let ok = r.0 as usize > 32;
            let took = started.elapsed().as_millis();
            if co.is_ok() {
                unsafe { windows::Win32::System::Com::CoUninitialize() };
            }

            // **The elapsed time is not decoration.** It is the reading that
            // named this defect: a cold call at ~155 ms next to a warm one at
            // 14 ms. Losing it would take away the number that made the cause
            // constructible.
            if frame_raw != 0 {
                wlogf!(
                    f,
                    "{} req={} worker tid={}: ShellExecuteW returned {} in {}ms for {:?}",
                    tag, req, me, ok, took, target
                );
            } else {
                // process-wide: the request named no surface, so this line is
                // about the process opening something rather than a window
                plogf!(
                    "{} req={} worker tid={}: ShellExecuteW returned {} in {}ms for {:?}",
                    tag, req, me, ok, took, target
                );
            }
        });

    // **The positive half of the criterion, and it says what it can prove.**
    // A `[…] handed off to worker …; the window thread returned in Nms` line
    // is impossible on the code before 324 -- there was no worker, and this
    // thread's own elapsed time was the shell call's. So its presence is
    // evidence the new path ran.
    //
    // **It is not evidence that nothing hangs.** It says this thread came
    // back, on this occasion; whether the window thread survives the two
    // adjacent opens that produced task 292 is answered by the recipe in
    // `docs/windows/hang-readings.md` §7, and by nothing here. Two readings,
    // and neither substitutes for the other.
    let spawned = match &worker {
        Ok(h) => {
            let _ = h;
            // **`handed off to worker` is a cross-tag literal, deliberately.**
            // The three call sites carry three different tags, so verifying
            // "every site moved" tag by tag needs three patterns -- and a
            // forgotten fourth pattern reads exactly like a site that was
            // never changed. ① and ③ share `ShellExecuteW`; this one shares
            // this phrase, so one `grep -E "ShellExecuteW|handed off to
            // worker"` sweeps all three whatever the tags become.
            match frame {
                Some(f) => wlogf!(
                    f,
                    "{} req={} handed off to worker; this thread returned in {}ms",
                    tag, req, entered.elapsed().as_millis()
                ),
                // process-wide: the request named no surface, so there is no
                // window this line could belong to
                None => plogf!(
                    "{} req={} handed off to worker; this thread returned in {}ms",
                    tag, req, entered.elapsed().as_millis()
                ),
            }
            true
        }
        Err(_) => false,
    };

    if !spawned {
        match frame {
            Some(f) => wlogf!(
                f,
                "{} req={} could NOT start the worker for {:?}; nothing was opened",
                tag, req, announce
            ),
            // process-wide: no worker and no window to attribute this to
            None => plogf!(
                "{} req={} could NOT start the worker for {:?}; nothing was opened",
                tag, req, announce
            ),
        }
    }
    spawned
}
