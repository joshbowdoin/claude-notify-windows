# Claude Code Stop / Notification hook.
# Shows a Windows toast and flashes the VS Code window this session lives in.
# Clicking the toast opens a claude-notify: link that brings that window to the front
# (switching virtual desktops if needed). See notify-activate.ps1.
param([string]$Message = "Claude Code is done")

. (Join-Path $PSScriptRoot 'notify-common.ps1')

$payload = Read-HookPayload ($input | Out-String)
if ($payload -and $payload.message) { $Message = $payload.message }
$sessionId = if ($payload -and $payload.session_id) { $payload.session_id } else { $env:CLAUDE_CODE_SESSION_ID }
$cwd = if ($payload -and $payload.cwd) { $payload.cwd } else { (Get-Location).Path }

# ---- Work out which VS Code window(s) to target ----
$targets = @()

# 1. The window recorded when you last submitted a prompt in this session (most precise).
$recorded = Get-RecordedWindow $sessionId
if ($recorded -ne [IntPtr]::Zero) { $targets = @($recorded) }

# 2. Otherwise, windows of the VS Code instance that spawned us, preferring a title match on the folder name.
if (-not $targets -and $env:VSCODE_PID) {
    $wins = [CcWin]::WindowsOfPid([uint32]$env:VSCODE_PID)
    $leaf = Split-Path $cwd -Leaf
    $byTitle = @($wins | Where-Object { [CcWin]::TitleOf($_) -like "* - $leaf - Visual Studio Code" })
    $targets = if ($byTitle) { $byTitle } else { @($wins) }
}

# 3. Last resort: every VS Code window.
if (-not $targets) {
    $targets = @(Get-Process Code -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        ForEach-Object { $_.MainWindowHandle })
}

# ---- Toast (built-in WinRT API, no module needed) ----
try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $title = "Claude Code"
    $sub = Split-Path $cwd -Leaf

    # Only wire up click-to-activate when we know exactly one window.
    $activation = ''
    if ($targets.Count -eq 1) {
        $activation = " activationType=`"protocol`" launch=`"claude-notify:activate?hwnd=$([long]$targets[0])`""
    }

    $xml = @"
<toast$activation>
  <visual>
    <binding template="ToastGeneric">
      <text>$(& $esc $title)</text>
      <text>$(& $esc $Message)</text>
      <text placement="attribution">$(& $esc $sub)</text>
    </binding>
  </visual>
</toast>
"@
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
    # AppId of Windows PowerShell so the toast is attributed to a registered app.
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
} catch {
    # Fall back to a balloon tip if WinRT toast is unavailable.
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Information
        $n.Visible = $true
        $n.ShowBalloonTip(5000, "Claude Code", $Message, [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 5
        $n.Dispose()
    } catch { }
}

# ---- Flash the target window(s) until focused ----
foreach ($h in $targets) { [CcWin]::Flash([IntPtr]$h) }
