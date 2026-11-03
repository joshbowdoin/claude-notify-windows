# Claude Code UserPromptSubmit hook.
# Records which VS Code window is in the foreground when you submit a prompt,
# so Stop/Notification hooks can target exactly that window later.
param([long]$Hwnd = 0)   # -Hwnd is only for manual testing; normally the foreground window is used.

. (Join-Path $PSScriptRoot 'notify-common.ps1')

$payload = Read-HookPayload ($input | Out-String)
$sessionId = if ($payload -and $payload.session_id) { $payload.session_id } else { $env:CLAUDE_CODE_SESSION_ID }
if (-not $sessionId) { exit 0 }

$h = if ($Hwnd -ne 0) { [IntPtr]$Hwnd } else { [CcWin]::GetForegroundWindow() }
if ($h -eq [IntPtr]::Zero) { exit 0 }

# Only record if the foreground window really is a VS Code window.
# Prefer the VS Code instance that spawned this session, but accept any Code.exe window.
$pid_ = [CcWin]::PidOf($h)
$proc = Get-Process -Id $pid_ -ErrorAction SilentlyContinue
if (-not $proc -or $proc.ProcessName -ne 'Code') { exit 0 }

$f = Get-StateFile $sessionId
New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
Set-Content -Path $f -Value ([long]$h).ToString() -NoNewline
Remove-StaleState
