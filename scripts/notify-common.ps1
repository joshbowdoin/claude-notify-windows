# Shared Win32 helpers for the Claude Code notification hooks.
# Dot-source this from notify.ps1, notify-record.ps1 and notify-activate.ps1.

$script:NotifyStateDir = Join-Path $PSScriptRoot 'notify-state'

Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class CcWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();

    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    [DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    public static uint PidOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }

    public static string TitleOf(IntPtr h) {
        int n = GetWindowTextLength(h);
        if (n <= 0) return "";
        var sb = new StringBuilder(n + 1);
        GetWindowText(h, sb, n + 1);
        return sb.ToString();
    }

    // Visible top-level windows with a title belonging to the given process id.
    public static List<IntPtr> WindowsOfPid(uint pid) {
        var r = new List<IntPtr>();
        EnumWindows((h, l) => {
            if (PidOf(h) == pid && IsWindowVisible(h) && GetWindowTextLength(h) > 0) r.Add(h);
            return true;
        }, IntPtr.Zero);
        return r;
    }

    // Flash taskbar button + caption until the window gets focus.
    public static void Flash(IntPtr h) {
        FLASHWINFO f = new FLASHWINFO();
        f.cbSize = (uint)Marshal.SizeOf(f); f.hwnd = h;
        f.dwFlags = 0x3 | 0xC; // FLASHW_ALL | FLASHW_TIMERNOFG
        f.uCount = 0; f.dwTimeout = 0;
        FlashWindowEx(ref f);
    }

    // Bring a window to the foreground, working around the foreground-lock rules.
    public static bool Activate(IntPtr h) {
        if (!IsWindow(h)) return false;
        if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE
        SetForegroundWindow(h);
        if (GetForegroundWindow() == h) return true;

        // Fallback 1: attach to the current foreground thread's input queue.
        IntPtr fg = GetForegroundWindow();
        uint fgPid; uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
        uint me = GetCurrentThreadId();
        if (fgThread != 0 && fgThread != me) AttachThreadInput(me, fgThread, true);
        BringWindowToTop(h);
        SetForegroundWindow(h);
        if (fgThread != 0 && fgThread != me) AttachThreadInput(me, fgThread, false);
        if (GetForegroundWindow() == h) return true;

        // Fallback 2: simulate an ALT key press, which grants foreground rights.
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        SetForegroundWindow(h);
        return GetForegroundWindow() == h;
    }
}

// Windows 10/11 virtual desktop query API (documented, stable COM interface).
[ComImport, Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVirtualDesktopManager {
    [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow, out bool onCurrentDesktop);
    [PreserveSig] int GetWindowDesktopId(IntPtr topLevelWindow, out Guid desktopId);
    [PreserveSig] int MoveWindowToDesktop(IntPtr topLevelWindow, ref Guid desktopId);
}

[ComImport, Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a")]
public class VirtualDesktopManagerClass { }

public static class CcDesktop {
    static IVirtualDesktopManager Mgr() { return (IVirtualDesktopManager)new VirtualDesktopManagerClass(); }

    public static bool IsOnCurrent(IntPtr h) {
        try { bool on; if (Mgr().IsWindowOnCurrentVirtualDesktop(h, out on) == 0) return on; } catch { }
        return true; // if the API is unavailable, assume yes
    }

    // Move the window onto the desktop that `reference` lives on (normally the current one).
    public static bool MoveToDesktopOf(IntPtr h, IntPtr reference) {
        try {
            Guid id;
            var m = Mgr();
            if (m.GetWindowDesktopId(reference, out id) != 0 || id == Guid.Empty) return false;
            return m.MoveWindowToDesktop(h, ref id) == 0;
        } catch { return false; }
    }
}
'@

# Parse the JSON hook payload. Callers pass ($input | Out-String), because powershell.exe
# delivers piped stdin to a -File script through $input, not through [Console]::In.
function Read-HookPayload([string]$Raw) {
    try {
        if ($Raw -and $Raw.Trim()) { return ($Raw | ConvertFrom-Json -ErrorAction Stop) }
    } catch { }
    return $null
}

function Get-StateFile([string]$SessionId) {
    if (-not $SessionId) { return $null }
    $safe = ($SessionId -replace '[^A-Za-z0-9\-_]', '_')
    return Join-Path $script:NotifyStateDir "$safe.hwnd"
}

# The VS Code window recorded for this session, validated to still be a live Code.exe window.
function Get-RecordedWindow([string]$SessionId) {
    $f = Get-StateFile $SessionId
    if (-not $f -or -not (Test-Path $f)) { return [IntPtr]::Zero }
    try {
        $h = [IntPtr][long](Get-Content $f -Raw).Trim()
        if (-not [CcWin]::IsWindow($h)) { return [IntPtr]::Zero }
        $p = Get-Process -Id ([CcWin]::PidOf($h)) -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq 'Code') { return $h }
    } catch { }
    return [IntPtr]::Zero
}

# Prune state files older than a week so the folder never grows unbounded.
function Remove-StaleState {
    try {
        if (Test-Path $script:NotifyStateDir) {
            Get-ChildItem $script:NotifyStateDir -Filter '*.hwnd' |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}
