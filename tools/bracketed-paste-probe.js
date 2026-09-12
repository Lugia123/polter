#!/usr/bin/env node
//
// bracketed-paste-probe.js -- does Ghostty record `CSI ? 2004 h` from the child?
//
// =====================================================================
// WHAT THIS ANSWERS
// =====================================================================
//
// `Surface.completeClipboardPaste` frames pasted text whenever bracketed
// paste is on. The framing is unconditional at that point:
//
//     src/input/paste.zig:95-98
//         if (opts.bracketed) {
//             result[0] = "\x1b[200~";
//             result[2] = "\x1b[201~";
//             return result;
//         }
//
// and `opts` is read straight off the terminal's own mode table:
//
//     src/input/paste.zig:9-13
//         pub fn fromTerminal(t: *const Terminal) Options {
//             return .{ .bracketed = t.modes.get(.bracketed_paste) };
//         }
//
// A real-machine reading (docs/windows/terminal-send-not-submitted.md,
// section 6, reading 2) says a probe that had sent `ESC[?2004h` still saw
// `terminal_send` arrive as bare bytes -- no `ESC[200~`, no `ESC[201~`.
// Those two facts can only both be true if, at that moment,
// `t.modes.get(.bracketed_paste)` was FALSE: the child's request had not
// been recorded in the terminal's state.
//
// This probe tests that directly, and does not have to infer it from the
// absence of a frame.
//
// =====================================================================
// THE INSTRUMENT: DECRQM, NOT "DID A FRAME SHOW UP"
// =====================================================================
//
// Ghostty answers DECRQM (`CSI ? 2004 $ p`) out of the same mode table
// that `fromTerminal` reads:
//
//     src/termio/stream_handler.zig:612-614
//         fn requestMode(self: *StreamHandler, mode: terminal.Mode) !void {
//             self.sendModeReport(self.terminal.modes.getReport(.fromMode(mode)));
//         }
//
//     src/terminal/modes.zig:220-229  (DECRPM encoding)
//         try writer.print("\x1B[{s}{};{}$y", ...);
//
//     src/terminal/modes.zig:211-217  (the state byte)
//         not_recognized = 0, set = 1, reset = 2,
//         permanently_set = 3, permanently_reset = 4
//
// So `ESC[?2004;1$y` means Ghostty's own recorded bit is SET and
// `ESC[?2004;2$y` means it is RESET. That is a direct read of the value
// `paste.zig` will consult -- one round trip, no guessing.
//
// =====================================================================
// THE FLOOR (this is the point of the script, do not skip it)
// =====================================================================
//
// "No frame showed up" is ambiguous between "the product did not frame it"
// and "the probe never asked for framing". Three floors separate those:
//
//   FLOOR A -- the query answers differently before and after.
//     DECRQM is asked ONCE BEFORE `ESC[?2004h` and ONCE AFTER. A probe
//     whose query is broken, or whose reply is a constant, gives the same
//     answer twice. **Two identical answers void the whole run.** The
//     expected pair is reset(2) then set(1).
//
//   FLOOR B -- the request actually left this process.
//     `ESC[?2004h` is written with an explicit flush callback and the
//     byte count is reported. A write that never drained is reported as
//     such rather than assumed.
//
//   FLOOR C -- this process really is in raw mode.
//     `isRaw` is our own flag and proves nothing on its own, so the floor
//     is an observation: the operator presses the real keyboard's Enter
//     once and it must arrive as a SINGLE `0d` byte in its own data event.
//     Cooked mode gives `0d0a`, or nothing until a full line, or a
//     translated `0a`. If the floor is not established the run says so
//     and every later reading is marked unusable.
//
//     (Raw mode also has to be on for the probe to be honest about what
//     the product's real targets look like: an agent CLI puts the tty in
//     raw mode, so the line discipline's CR/LF rewriting -- ICRNL -- is
//     off for it. A cooked probe would measure its own line discipline
//     instead of the product. On Windows there is no line discipline at
//     all, which is the other half of why raw is the comparable state.)
//
// =====================================================================
// THE CRITERION
// =====================================================================
//
// After the floors are green, send text at this terminal with Polter and
// read the hex. `ESC[200~` is `1b5b3230307e`; `ESC[201~` is `1b5b3230317e`.
//
//   terminal_send(id, "abc")                 -- single line
//   terminal_send(id, "line one\nline two")  -- multi line
//
// Read the two together with the DECRQM answer:
//
//  DECRQM after 2004h | what arrives                        | reading
//  -------------------+-------------------------------------+------------------
//  ;1$y  (set)        | hex contains 1b5b3230307e           | mode recorded AND
//                     |                                     | framed. This lead
//                     |                                     | is DEAD.
//  ;1$y  (set)        | no 1b5b3230307e                     | contradiction: the
//                     |                                     | bit is set but the
//                     |                                     | encoder did not
//                     |                                     | frame. Go back to
//                     |                                     | paste.zig.
//  ;2$y  (reset)      | multi-line send REFUSED             | *** the lead is
//                     | (UnbracketedMultiline)              | CONFIRMED: the
//                     |                                     | child's request was
//                     |                                     | not recorded.
//  ;2$y  (reset)      | multi-line send delivers bytes      | contradiction: the
//                     |                                     | refusal at
//                     |                                     | Surface.zig:4104-4106
//                     |                                     | should have fired
//                     |                                     | first. You are not
//                     |                                     | reading the same
//                     |                                     | surface or the same
//                     |                                     | moment.
//  ;0$y               | --                                  | mode not recognised.
//                     |                                     | Whole run void.
//  no reply           | --                                  | NOT "reset". The
//                     |                                     | reply channel was
//                     |                                     | never shown to
//                     |                                     | work. Run void.
//
// *** Note the third row: when the bit is false a MULTI-LINE send never
// reaches the pty at all --
//
//     src/Surface.zig:4104-4106
//         if (multiline and !encode_opts.bracketed) {
//             log.warn("poltergeist: refusing multi-line text, bracketed paste is off", .{});
//             return error.UnbracketedMultiline;
//         }
//
// -- so for the multi-line case the reading is the RETURN VALUE of
// terminal_send, not the hex. The hex is the reading for the single-line
// case, which is never refused and is the one the original anomaly was
// observed on.
//
// =====================================================================
// TWO WAYS TO GET A FALSE "REFUSED" (read these before calling it)
// =====================================================================
//
//   1. A key reaching this surface in the last 10s makes every send fail
//      with UserPresent, not with UnbracketedMultiline --
//      `notice_quiet_keyboard_ms` is `10 * std.time.ms_per_s`
//      (src/Surface.zig:3666), checked at src/Surface.zig:4027-4036.
//      FLOOR C presses Enter, so it starts that clock. This script prints
//      a line when the window has passed. Wait for it.
//
//   2. An earlier `submit=false` send leaves a draft, and a terminal with
//      an outstanding draft refuses everything with UserPresent too
//      (src/Surface.zig:4046-4053). Use a fresh terminal.
//
//   The two refusals are different errors; read the error, not "it failed".
//
// =====================================================================
// USAGE
// =====================================================================
//
//   node bracketed-paste-probe.js
//
// Runs until Ctrl-C (which in raw mode arrives here as byte 0x03 and is
// handled, not delivered as a signal). On exit it puts mode 2004 back to
// whatever the FIRST DECRQM said it was -- not unconditionally off, which
// would switch off a mode the terminal already had on. If the run stopped
// before that first answer arrived it writes nothing.
//
// Every line beginning "#" is a raw reading: one stdin data event, hex
// only, undecoded. Every line beginning "[" is this script talking.
//
'use strict';

const fs = require('fs');

const ESC = '\x1b';
const SET_2004 = ESC + '[?2004h';
const RESET_2004 = ESC + '[?2004l';
const QUERY_2004 = ESC + '[?2004$p';

const QUERY_TIMEOUT_MS = 2000;
const QUIET_WINDOW_MS = 10000; // notice_quiet_keyboard_ms, src/Surface.zig:3666
const ENTER_FLOOR_TIMEOUT_MS = 60000;

const t0 = process.hrtime.bigint();
function ms() {
    return Number((process.hrtime.bigint() - t0) / 1000n) / 1000;
}
function stamp() {
    return ms().toFixed(3).padStart(11);
}

function say(s) {
    process.stdout.write('[' + stamp() + '] ' + s + '\r\n');
}

// ---------------------------------------------------------------------
// State
// ---------------------------------------------------------------------

let eventSeq = 0;
let restored = false;

// Set while a DECRQM answer is being waited for. Everything still gets
// logged raw; this only routes a copy to the waiter.
let pending = null;

const floors = {
    tty: null,        // stdin is a tty and raw mode was accepted
    wrote2004h: null, // the request drained out of this process
    queryBefore: null,// state digit seen before the request, or null
    queryAfter: null, // state digit seen after the request, or null
    differs: null,    // the two answers are not the same
    enterIsBare0d: null,
};

// ---------------------------------------------------------------------
// Raw reading channel. Nothing here decodes; hex only.
// ---------------------------------------------------------------------

function onData(buf) {
    eventSeq += 1;
    const hex = buf.toString('hex');
    process.stdout.write(
        '#' + String(eventSeq).padStart(3, '0') +
        ' t=+' + stamp() + 'ms' +
        ' len=' + String(buf.length).padStart(4) +
        ' hex=' + hex + '\r\n'
    );

    if (pending) pending.feed(buf);

    // Ctrl-C. In raw mode this is a byte, not a signal, so the exit has to
    // be arranged here or the probe cannot be stopped without killing it.
    if (buf.includes(0x03)) {
        say('0x03 (ctrl-c) seen -- restoring and exiting');
        finish(0);
    }
}

// ---------------------------------------------------------------------
// DECRQM round trip
// ---------------------------------------------------------------------

// Matches ESC [ ? 2004 ; <digit> $ y
const DECRPM_RE = /\x1b\[\?2004;(\d)\$y/;

function queryMode(label) {
    return new Promise((resolve) => {
        let acc = Buffer.alloc(0);
        let done = false;

        const timer = setTimeout(() => {
            if (done) return;
            done = true;
            pending = null;
            say('DECRQM(' + label + '): NO REPLY within ' + QUERY_TIMEOUT_MS + 'ms');
            say('  ^ this is NOT "reset". It means the reply channel was never');
            say('    shown to work, so nothing measured after it is usable.');
            resolve(null);
        }, QUERY_TIMEOUT_MS);

        pending = {
            feed(buf) {
                if (done) return;
                acc = Buffer.concat([acc, buf]);
                const m = DECRPM_RE.exec(acc.toString('latin1'));
                if (!m) return;
                done = true;
                clearTimeout(timer);
                pending = null;
                const digit = m[1];
                const names = {
                    '0': 'not_recognized',
                    '1': 'set',
                    '2': 'reset',
                    '3': 'permanently_set',
                    '4': 'permanently_reset',
                };
                say('DECRQM(' + label + '): ESC[?2004;' + digit + '$y  => ' +
                    (names[digit] || 'unknown(' + digit + ')'));
                resolve(digit);
            },
        };

        process.stdout.write(QUERY_2004);
    });
}

// ---------------------------------------------------------------------
// Floors
// ---------------------------------------------------------------------

function write2004h() {
    return new Promise((resolve) => {
        const drained = process.stdout.write(SET_2004, () => {
            say('FLOOR B: wrote ESC[?2004h (' + SET_2004.length +
                ' bytes) and the write drained' +
                (drained ? '' : ' (after backpressure)'));
            floors.wrote2004h = true;
            resolve(true);
        });
        // The callback is what proves it left; `drained` alone only says it
        // did not have to queue. If the callback never fires the promise
        // never settles, which is louder than a silent assumption.
    });
}

function enterFloor() {
    return new Promise((resolve) => {
        say('');
        say('FLOOR C: press ENTER on the REAL keyboard, once, now.');
        say('  expected: one data event, len=1, hex=0d');
        say('  0d0a, or a whole line arriving at once, or a bare 0a, all mean');
        say('  this process is NOT in raw mode and every later reading is void.');

        const seen = [];
        const handler = (buf) => {
            seen.push(buf);
            const hex = buf.toString('hex');
            if (hex === '0d') {
                cleanup();
                floors.enterIsBare0d = true;
                say('FLOOR C: PASS -- a bare 0d in its own event.');
                resolve(true);
                return;
            }
            if (hex.includes('0d') || hex.includes('0a')) {
                cleanup();
                floors.enterIsBare0d = false;
                say('FLOOR C: FAIL -- expected a lone 0d, got hex=' + hex);
                resolve(false);
            }
        };
        const timer = setTimeout(() => {
            cleanup();
            floors.enterIsBare0d = null;
            say('FLOOR C: NOT ESTABLISHED -- nothing arrived in ' +
                (ENTER_FLOOR_TIMEOUT_MS / 1000) + 's.');
            say('  Not established is not the same as failed, and neither one');
            say('  is a pass. Readings after this are unusable either way.');
            resolve(null);
        }, ENTER_FLOOR_TIMEOUT_MS);

        function cleanup() {
            clearTimeout(timer);
            process.stdin.removeListener('data', handler);
        }
        process.stdin.on('data', handler);
    });
}

// ---------------------------------------------------------------------
// Teardown
// ---------------------------------------------------------------------

function restore() {
    if (restored) return;
    restored = true;
    // Put the mode back to WHAT IT WAS, which is not the same as turning it
    // off. `floors.queryBefore` is the only thing that knows, and if the run
    // stopped before that answer arrived the honest move is to write nothing
    // rather than switch off a mode somebody else had turned on.
    //
    // Synchronous, because an async write at exit does not flush.
    try {
        if (floors.queryBefore === '1' || floors.queryBefore === '3') {
            fs.writeSync(1, SET_2004);
        } else if (floors.queryBefore !== null) {
            fs.writeSync(1, RESET_2004);
        }
    } catch (_) {
        // Nothing useful to do; the terminal is going away anyway.
    }
    try {
        if (process.stdin.isTTY) process.stdin.setRawMode(false);
    } catch (_) {}
}

function finish(code) {
    restore();
    process.exit(code);
}

process.on('exit', restore);
process.on('SIGINT', () => finish(0));
process.on('SIGTERM', () => finish(0));

// ---------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------

async function main() {
    say('bracketed-paste-probe -- reading Ghostty\'s recorded mode 2004');
    say('pid=' + process.pid + ' node=' + process.version +
        ' platform=' + process.platform);

    if (!process.stdin.isTTY) {
        floors.tty = false;
        say('FLOOR C: FAIL -- stdin is not a tty. Run this in the terminal');
        say('  under test, not through a pipe or a redirect. Stopping.');
        finish(2);
        return;
    }
    process.stdin.setRawMode(true);
    floors.tty = process.stdin.isRaw === true;
    say('stdin.isTTY=true stdin.isRaw=' + process.stdin.isRaw +
        '   (this is our own flag; FLOOR C is what actually tests it)');

    process.stdin.resume();
    process.stdin.on('data', onData);

    // FLOOR A, first half. Asked BEFORE the request so the pair can differ.
    floors.queryBefore = await queryMode('before 2004h');

    // FLOOR B.
    await write2004h();

    // Give the emulator a moment to parse it before asking again. This is
    // not a fix for a race, it is slack on a round trip that has to happen
    // in order; if the answer is still 'reset' after this, that is the
    // reading the probe exists to take.
    await new Promise((r) => setTimeout(r, 250));

    // FLOOR A, second half.
    floors.queryAfter = await queryMode('after 2004h');

    floors.differs =
        floors.queryBefore !== null &&
        floors.queryAfter !== null &&
        floors.queryBefore !== floors.queryAfter;

    say('');
    say('=== FLOOR A ===');
    say('  before=' + floors.queryBefore + '  after=' + floors.queryAfter);
    if (floors.queryBefore === null || floors.queryAfter === null) {
        say('  NOT ESTABLISHED: a query went unanswered. Run void.');
    } else if (!floors.differs) {
        say('  FAIL: the two answers are IDENTICAL. A query that cannot');
        say('  change its answer cannot report a change. Run void --');
        say('  do not read anything below as evidence about the product.');
    } else if (floors.queryBefore === '2' && floors.queryAfter === '1') {
        say('  PASS: reset -> set. The request was recorded.');
        say('  *** So the lead is NOT confirmed by this half: Ghostty did');
        say('  record mode 2004. Go on to the send and read the hex; if a');
        say('  frame is still missing the fault is in the encoder, not the');
        say('  mode table.');
    } else {
        say('  The pair differs but is not reset->set. Write both digits');
        say('  down verbatim and read the table in this file\'s header.');
    }

    if (floors.queryAfter === '2') {
        say('');
        say('  *** READING: after ESC[?2004h was written and drained,');
        say('  *** Ghostty still reports mode 2004 as RESET.');
        say('  *** That is the lead, confirmed at its source.');
    }

    await enterFloor();

    const quietAt = Date.now() + QUIET_WINDOW_MS + 500;
    say('');
    say('Waiting out the UserPresent window before you send anything:');
    say('  a key reached this surface just now, and for the next ' +
        (QUIET_WINDOW_MS / 1000) + 's every');
    say('  Polter send is refused with UserPresent -- which is a DIFFERENT');
    say('  refusal from UnbracketedMultiline and must not be read as it.');
    const wait = Math.max(0, quietAt - Date.now());
    await new Promise((r) => setTimeout(r, wait));

    say('');
    say('=== READY. Floors: tty=' + floors.tty +
        ' wrote2004h=' + floors.wrote2004h +
        ' queryDiffers=' + floors.differs +
        ' enterBare0d=' + floors.enterIsBare0d + ' ===');
    say('Now send from Polter, one at a time, reading the hex after each:');
    say('  terminal_send(id, "abc")');
    say('  terminal_send(id, "line one\\nline two")');
    say('Look for 1b5b3230307e (ESC[200~) and 1b5b3230317e (ESC[201~).');
    say('For the multi-line send the reading is terminal_send\'s RETURN');
    say('VALUE as well -- a refusal there is a reading, not a failure.');
    say('');
    say('If DECRQM went unanswered above, that half is void but this half is');
    say('NOT: a multi-line send that comes back UnbracketedMultiline proves');
    say('the bit was false on Ghostty\'s side, with no DECRQM in the argument.');
    say('One that delivers bytes proves it was true. Read that return value');
    say('either way -- it is the independent path to the same question.');
    say('Ctrl-C when done; the mode is put back on the way out.');
    say('');
}

main().catch((err) => {
    say('probe error: ' + (err && err.stack ? err.stack : String(err)));
    finish(1);
});
