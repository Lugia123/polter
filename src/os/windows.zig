const std = @import("std");
const windows = std.os.windows;

// NOTE: The Windows part of the Zig stdlib is currently in the process of
// having most of its features removed, with the ultimate goal of switching to
// serve as a support for higher-level functionality offered in places like
// `std.Io` only. As such this file serves as a "bridge" between type
// information (mostly coming from stdlib) and manually-defined constants and
// external functions.

// Utility functions
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const GetLastError = windows.GetLastError;
pub const unexpectedError = windows.unexpectedError;
pub const unexpectedStatus = windows.unexpectedStatus;

// Primitive types
pub const BOOL = windows.BOOL;
pub const COORD = windows.COORD;
pub const DWORD = windows.DWORD;
pub const DWORD_PTR = windows.DWORD_PTR;
pub const HANDLE = windows.HANDLE;
pub const HINSTANCE = windows.HINSTANCE;
pub const HPCON = windows.LPVOID;
pub const HRESULT = c_long;
pub const LARGE_INTEGER = windows.LARGE_INTEGER;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPSTR = windows.LPSTR;
pub const LPVOID = windows.LPVOID;
pub const LPWSTR = windows.LPWSTR;
pub const PVOID = windows.PVOID;
pub const SIZE_T = windows.SIZE_T;
pub const UINT = windows.UINT;
pub const ULONG = windows.ULONG;
pub const ULONG_PTR = windows.ULONG_PTR;
pub const UNICODE_STRING = windows.UNICODE_STRING;
pub const Win32Error = windows.Win32Error;

// Structs and opaque types
pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const HLOCAL = ?*anyopaque;
pub const PSID = ?*anyopaque;
pub const PACL = ?*anyopaque;
pub const PSECURITY_DESCRIPTOR = ?*anyopaque;
pub const SECURITY_INFORMATION = DWORD;

pub const SID_AND_ATTRIBUTES = extern struct {
    Sid: PSID,
    Attributes: DWORD,
};

/// The payload `GetTokenInformation` writes for `TOKEN_INFORMATION_CLASS.User`.
/// The SID itself sits past the end of the struct, in the same buffer, which
/// is why callers pass a buffer rather than one of these.
pub const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const STARTUPINFOW = windows.STARTUPINFOW;

pub const OVERLAPPED = extern struct {
    Internal: ULONG_PTR,
    InternalHigh: ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?PVOID,
    },
    hEvent: ?HANDLE,
};
pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};
pub const STARTUPINFOEX = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
};

// Well-known constant values
pub const INFINITE = 4294967295;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const MAX_PATH = windows.MAX_PATH;
pub const FALSE: windows.BOOL = .fromBool(false);
pub const TRUE: windows.BOOL = .fromBool(true);

// Bit-field and enum constant values
pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
pub const FILE_ATTRIBUTE_NORMAL = 0x80;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
pub const FILE_FLAG_OVERLAPPED = 0x40000000;
pub const FILE_NON_DIRECTORY_FILE = 0x00000040;
pub const FILE_SHARE_READ = 0x00000001;
pub const GENERIC_READ = 0x80000000;
pub const HANDLE_FLAG_INHERIT = 0x00000001;
pub const MEM_COMMIT = 0x1000;
pub const MEM_RELEASE = 0x8000;
pub const MEM_RESERVE = 0x2000;
pub const OPEN_EXISTING = 3; // Known as FILE_OPEN in Windows docs
pub const PAGE_READWRITE = 0x04;
pub const ERROR_IO_PENDING = 997;
pub const ERROR_PIPE_BUSY = 231;
pub const ERROR_PIPE_CONNECTED = 535;
pub const GENERIC_WRITE = 0x40000000;
pub const PIPE_ACCESS_DUPLEX = 0x00000003;
pub const PIPE_ACCESS_INBOUND = 0x00000001;
pub const PIPE_UNLIMITED_INSTANCES = 255;
pub const PIPE_ACCESS_OUTBOUND = 0x00000002;
pub const PIPE_READMODE_BYTE = 0x00000000;
pub const PIPE_TYPE_BYTE = 0x00000000;
pub const PIPE_WAIT = 0x00000000;
pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;
pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
pub const S_OK = 0;
pub const WAIT_FAILED = 0xFFFFFFFF;
pub const WAIT_OBJECT_0 = 0;

// Access control, for the plugin settings file. See `Plugin.Settings.write`.
pub const DACL_SECURITY_INFORMATION: SECURITY_INFORMATION = 0x00000004;
pub const PROTECTED_DACL_SECURITY_INFORMATION: SECURITY_INFORMATION = 0x80000000;
pub const SDDL_REVISION_1 = 1;
pub const TOKEN_QUERY = 0x0008;

/// `TOKEN_INFORMATION_CLASS`, of which we only ever ask for the one.
pub const TOKEN_INFORMATION_CLASS = enum(c_int) {
    User = 1,
    _,
};

pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(
    .ProcThreadAttributePseudoConsole,
    false,
    true,
    false,
);

// Types needed for ntdll calls
pub const ACCESS_MASK = windows.ACCESS_MASK;
pub const IO_STATUS_BLOCK = windows.IO_STATUS_BLOCK;
pub const NTSTATUS = windows.NTSTATUS;
pub const OBJECT_ATTRIBUTES = windows.OBJECT.ATTRIBUTES;

// Exported functions by library
pub const exp = struct {
    pub const kernel32 = struct {
        /// The process's own command line, WTF-16, argv[0] included.
        ///
        /// **The buffer belongs to the process and must not be freed or
        /// written to.** It is what `global.zig` hands to
        /// `std.process.Args.Vector` on Windows so that `+action` arguments
        /// reach `cli.action.detectArgs`; without it that iterator is handed
        /// an empty string and every CLI action is silently inert.
        pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPWSTR;

        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *HANDLE,
            hWritePipe: *HANDLE,
            lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
            nSize: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: COORD,
            hInput: HANDLE,
            hOutput: HANDLE,
            dwFlags: DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(
            hPC: HPCON,
            size: COORD,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: DWORD,
            dwFlags: DWORD,
            lpSize: *SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: DWORD,
            Attribute: DWORD_PTR,
            lpValue: PVOID,
            cbSize: SIZE_T,
            lpPreviousValue: ?PVOID,
            lpReturnSize: ?*SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: HANDLE,
            lpBuffer: ?LPVOID,
            nBufferSize: DWORD,
            lpBytesRead: ?*DWORD,
            lpTotalBytesAvail: ?*DWORD,
            lpBytesLeftThisMessage: ?*DWORD,
        ) callconv(.winapi) BOOL;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?LPWSTR,
            lpCommandLine: ?LPWSTR,
            lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
            bInheritHandles: BOOL,
            dwCreationFlags: DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?LPWSTR,
            lpStartupInfo: *STARTUPINFOW,
            lpProcessInformation: *PROCESS_INFORMATION,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getcomputernamea
        pub extern "kernel32" fn GetComputerNameA(
            lpBuffer: LPSTR,
            nSize: *DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw
        pub extern "kernel32" fn GetTempPathW(
            nBufferLength: DWORD,
            lpBuffer: LPWSTR,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn SetHandleInformation(
            hObject: HANDLE,
            dwMask: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreateFileW(
            lpFileName: LPCWSTR,
            dwDesiredAccess: DWORD,
            dwShareMode: DWORD,
            lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
            dwCreationDisposition: DWORD,
            dwFlagsAndAttributes: DWORD,
            hTemplateFile: ?HANDLE,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CreateNamedPipeW(
            lpName: LPCWSTR,
            dwOpenMode: DWORD,
            dwPipeMode: DWORD,
            nMaxInstances: DWORD,
            nOutBufferSize: DWORD,
            nInBufferSize: DWORD,
            nDefaultTimeOut: DWORD,
            lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CreateEventW(
            lpEventAttributes: ?*SECURITY_ATTRIBUTES,
            bManualReset: BOOL,
            bInitialState: BOOL,
            lpName: ?LPCWSTR,
        ) callconv(.winapi) ?HANDLE;
        pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
        pub extern "kernel32" fn WaitForMultipleObjects(
            nCount: DWORD,
            lpHandles: [*]const HANDLE,
            bWaitAll: BOOL,
            dwMilliseconds: DWORD,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn GetOverlappedResult(
            hFile: HANDLE,
            lpOverlapped: *OVERLAPPED,
            lpNumberOfBytesTransferred: *DWORD,
            bWait: BOOL,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn WaitNamedPipeW(
            lpNamedPipeName: LPCWSTR,
            nTimeOut: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn ConnectNamedPipe(
            hNamedPipe: HANDLE,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CloseHandle(
            hObject: HANDLE,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn VirtualAlloc(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            flAllocationType: DWORD,
            flProtect: DWORD,
        ) callconv(.winapi) ?LPVOID;
        pub extern "kernel32" fn VirtualFree(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            dwFreeType: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn WaitForSingleObject(
            hHandle: HANDLE,
            dwMilliseconds: DWORD,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn GetExitCodeProcess(
            hProcess: HANDLE,
            lpExitCode: *DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn TerminateProcess(
            hProcess: HANDLE,
            uExitCode: UINT,
        ) callconv(.winapi) BOOL;
        /// Puts a named pipe instance back into the disconnected state.
        /// The Windows answer to `shutdown(SHUT_RD)`: unlike `CancelIoEx`
        /// it is sticky, so a read issued *after* it still ends at once.
        pub extern "kernel32" fn DisconnectNamedPipe(
            hNamedPipe: HANDLE,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CancelIoEx(
            hFile: HANDLE,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn ReadFile(
            hFile: HANDLE,
            lpBuffer: LPVOID,
            nNumberOfBytesToRead: DWORD,
            lpNumberOfBytesRead: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
        /// The numeric process id behind a process handle. `Child.Id` is the
        /// handle on Windows, and a handle is not what anybody wants to read
        /// in a log line.
        pub extern "kernel32" fn GetProcessId(
            Process: HANDLE,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn LocalFree(
            hMem: HLOCAL,
        ) callconv(.winapi) HLOCAL;
    };
    pub const advapi32 = struct {
        pub extern "advapi32" fn OpenProcessToken(
            ProcessHandle: HANDLE,
            DesiredAccess: DWORD,
            TokenHandle: *HANDLE,
        ) callconv(.winapi) BOOL;
        pub extern "advapi32" fn GetTokenInformation(
            TokenHandle: HANDLE,
            TokenInformationClass: TOKEN_INFORMATION_CLASS,
            TokenInformation: ?LPVOID,
            TokenInformationLength: DWORD,
            ReturnLength: *DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "advapi32" fn ConvertSidToStringSidW(
            Sid: PSID,
            StringSid: *LPWSTR,
        ) callconv(.winapi) BOOL;
        pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
            StringSecurityDescriptor: LPCWSTR,
            StringSDRevision: DWORD,
            SecurityDescriptor: *PSECURITY_DESCRIPTOR,
            SecurityDescriptorSize: ?*ULONG,
        ) callconv(.winapi) BOOL;
        pub extern "advapi32" fn SetFileSecurityW(
            lpFileName: LPCWSTR,
            SecurityInformation: SECURITY_INFORMATION,
            pSecurityDescriptor: PSECURITY_DESCRIPTOR,
        ) callconv(.winapi) BOOL;
    };
    pub const ntdll = struct {
        pub extern "ntdll" fn NtCreateFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            AllocationSize: ?*LARGE_INTEGER,
            FileAttributes: ULONG,
            ShareAccess: ULONG,
            CreateDisposition: ULONG,
            CreateOptions: ULONG,
            EaBuffer: ?*anyopaque,
            EaLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
    };
};

/// A DACL naming this user and nobody else, ready to hand to any Win32 call
/// that takes a `SECURITY_ATTRIBUTES`.
///
/// **The `P` in `D:P` is the load-bearing half.** It marks the DACL
/// *protected*: without it the entries the parent object hands down are
/// kept, and not inheriting them is the whole point. `rights` is the SDDL
/// rights string -- `"FA"` for a file, `"GA"` for a kernel object such as a
/// pipe.
///
/// Lives here rather than beside either caller because it is one security
/// decision, and a second copy of it is a second place for it to drift.
pub const OwnerOnly = struct {
    sd: PSECURITY_DESCRIPTOR,

    pub fn deinit(self: OwnerOnly) void {
        _ = exp.kernel32.LocalFree(self.sd);
    }

    /// A `SECURITY_ATTRIBUTES` pointing at it. Borrowed: it must not outlive
    /// the `OwnerOnly` it came from.
    pub fn attributes(self: *const OwnerOnly) SECURITY_ATTRIBUTES {
        return .{
            .nLength = @sizeOf(SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = self.sd,
            .bInheritHandle = FALSE,
        };
    }
};

/// Build one, or say which call failed.
///
/// The error code is carried out of the block rather than asked for after
/// it: `break` evaluates its operand *before* the scope unwinds, while
/// `GetLastError` reads a per-thread slot that the `defer`s here --
/// `CloseHandle`, `LocalFree` -- overwrite on their way out. Asking
/// afterwards reports whichever cleanup ran last, very often `0`, which
/// reads as "nothing went wrong" in the one value whose job is to say what
/// did. A plausible wrong answer is worse than no answer.
pub fn ownerOnly(
    alloc: std.mem.Allocator,
    comptime rights: []const u8,
) error{Win32}!OwnerOnly {
    const advapi32 = exp.advapi32;

    const err: Win32Error = failed: {
        var token: HANDLE = undefined;
        if (advapi32.OpenProcessToken(
            exp.kernel32.GetCurrentProcess(),
            TOKEN_QUERY,
            &token,
        ) == FALSE) break :failed GetLastError();
        defer _ = exp.kernel32.CloseHandle(token);

        // `TOKEN_USER` is a header; the SID it points at lives past the end
        // of it in the same buffer. A SID is at most 68 bytes, so one
        // buffer with room to spare is simpler than the two-call sizing
        // dance and cannot come up short.
        var buf: [256]u8 align(@alignOf(TOKEN_USER)) = undefined;
        var len: DWORD = 0;
        if (advapi32.GetTokenInformation(
            token,
            .User,
            &buf,
            buf.len,
            &len,
        ) == FALSE) break :failed GetLastError();
        const user: *const TOKEN_USER = @ptrCast(&buf);

        var sid_str: LPWSTR = undefined;
        if (advapi32.ConvertSidToStringSidW(
            user.User.Sid,
            &sid_str,
        ) == FALSE) break :failed GetLastError();
        defer _ = exp.kernel32.LocalFree(sid_str);

        // Built as SDDL rather than by hand: an ACL assembled out of
        // `InitializeAcl`/`AddAccessAllowedAce` is a dozen more calls and a
        // dozen more ways to get a byte count wrong, for a string the
        // system parses the same either way.
        const sid_len = std.mem.len(sid_str);
        const sddl = std.fmt.allocPrintSentinel(
            alloc,
            "D:P(A;;" ++ rights ++ ";;;{f})",
            .{std.unicode.fmtUtf16Le(sid_str[0..sid_len])},
            0,
        ) catch break :failed GetLastError();
        defer alloc.free(sddl);

        const sddl_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, sddl) catch
            break :failed GetLastError();
        defer alloc.free(sddl_w);

        var sd: PSECURITY_DESCRIPTOR = undefined;
        if (advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl_w,
            SDDL_REVISION_1,
            &sd,
            null,
        ) == FALSE) break :failed GetLastError();

        return .{ .sd = sd };
    };

    lastError = err;
    return error.Win32;
}

/// What the most recent `ownerOnly` failure was, for the caller's log line.
/// Not thread safe and does not need to be: it is read immediately after the
/// error, and a wrong code in a warning is not worth a lock.
pub var lastError: Win32Error = .SUCCESS;

pub const ProcThreadAttributeNumber = enum(DWORD) {
    ProcThreadAttributePseudoConsole = 22,
    _,
};

/// Corresponds to the ProcThreadAttributeValue define in WinBase.h
pub fn ProcThreadAttributeValue(
    comptime attribute: ProcThreadAttributeNumber,
    comptime thread: bool,
    comptime input: bool,
    comptime additive: bool,
) DWORD {
    return (@intFromEnum(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
        (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
        (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
        (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
}
