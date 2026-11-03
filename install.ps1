<#
.SYNOPSIS
    Installs (or removes) Windows toast + window-flash notifications for Claude Code.

.DESCRIPTION
    - Copies the notify scripts to %USERPROFILE%\.claude\notify (or -Dest)
    - Registers the claude-notify: URL protocol for the current user (toast click -> focus VS Code)
    - Merges UserPromptSubmit / Stop / Notification hooks into %USERPROFILE%\.claude\settings.json,
      keeping every other setting intact (a settings.json.bak copy is written first)
    - Sends a test toast

    Nothing is written outside the current user's profile and HKCU.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$Dest = (Join-Path $env:USERPROFILE '.claude\notify'),
    [switch]$SkipTest
)

$ErrorActionPreference = 'Stop'

$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$protoKey     = 'HKCU:\Software\Classes\claude-notify'
$scriptNames  = 'notify-common.ps1', 'notify.ps1', 'notify-record.ps1', 'notify-activate.ps1'
$hookMarker   = 'notify(-record)?\.ps1'   # regex that identifies hook entries owned by this tool
$hookEvents   = 'UserPromptSubmit', 'Stop', 'Notification'

# ---------------------------------------------------------------- helpers
function Read-Settings {
    if (Test-Path $settingsPath) {
        $raw = Get-Content $settingsPath -Raw
        if ($raw -and $raw.Trim()) { return ($raw | ConvertFrom-Json) }
    }
    return [pscustomobject]@{}
}

# Windows PowerShell's ConvertTo-Json indents by nesting column; re-indent to a normal 2-space style.
function Format-Json([string]$json) {
    $depth = 0
    $out = foreach ($line in ($json -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -match '^[\]}]') { $depth = [Math]::Max(0, $depth - 1) }
        $t = $t -replace '":\s+', '": '
        (' ' * (2 * $depth)) + $t
        if ($t -match '[\[{]$') { $depth++ }
    }
    return ($out -join "`n") + "`n"
}

function Write-Settings($obj) {
    New-Item -ItemType Directory -Force -Path (Split-Path $settingsPath) | Out-Null
    if (Test-Path $settingsPath) { Copy-Item $settingsPath "$settingsPath.bak" -Force }
    $json = Format-Json ($obj | ConvertTo-Json -Depth 100)
    # UTF-8 without BOM: Claude Code's JSON parser rejects a BOM.
    [System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Remove-OurHooks($settings) {
    if (-not $settings.PSObject.Properties['hooks']) { return }
    foreach ($ev in $hookEvents) {
        if (-not $settings.hooks.PSObject.Properties[$ev]) { continue }
        $kept = @()
        foreach ($group in @($settings.hooks.$ev)) {
            $inner = @($group.hooks | Where-Object { -not ($_.type -eq 'command' -and $_.command -match $hookMarker) })
            if ($inner.Count -gt 0) {
                $group.hooks = [object[]]$inner
                $kept += $group
            }
        }
        if ($kept.Count -gt 0) { $settings.hooks.$ev = [object[]]$kept }
        else { $settings.hooks.PSObject.Properties.Remove($ev) }
    }
    if (@($settings.hooks.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }
}

function Add-OurHooks($settings) {
    if (-not $settings.PSObject.Properties['hooks']) {
        $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
    }
    $d = $Dest -replace '\\', '/'   # forward slashes survive whichever shell runs the hook
    $commands = @{
        UserPromptSubmit = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$d/notify-record.ps1`""
        Stop             = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$d/notify.ps1`" -Message `"Finished`""
        Notification     = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$d/notify.ps1`" -Message `"Needs your input`""
    }
    foreach ($ev in $hookEvents) {
        $hook  = [pscustomobject]@{ type = 'command'; command = $commands[$ev]; async = $true; timeout = 15 }
        $group = [pscustomobject]@{ hooks = [object[]]@($hook) }
        $existing = if ($settings.hooks.PSObject.Properties[$ev]) { @($settings.hooks.$ev) } else { @() }
        $merged = [object[]]($existing + @($group))
        if ($settings.hooks.PSObject.Properties[$ev]) { $settings.hooks.$ev = $merged }
        else { $settings.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue $merged }
    }
}

function Register-Protocol {
    New-Item -Path $protoKey -Force | Out-Null
    Set-ItemProperty -Path $protoKey -Name '(Default)' -Value 'URL:Claude Code Notification'
    New-ItemProperty -Path $protoKey -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
    New-Item -Path "$protoKey\shell\open\command" -Force | Out-Null
    $cmd = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Dest\notify-activate.ps1`" `"%1`""
    Set-ItemProperty -Path "$protoKey\shell\open\command" -Name '(Default)' -Value $cmd
}

# ---------------------------------------------------------------- uninstall
if ($Uninstall) {
    Write-Host "Removing Claude Code notification hooks from $settingsPath"
    $s = Read-Settings
    Remove-OurHooks $s
    Write-Settings $s

    if (Test-Path $protoKey) {
        Write-Host "Removing claude-notify: protocol registration"
        Remove-Item -Path $protoKey -Recurse -Force
    }

    if (Test-Path $Dest) {
        Write-Host "Removing scripts from $Dest"
        foreach ($n in $scriptNames) { Remove-Item (Join-Path $Dest $n) -Force -ErrorAction SilentlyContinue }
        Remove-Item (Join-Path $Dest 'notify-state') -Recurse -Force -ErrorAction SilentlyContinue
        # Only remove the folder itself if nothing else lives there.
        if (-not (Get-ChildItem $Dest -Force -ErrorAction SilentlyContinue)) { Remove-Item $Dest -Force }
    }

    Write-Host "Done. Restart Claude Code (or run /hooks once) so it drops the old hooks." -ForegroundColor Green
    return
}

# ---------------------------------------------------------------- install
$src = Join-Path $PSScriptRoot 'scripts'
foreach ($n in $scriptNames) {
    if (-not (Test-Path (Join-Path $src $n))) { throw "Missing $n in $src. Run install.ps1 from the unpacked package folder." }
}

Write-Host "Copying scripts to $Dest"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
foreach ($n in $scriptNames) { Copy-Item (Join-Path $src $n) (Join-Path $Dest $n) -Force }

Write-Host "Registering claude-notify: protocol (HKCU)"
Register-Protocol

Write-Host "Adding hooks to $settingsPath"
$s = Read-Settings
Remove-OurHooks $s     # replaces any previous install, wherever it lived
Add-OurHooks $s
Write-Settings $s

if (-not $SkipTest) {
    Write-Host "Sending a test notification..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'notify.ps1') -Message 'Notifications installed. Click me to focus VS Code.'
}

Write-Host ""
Write-Host "Installed." -ForegroundColor Green
Write-Host "If Claude Code is already running, restart it or run /hooks once so it picks up the new hooks."
Write-Host "To remove:  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall"
