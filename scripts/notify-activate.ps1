# Protocol handler for claude-notify: links, invoked when you click a Claude Code toast.
# Usage (registered in HKCU):  notify-activate.ps1 "claude-notify:activate?hwnd=12345"
param([Parameter(Position = 0)][string]$Uri = '')

. (Join-Path $PSScriptRoot 'notify-common.ps1')

if ($Uri -notmatch 'hwnd=(\d+)') { exit 0 }
$h = [IntPtr][long]$Matches[1]
if (-not [CcWin]::IsWindow($h)) { exit 0 }

# Whatever is in the foreground right now sits on the desktop the user is looking at.
$reference = [CcWin]::GetForegroundWindow()

# Activating a window on another virtual desktop normally makes Windows switch to it.
[void][CcWin]::Activate($h)
Start-Sleep -Milliseconds 300

# If Windows did not switch desktops, pull the window onto the current desktop instead.
if (-not [CcDesktop]::IsOnCurrent($h) -and $reference -ne [IntPtr]::Zero) {
    [void][CcDesktop]::MoveToDesktopOf($h, $reference)
    [void][CcWin]::Activate($h)
}
