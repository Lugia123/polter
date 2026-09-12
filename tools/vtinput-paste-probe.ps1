<#
.SYNOPSIS
  Does Ghostty's bracketed-paste frame survive ConPTY when the reading
  process sets ENABLE_VIRTUAL_TERMINAL_INPUT?

.DESCRIPTION
  WHY THIS EXISTS -- THE INSTRUMENT WAS THE SUSPECT
  =================================================
  Three earlier readings said `terminal_send` arrives at a Windows child
  without `ESC[200~` / `ESC[201~`. All three were taken with a node probe.
  conhost's handling of an input-direction CSI depends on the child's CONIN
  mode: with ENABLE_VIRTUAL_TERMINAL_INPUT set it is passed through, without
  it the sequence is looked up in a small generic map (which does not contain
  200~/201~) and otherwise DISCARDED. node's raw stdin on Windows goes through
  libuv's tty layer and may well not set that bit.

  So "no frame" may have been the probe's own blind spot rather than the
  product's behaviour. This probe removes that variable by BEING the kind of
  host an agent CLI is: it sets the bit itself, verifies it is set by reading
  the mode back, and then reads raw bytes.

  It also carries its own positive control (see #vt0 / #vt1 below), so the
  discard path and the pass-through path can be compared IN ONE PROCESS
  against ONE Ghostty surface, with one variable changed.

  THE CRITERION
  =============
  With the bit verified set, send three lines at this terminal from Polter:

      terminal_send(id, "line 1\nline 2\nline 3")

  and look in the hex for:

      1b5b3230307e   = ESC[200~     (frame opens)
      1b5b3230317e   = ESC[201~     (frame closes)

    * FRAME PRESENT -> the product does frame it and ConPTY does forward it.
      Every earlier "no frame" reading was instrument blindness. The defect
      is somewhere else and the ConPTY-eats-the-frame theory is dead.

    * FRAME ABSENT -> *this* is a product reading, because the host now
      matches the real target's class. The frame really is lost.

  THE POSITIVE CONTROL (do not skip -- "absent" alone proves little)
  =================================================================
  "Absent" is only worth something if this probe can be shown to produce
  "present" under some condition, or to lose it when the bit is cleared.
  Send these as ordinary text to flip the bit mid-session:

      terminal_send(id, "#vt0")   -> clears ENABLE_VIRTUAL_TERMINAL_INPUT
      terminal_send(id, "#vt1")   -> sets it again
      terminal_send(id, "#quit")  -> restore everything and exit

  Each flip logs the mode READ BACK, not the value asked for. The A/B to run:

      1. three lines            (bit ON  -- cell A)
      2. #vt0                   (flip)
      3. three lines            (bit OFF -- cell B)
      4. #vt1                   (flip back)

  Readings:
      A has the frame, B does not  -> W1's mechanism is confirmed, in one
                                      session, with one variable changed.
      A and B both lack the frame  -> the bit is not what decides it. The
                                      earlier readings stand and the cause is
                                      upstream of CONIN mode.
      A and B both have the frame  -> the flip did not take effect (check the
                                      read-back lines) or something else moved.
      A lacks it, B has it         -> nothing here predicts this; write both
                                      hex lines down verbatim before theorising.

  THE FLOORS
  ==========
  FLOOR 0 -- the mode bit is actually set.
    SetConsoleMode's return value is NOT the evidence. The mode is read back
    with GetConsoleMode and compared bit by bit; the run refuses to go on if
    the read-back disagrees.

  FLOOR A -- the DECRQM channel is alive AND can change its answer.
    Mode 2004 is queried three times: once to learn the state on arrival (so
    it can be put back), then after an explicit `ESC[?2004l`, then after
    `ESC[?2004h`. The floor is that the last two DIFFER.
    *** The explicit reset is deliberate: the state on arrival is NOT
    reliably "reset", so a plain before/after pair can come back 1/1 and look
    like a broken query. Forcing the low edge first makes the pair
    constructed rather than hoped for.

  FLOOR B -- the bytes left this process.
    Every write checks that WriteFile reported the full length written.

  FLOOR C -- line discipline is off.
    ENABLE_LINE_INPUT and ENABLE_ECHO_INPUT are cleared and verified in the
    same read-back as FLOOR 0. With ENABLE_LINE_INPUT set, nothing would
    arrive until a return was pressed, so bytes arriving at all is a second,
    independent sign.

  ON EXIT
  =======
  Console input and output modes are restored to exactly what they were, and
  mode 2004 is put back to whatever the FIRST query said -- not switched off,
  which would turn off a mode the terminal already had on.

  There is also a hard time limit (-Seconds, default 600) so this can never
  strand a terminal if nobody sends #quit.

.PARAMETER LogPath
  File to append the readings to. Defaults to vtinput-probe.log in the
  current directory.

.PARAMETER Seconds
  Hard time limit. The probe restores and exits when it expires.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File vtinput-paste-probe.ps1

.NOTES
  Run it in the terminal under test, not through a pipe: with stdin
  redirected there is no console handle and the probe stops with a FLOOR
  failure rather than measuring something else.
#>

[CmdletBinding()]
param(
    [string] $LogPath = (Join-Path (Get-Location) 'vtinput-probe.log'),
    [int]    $Seconds = 600
)

$ErrorActionPreference = 'Stop'

$csharp = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class VtInputPasteProbe
{
    const int STD_INPUT_HANDLE  = -10;
    const int STD_OUTPUT_HANDLE = -11;

    const uint ENABLE_PROCESSED_INPUT           = 0x0001;
    const uint ENABLE_LINE_INPUT                = 0x0002;
    const uint ENABLE_ECHO_INPUT                = 0x0004;
    const uint ENABLE_WINDOW_INPUT              = 0x0008;
    const uint ENABLE_MOUSE_INPUT               = 0x0010;
    const uint ENABLE_VIRTUAL_TERMINAL_INPUT    = 0x0200;

    const uint ENABLE_PROCESSED_OUTPUT          = 0x0001;
    const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

    const uint WAIT_OBJECT_0 = 0;
    const uint WAIT_TIMEOUT  = 258;

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToRead,
                                out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToWrite,
                                 out uint lpNumberOfBytesWritten, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    static StreamWriter _log;
    static Stopwatch _clock;
    static IntPtr _hIn;
    static IntPtr _hOut;
    static int _seq;

    // Everything read so far, as latin1 characters, so the DECRPM reply can
    // be found across a read boundary. Trimmed so it cannot grow without end.
    static StringBuilder _acc = new StringBuilder();

    static void Say(string s)
    {
        string line = "[" + _clock.Elapsed.TotalMilliseconds.ToString("0.000").PadLeft(11) + "] " + s;
        _log.WriteLine(line);
        WriteOut(Encoding.ASCII.GetBytes(line + "\r\n"), false);
    }

    static bool WriteOut(byte[] bytes, bool checkFloor)
    {
        uint written;
        bool ok = WriteFile(_hOut, bytes, (uint)bytes.Length, out written, IntPtr.Zero);
        if (checkFloor)
        {
            if (!ok || written != (uint)bytes.Length)
            {
                Say("FLOOR B: FAIL -- wrote " + written + " of " + bytes.Length +
                    " bytes, WriteFile ok=" + ok + " err=" + Marshal.GetLastWin32Error());
                return false;
            }
            Say("FLOOR B: wrote " + bytes.Length + " bytes, WriteFile reported all of them");
        }
        return ok;
    }

    static string Hex(byte[] buf, int len)
    {
        StringBuilder sb = new StringBuilder(len * 2);
        for (int i = 0; i < len; i++) sb.Append(buf[i].ToString("x2"));
        return sb.ToString();
    }

    static string ModeBits(uint m)
    {
        List<string> on = new List<string>();
        if ((m & ENABLE_PROCESSED_INPUT) != 0) on.Add("PROCESSED_INPUT");
        if ((m & ENABLE_LINE_INPUT) != 0) on.Add("LINE_INPUT");
        if ((m & ENABLE_ECHO_INPUT) != 0) on.Add("ECHO_INPUT");
        if ((m & ENABLE_WINDOW_INPUT) != 0) on.Add("WINDOW_INPUT");
        if ((m & ENABLE_MOUSE_INPUT) != 0) on.Add("MOUSE_INPUT");
        if ((m & ENABLE_VIRTUAL_TERMINAL_INPUT) != 0) on.Add("VIRTUAL_TERMINAL_INPUT");
        return "0x" + m.ToString("x4") + " [" + string.Join(" ", on.ToArray()) + "]";
    }

    // Read one chunk with a timeout. Returns bytes read, 0 on timeout, -1 on error.
    static int ReadChunk(byte[] buf, uint timeoutMs)
    {
        uint w = WaitForSingleObject(_hIn, timeoutMs);
        if (w == WAIT_TIMEOUT) return 0;
        if (w != WAIT_OBJECT_0) return -1;

        uint read;
        if (!ReadFile(_hIn, buf, (uint)buf.Length, out read, IntPtr.Zero)) return -1;
        if (read == 0) return 0;

        _seq++;
        string hex = Hex(buf, (int)read);
        string line = "#" + _seq.ToString("000") +
                      " t=+" + _clock.Elapsed.TotalMilliseconds.ToString("0.000") + "ms" +
                      " len=" + read + " hex=" + hex;
        _log.WriteLine(line);
        WriteOut(Encoding.ASCII.GetBytes(line + "\r\n"), false);

        for (int i = 0; i < (int)read; i++) _acc.Append((char)buf[i]);
        if (_acc.Length > 8192) _acc.Remove(0, _acc.Length - 4096);

        return (int)read;
    }

    // Ask DECRQM for mode 2004 and wait for the DECRPM reply.
    // Returns the state digit as a char, or '\0' if no reply arrived.
    static char QueryMode2004(string label, uint timeoutMs)
    {
        int start = _acc.Length;
        byte[] q = Encoding.ASCII.GetBytes("\x1b[?2004$p");
        if (!WriteOut(q, true)) return '\0';

        byte[] buf = new byte[4096];
        long deadline = _clock.ElapsedMilliseconds + timeoutMs;
        while (_clock.ElapsedMilliseconds < deadline)
        {
            uint slice = (uint)Math.Max(1, deadline - _clock.ElapsedMilliseconds);
            int n = ReadChunk(buf, slice);
            if (n < 0) break;

            // _acc is trimmed when it grows, which shifts every index into it.
            // Clamping here rather than trusting `start` -- a stale index would
            // be an ArgumentOutOfRangeException on the test machine, and a probe
            // that crashes mid-run looks like a probe that read nothing.
            int from = Math.Max(0, Math.Min(start - 16, _acc.Length));
            string hay = _acc.ToString(from, _acc.Length - from);
            int idx = hay.IndexOf("\x1b[?2004;");
            if (idx >= 0 && hay.Length >= idx + 11)
            {
                char digit = hay[idx + 8];
                if (hay.Substring(idx + 9, 2) == "$y")
                {
                    Say("FLOOR A " + label + ": ESC[?2004;" + digit + "$y" +
                        "   (0=not_recognized 1=set 2=reset 3=perm_set 4=perm_reset)");
                    return digit;
                }
            }
        }

        Say("FLOOR A " + label + ": NO REPLY within " + timeoutMs + "ms");
        Say("  ^ this is NOT 'reset'. It means the reply channel was never shown");
        Say("    to work, so nothing measured after it is usable.");
        return '\0';
    }

    static bool SetAndVerifyInputMode(uint desired, string label)
    {
        SetConsoleMode(_hIn, desired);
        uint back;
        if (!GetConsoleMode(_hIn, out back))
        {
            Say("FLOOR 0 " + label + ": FAIL -- GetConsoleMode read-back failed err=" +
                Marshal.GetLastWin32Error());
            return false;
        }
        Say("FLOOR 0 " + label + ": asked  " + ModeBits(desired));
        Say("FLOOR 0 " + label + ": got    " + ModeBits(back));
        if (back != desired)
        {
            Say("FLOOR 0 " + label + ": READ-BACK DISAGREES. SetConsoleMode's return value is");
            Say("  not the evidence and this is why. Differing bits: 0x" +
                (back ^ desired).ToString("x4"));
            return false;
        }
        Say("FLOOR 0 " + label + ": PASS -- read-back matches, VIRTUAL_TERMINAL_INPUT=" +
            (((back & ENABLE_VIRTUAL_TERMINAL_INPUT) != 0) ? "ON" : "OFF"));
        return true;
    }

    public static int Run(string logPath, int seconds)
    {
        _clock = Stopwatch.StartNew();
        _log = new StreamWriter(logPath, false, new UTF8Encoding(false));
        _log.AutoFlush = true;

        _hIn = GetStdHandle(STD_INPUT_HANDLE);
        _hOut = GetStdHandle(STD_OUTPUT_HANDLE);

        uint inOrig, outOrig;
        if (!GetConsoleMode(_hIn, out inOrig))
        {
            _log.WriteLine("FLOOR 0: FAIL -- no console input handle (err=" +
                           Marshal.GetLastWin32Error() + "). stdin is redirected, or this is " +
                           "not running in a console. Nothing measured here would be about " +
                           "the product.");
            _log.Flush();
            return 2;
        }
        if (!GetConsoleMode(_hOut, out outOrig))
        {
            _log.WriteLine("FLOOR 0: FAIL -- no console output handle (err=" +
                           Marshal.GetLastWin32Error() + ").");
            _log.Flush();
            return 2;
        }

        char state0 = '\0';
        uint inDesired = 0;

        try
        {
            Say("vtinput-paste-probe  pid=" + Process.GetCurrentProcess().Id +
                "  clr=" + Environment.Version);
            Say("console input  mode on arrival: " + ModeBits(inOrig));
            Say("console output mode on arrival: 0x" + outOrig.ToString("x4"));

            // Output side: the probe writes VT (DECRQM, mode sets) and needs
            // conhost to treat it as VT rather than as text to print.
            uint outDesired = outOrig | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            SetConsoleMode(_hOut, outDesired);
            uint outBack;
            GetConsoleMode(_hOut, out outBack);
            Say("console output mode now: 0x" + outBack.ToString("x4") +
                "  VIRTUAL_TERMINAL_PROCESSING=" +
                (((outBack & ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0) ? "ON" : "OFF"));

            // Input side. This is the whole point of the probe: be the kind of
            // host an agent CLI is.
            inDesired = (inOrig & ~(ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT |
                                    ENABLE_ECHO_INPUT | ENABLE_WINDOW_INPUT |
                                    ENABLE_MOUSE_INPUT))
                        | ENABLE_VIRTUAL_TERMINAL_INPUT;
            if (!SetAndVerifyInputMode(inDesired, "input(vt on)"))
            {
                Say("Stopping: without the bit verified set, 'no frame' would mean nothing.");
                return 3;
            }
            Say("FLOOR C: LINE_INPUT and ECHO_INPUT are clear in the read-back above.");

            // FLOOR A. Three queries, and the middle one is forced low on
            // purpose so the pair that forms the floor is constructed.
            state0 = QueryMode2004("on arrival", 2000);
            WriteOut(Encoding.ASCII.GetBytes("\x1b[?2004l"), true);
            char stateLow = QueryMode2004("after 2004l", 2000);
            WriteOut(Encoding.ASCII.GetBytes("\x1b[?2004h"), true);
            char stateHigh = QueryMode2004("after 2004h", 2000);

            Say("FLOOR A verdict: arrival=" + (state0 == '\0' ? "none" : state0.ToString()) +
                " low=" + (stateLow == '\0' ? "none" : stateLow.ToString()) +
                " high=" + (stateHigh == '\0' ? "none" : stateHigh.ToString()));
            if (stateLow == '\0' || stateHigh == '\0')
            {
                Say("  NOT ESTABLISHED: a query went unanswered. Run void.");
            }
            else if (stateLow == stateHigh)
            {
                Say("  FAIL: the forced-low and forced-high answers are IDENTICAL.");
                Say("  A query that cannot change its answer cannot report a change.");
                Say("  Run void -- do not read anything below as evidence about the product.");
            }
            else if (stateLow == '2' && stateHigh == '1')
            {
                Say("  PASS: reset -> set. Ghostty records mode 2004 and answers about it.");
            }
            else
            {
                Say("  The pair differs but is not reset->set. Write both digits down");
                Say("  verbatim before reading anything below.");
            }

            Say("");
            Say("=== READY ===");
            Say("Send from Polter and read the hex after each:");
            Say("  terminal_send(id, \"line 1\\nline 2\\nline 3\")   <- cell A, bit ON");
            Say("  terminal_send(id, \"#vt0\")                      <- clear the bit");
            Say("  terminal_send(id, \"line 1\\nline 2\\nline 3\")   <- cell B, bit OFF");
            Say("  terminal_send(id, \"#vt1\")                      <- set it again");
            Say("  terminal_send(id, \"#quit\")                     <- restore and exit");
            Say("Look for 1b5b3230307e (ESC[200~) and 1b5b3230317e (ESC[201~).");
            Say("Time limit: " + seconds + "s, after which this restores and exits by itself.");
            Say("");

            byte[] buf = new byte[4096];
            long deadline = _clock.ElapsedMilliseconds + (long)seconds * 1000L;
            int cmdFrom = _acc.Length;

            while (_clock.ElapsedMilliseconds < deadline)
            {
                int n = ReadChunk(buf, 500);
                if (n < 0) { Say("read error err=" + Marshal.GetLastWin32Error()); break; }
                if (n == 0) continue;

                bool ctrlC = false;
                for (int i = 0; i < n; i++) if (buf[i] == 0x03) ctrlC = true;
                if (ctrlC) { Say("0x03 (ctrl-c) seen -- restoring and exiting"); break; }

                if (cmdFrom > _acc.Length) cmdFrom = _acc.Length;   // _acc may have been trimmed
                string tail = _acc.ToString(cmdFrom, _acc.Length - cmdFrom);
                if (tail.IndexOf("#quit") >= 0)
                {
                    Say("#quit seen -- restoring and exiting");
                    break;
                }
                if (tail.IndexOf("#vt0") >= 0)
                {
                    Say("#vt0 seen -- clearing ENABLE_VIRTUAL_TERMINAL_INPUT");
                    SetAndVerifyInputMode(inDesired & ~ENABLE_VIRTUAL_TERMINAL_INPUT, "input(vt off)");
                    cmdFrom = _acc.Length;
                }
                else if (tail.IndexOf("#vt1") >= 0)
                {
                    Say("#vt1 seen -- setting ENABLE_VIRTUAL_TERMINAL_INPUT");
                    SetAndVerifyInputMode(inDesired, "input(vt on)");
                    cmdFrom = _acc.Length;
                }
                else if (tail.Length > 2048)
                {
                    cmdFrom = _acc.Length;
                }
            }

            if (_clock.ElapsedMilliseconds >= deadline) Say("time limit reached -- restoring and exiting");
        }
        finally
        {
            // Mode 2004 back to what it was on arrival, which is not the same
            // as switching it off.
            if (state0 == '1' || state0 == '3') WriteOut(Encoding.ASCII.GetBytes("\x1b[?2004h"), false);
            else if (state0 != '\0') WriteOut(Encoding.ASCII.GetBytes("\x1b[?2004l"), false);

            SetConsoleMode(_hIn, inOrig);
            SetConsoleMode(_hOut, outOrig);

            uint inBack, outBack2;
            GetConsoleMode(_hIn, out inBack);
            GetConsoleMode(_hOut, out outBack2);
            Say("restored: input " + ModeBits(inBack) + " (was " + ModeBits(inOrig) + ")");
            Say("restored: output 0x" + outBack2.ToString("x4") + " (was 0x" + outOrig.ToString("x4") + ")");
            _log.Flush();
            _log.Close();
        }

        return 0;
    }
}
'@

Add-Type -TypeDefinition $csharp -Language CSharp

Write-Host "vtinput-paste-probe: log -> $LogPath"
$code = [VtInputPasteProbe]::Run($LogPath, $Seconds)
Write-Host "vtinput-paste-probe: exit $code"
exit $code
