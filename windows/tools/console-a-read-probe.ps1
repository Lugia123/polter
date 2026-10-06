<#
.SYNOPSIS
  Does this console hand U+00D7 and U+2460 to a program reading bytes, or NUL?

.DESCRIPTION
  Task 1091. Pasting text with a multiplication sign or a circled digit into a
  Polter pane on a code page 936 machine reached the console program as
  U+0000, while Chinese characters arrived intact.

  Nothing on Polter's side of the pipe transcodes: the host turns
  CF_UNICODETEXT into UTF-8, the core writes those bytes to the ConPTY input
  pipe. What turns them into the bytes a program reads with `ReadFile` is the
  console host. So this takes Polter's paste path out of the reading
  altogether: it puts KEY_EVENT records carrying the characters straight into
  its own console's input buffer (`WriteConsoleInputW`) and reads them back
  four ways -- `ReadConsoleW`, `ReadFile` in line mode, `ReadFile` in raw
  mode, and `ReadConsoleInputA`.

  The text is a, U+00D7, U+2460, U+4E2D, b. In code page 936 a healthy byte
  read is `61 A1 C1 A2 D9 D6 D0 62` and a healthy wide read is
  `0061 00D7 2460 4E2D 0062`.

  **What the outcome means.** The wide read correct and a byte read with 00
  where A1 C1 / A2 D9 belong: the console host does it, with no paste and no
  terminal's input path involved. Not Polter's.

  **What it read on the test machine** (Server 2022, build 20348, code page
  936; issue #66 of this repository): in a Polter pane, which is a ConPTY, `ReadFile`
  gave `61 00 00 D6 D0 62` in both modes while `ReadConsoleW` and
  `ReadConsoleInputA` were right; in a plain `conhost.exe` window all four
  were right.

  There was a second mode that waited for a real paste. It returned at once
  on the machine, in both kinds of console, without waiting for anything, and
  was taken out rather than left to give a reading that means nothing.

.PARAMETER Out
  Also write the readings to this file. Use it: the script echoes input, and a
  transcript scraped off the screen is harder to read than a file.

.NOTES
  Windows PowerShell 5.1 or PowerShell 7. **This file is ASCII on purpose** --
  5.1 reads a script without a BOM in the system code page, which is the very
  thing being measured.

  Run it *in the console being asked about*: in a Polter pane, and for a
  comparison in a plain `conhost.exe` window. It opens `CONIN$` itself, so a
  redirected stdin does not matter, but a process with no console at all
  (a service, a remote exec) has nothing to measure and says so.
#>
param(
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class ConsoleARead
{
    // INPUT_RECORD holding a KEY_EVENT_RECORD. 20 bytes.
    [StructLayout(LayoutKind.Explicit, Size = 20)]
    public struct IR
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public int KeyDown;
        [FieldOffset(8)] public ushort Repeat;
        [FieldOffset(10)] public ushort Vk;
        [FieldOffset(12)] public ushort Scan;
        [FieldOffset(14)] public ushort Char;
        [FieldOffset(16)] public uint Control;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteConsoleInputW(IntPtr h, [In] IR[] buf, uint n, out uint written);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadConsoleInputA(IntPtr h, [Out] IR[] buf, uint n, out uint read);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, [Out] byte[] buf, uint n, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadConsoleW(IntPtr h, [Out] ushort[] buf, uint n, out uint read, IntPtr ctl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FlushConsoleInputBuffer(IntPtr h);
    [DllImport("kernel32.dll")]
    public static extern uint GetConsoleCP();
    [DllImport("kernel32.dll")]
    public static extern uint GetConsoleOutputCP();

    const uint LINE = 0x7; // PROCESSED_INPUT | LINE_INPUT | ECHO_INPUT
    const uint RAW = 0x0;

    static IntPtr h = IntPtr.Zero;
    static uint saved = 0;

    public static void Open()
    {
        // GENERIC_READ | GENERIC_WRITE, share read+write, OPEN_EXISTING
        h = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == IntPtr.Zero || h == new IntPtr(-1))
            throw new Exception("CONIN$ could not be opened (error " + Marshal.GetLastWin32Error() + "): this process has no console, so there is nothing to measure");
        if (!GetConsoleMode(h, out saved))
            throw new Exception("GetConsoleMode failed: " + Marshal.GetLastWin32Error());
    }

    public static void Close()
    {
        if (h != IntPtr.Zero) SetConsoleMode(h, saved);
    }

    static void Check(bool ok, string what)
    {
        if (!ok) throw new Exception(what + " failed: " + Marshal.GetLastWin32Error());
    }

    static void Prepare(uint mode)
    {
        Check(SetConsoleMode(h, mode), "SetConsoleMode");
        Check(FlushConsoleInputBuffer(h), "FlushConsoleInputBuffer");
    }

    static void Inject(string s)
    {
        IR[] recs = new IR[s.Length * 2];
        for (int i = 0; i < s.Length; i++)
        {
            for (int k = 0; k < 2; k++)
            {
                IR r = new IR();
                r.EventType = 1; // KEY_EVENT
                r.KeyDown = (k == 0) ? 1 : 0;
                r.Repeat = 1;
                r.Vk = (ushort)(s[i] == '\r' ? 0x0D : 0);
                r.Char = s[i];
                recs[i * 2 + k] = r;
            }
        }
        uint w;
        Check(WriteConsoleInputW(h, recs, (uint)recs.Length, out w), "WriteConsoleInputW");
        if (w != recs.Length) throw new Exception("WriteConsoleInputW wrote " + w + " of " + recs.Length);
    }

    static string Hex(byte[] b, int n)
    {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < n; i++) { if (i > 0) sb.Append(' '); sb.Append(b[i].ToString("X2")); }
        return sb.ToString();
    }

    static string Hex(ushort[] b, int n)
    {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < n; i++) { if (i > 0) sb.Append(' '); sb.Append(b[i].ToString("X4")); }
        return sb.ToString();
    }

    // One ReadFile in line mode: returns when the line's Enter arrives.
    public static string LineBytes(string inject)
    {
        Prepare(LINE);
        Inject(inject + "\r");
        byte[] buf = new byte[512];
        uint n;
        Check(ReadFile(h, buf, (uint)buf.Length, out n, IntPtr.Zero), "ReadFile");
        return Hex(buf, (int)n);
    }

    // ReadFile in raw mode, repeated until the carriage return shows up.
    public static string RawBytes(string inject)
    {
        Prepare(RAW);
        Inject(inject + "\r");
        List<byte> all = new List<byte>();
        byte[] buf = new byte[64];
        for (int round = 0; round < 64 && !all.Contains(0x0D); round++)
        {
            uint n;
            Check(ReadFile(h, buf, (uint)buf.Length, out n, IntPtr.Zero), "ReadFile");
            for (int i = 0; i < n; i++) all.Add(buf[i]);
        }
        return Hex(all.ToArray(), all.Count);
    }

    // ReadConsoleInputA: the AsciiChar of each key-down, until the Enter.
    public static string InputA(string inject)
    {
        Prepare(RAW);
        Inject(inject + "\r");
        List<byte> all = new List<byte>();
        IR[] one = new IR[1];
        for (int round = 0; round < 256; round++)
        {
            uint n;
            Check(ReadConsoleInputA(h, one, 1, out n), "ReadConsoleInputA");
            if (n == 0 || one[0].EventType != 1 || one[0].KeyDown == 0) continue;
            byte c = (byte)(one[0].Char & 0xFF);
            all.Add(c);
            if (c == 0x0D) break;
        }
        return Hex(all.ToArray(), all.Count);
    }

    public static string LineWide(string inject)
    {
        Prepare(LINE);
        Inject(inject + "\r");
        ushort[] buf = new ushort[512];
        uint n;
        Check(ReadConsoleW(h, buf, (uint)buf.Length, out n, IntPtr.Zero), "ReadConsoleW");
        return Hex(buf, (int)n);
    }
}
'@

$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) {
    $lines.Add($s)
    Write-Host $s
}

# a, U+00D7, U+2460, U+4E2D, b -- built from numbers so this file stays ASCII.
$text = -join ([char]0x61, [char]0xD7, [char]0x2460, [char]0x4E2D, [char]0x62)

$os = [Environment]::OSVersion.Version
$ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR
Say ("probe 1091 mode=inject os={0}.{1}.{2}.{3} inputCP={4} outputCP={5} ps={6}" -f `
        $os.Major, $os.Minor, $os.Build, $ubr,
    [ConsoleARead]::GetConsoleCP(), [ConsoleARead]::GetConsoleOutputCP(), $PSVersionTable.PSVersion)
Say ("expect  wide  0061 00D7 2460 4E2D 0062   bytes(936)  61 A1 C1 A2 D9 D6 D0 62")

[ConsoleARead]::Open()
try {
    Say ("ReadConsoleW       line : " + [ConsoleARead]::LineWide($text))
    Say ("ReadFile           line : " + [ConsoleARead]::LineBytes($text))
    Say ("ReadFile           raw  : " + [ConsoleARead]::RawBytes($text))
    Say ("ReadConsoleInputA  raw  : " + [ConsoleARead]::InputA($text))
}
finally {
    [ConsoleARead]::Close()
}

if ($Out -ne '') {
    [System.IO.File]::WriteAllLines($Out, $lines, (New-Object System.Text.ASCIIEncoding))
    Write-Host "written: $Out"
}
