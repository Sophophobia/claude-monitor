<#
  install.ps1  --  set up Claude Monitor on this machine.

  What it does (idempotent, non-destructive):
    1. Makes sure ~/.claude/session-status exists.
    2. Merges Claude Monitor's 5 hooks into ~/.claude/settings.json, using THIS
       machine's path to status-hook.ps1 (so it is portable across machines /
       usernames). Existing settings and other hooks are preserved; a backup is
       written to settings.json.bak first.
    3. With -Startup, drops a shortcut in the Startup folder so the panel
       launches at login.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Startup
#>
param([switch]$Startup)

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$hookPath = Join-Path $here 'status-hook.ps1'
$vbsPath  = Join-Path $here 'start-panel.vbs'
$claude   = Join-Path $env:USERPROFILE '.claude'
$settings = Join-Path $claude 'settings.json'
$statusDir = Join-Path $claude 'session-status'

if (-not (Test-Path $hookPath)) { throw "status-hook.ps1 not found next to install.ps1 ($hookPath)" }

# 1) status dir
New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
Write-Host "[ok] status dir: $statusDir"

# helper: PSCustomObject -> ordered hashtable (deep), preserving arrays
function ConvertTo-HashtableDeep($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [string] -or $o -is [bool] -or $o -is [int] -or $o -is [long] -or $o -is [double]) { return $o }
    if ($o -is [System.Collections.IEnumerable]) {
        $arr = @(); foreach ($i in $o) { $arr += , (ConvertTo-HashtableDeep $i) }; return , $arr
    }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }; return $h
    }
    return $o
}

# 2) load (or start) settings
$root = [ordered]@{}
if (Test-Path $settings) {
    Copy-Item $settings "$settings.bak" -Force
    Write-Host "[ok] backed up existing settings -> settings.json.bak"
    try { $root = ConvertTo-HashtableDeep (Get-Content $settings -Raw | ConvertFrom-Json) } catch { $root = [ordered]@{} }
}
if (-not ($root -is [System.Collections.IDictionary])) { $root = [ordered]@{} }
if (-not $root.Contains('hooks')) { $root['hooks'] = [ordered]@{} }
$hooks = $root['hooks']

# event -> -Event argument
$events = [ordered]@{
    SessionStart     = 'idle'
    UserPromptSubmit = 'running'
    Stop             = 'done'
    Notification     = 'notify'
    SessionEnd       = 'end'
}

foreach ($evt in $events.Keys) {
    $arg = $events[$evt]
    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Event {1}' -f $hookPath, $arg

    $existing = @()
    if ($hooks.Contains($evt) -and $hooks[$evt]) { $existing = @($hooks[$evt]) }

    # Remove any prior Claude Monitor entries (so re-running fixes a stale path), keep others.
    $kept = @()
    foreach ($group in $existing) {
        $isOurs = $false
        if ($group -and $group.Contains('hooks')) {
            foreach ($h in @($group['hooks'])) {
                if ($h.Contains('command') -and ([string]$h['command']) -match 'status-hook\.ps1') { $isOurs = $true }
            }
        }
        if (-not $isOurs) { $kept += , $group }
    }

    $beaconGroup = [ordered]@{ hooks = @( [ordered]@{ type = 'command'; command = $cmd } ) }
    $kept += , $beaconGroup
    $hooks[$evt] = $kept
}
$root['hooks'] = $hooks

($root | ConvertTo-Json -Depth 20) | Set-Content -Path $settings -Encoding UTF8
Write-Host "[ok] hooks written to: $settings"
Write-Host "     hook script     : $hookPath"

# 3) optional startup shortcut
if ($Startup) {
    $startupDir = [System.Environment]::GetFolderPath('Startup')
    $lnk = Join-Path $startupDir 'Claude Monitor.lnk'
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = (Join-Path $env:WINDIR 'System32\wscript.exe')
    $sc.Arguments  = '"' + $vbsPath + '"'
    $sc.WorkingDirectory = $here
    $sc.Description = 'Claude Monitor - Claude Code session monitor'
    $sc.Save()
    Write-Host "[ok] startup shortcut: $lnk"
}

Write-Host ""
Write-Host "Done. Restart any open Claude Code sessions so the hooks take effect,"
Write-Host "then launch the panel:  double-click start-panel.vbs"
