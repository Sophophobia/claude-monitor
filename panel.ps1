<#
  panel.ps1  --  Claude Code Session Monitor
  A small always-on-top, draggable floating panel that shows the live state of
  the Claude Code sessions you pin.

  State comes from ~/.claude/session-status/<id>.json files written by
  status-hook.ps1 (wired up via global hooks in ~/.claude/settings.json).
  Liveness comes from ~/.claude/sessions/<pid>.json (Claude writes these) plus a
  pid-alive check.

  Launch hidden via start-panel.vbs, or directly:
    powershell -NoProfile -ExecutionPolicy Bypass -Sta -File panel.ps1
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Custom color table so context menus match the theme: no white image-margin
# gutter, and a hover highlight that keeps the (light or dark) text readable.
# Colors are static fields set from the current theme before each menu shows.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System.Drawing;
using System.Windows.Forms;
public class CMColorTable : ProfessionalColorTable {
    public static Color Bg     = Color.FromArgb(28,28,32);
    public static Color Hover  = Color.FromArgb(58,58,68);
    public static Color Border = Color.FromArgb(55,55,62);
    public override Color ToolStripDropDownBackground       { get { return Bg; } }
    public override Color ImageMarginGradientBegin          { get { return Bg; } }
    public override Color ImageMarginGradientMiddle         { get { return Bg; } }
    public override Color ImageMarginGradientEnd            { get { return Bg; } }
    public override Color MenuItemSelected                  { get { return Hover; } }
    public override Color MenuItemSelectedGradientBegin     { get { return Hover; } }
    public override Color MenuItemSelectedGradientEnd       { get { return Hover; } }
    public override Color MenuItemPressedGradientBegin      { get { return Bg; } }
    public override Color MenuItemPressedGradientEnd        { get { return Bg; } }
    public override Color MenuItemBorder                    { get { return Hover; } }
    public override Color MenuBorder                        { get { return Border; } }
    public override Color SeparatorDark                     { get { return Border; } }
    public override Color SeparatorLight                    { get { return Border; } }
}
"@

# ---------------------------------------------------------------- paths -----
$Home_      = $env:USERPROFILE
$StatusDir  = Join-Path $Home_ '.claude\session-status'
$SessionDir = Join-Path $Home_ '.claude\sessions'
# config.json lives next to this script so the whole tool folder is portable.
$ConfigPath = Join-Path $PSScriptRoot 'config.json'

# How long a tool may stay 'pending' (PreToolUse fired, PostToolUse not yet)
# before we assume it is blocked on a permission prompt and show orange. The
# desktop app fires no Notification for permission dialogs, so this timing
# heuristic is how "Needs permission" is detected. Quick auto-approved tools
# finish well under this, so they never flip to orange. Tweak to taste.
$script:PendingPermMs = 3000

# --------------------------------------------------------------- config -----
$script:Pins    = @()
$script:PosX    = $null
$script:PosY    = $null
$script:Names   = @{}   # sessionId -> custom display name (overrides the auto-title)
$script:PinInfo = @{}   # sessionId -> @{ project; cwd; title } last-known identity, so an
                        # ended pin still renders sensibly after its session record is gone.
$script:pinInfoDirty = $false

# Grouping: sessions can be sorted into named, collapsible groups.
$script:Groups     = @{}   # sessionId -> group name (absent = ungrouped)
$script:GroupOrder = @()   # ordered list of group names (display order of group blocks)
$script:Collapsed  = @{}   # group name -> $true if collapsed
$script:UngroupedName = 'Ungrouped'   # header shown for sessions in no group (only when groups exist)

# In-session "#name"/"#group" commands feed these. AutoPinned: sids we have
# already auto-pinned (or that the user has since unpinned) so we don't re-pin
# them. GroupCmd: the last "#group" value we applied per sid, used as a latch so
# a fresh "#group" re-groups but a later manual move is not overridden.
$script:AutoPinned = @{}
$script:GroupCmd   = @{}

$script:Theme = 'dark'   # 'dark' (default) or 'light'
$script:Compact = $false # compact mode: show only sessions needing answer/permission

function Load-Config {
    try {
        if (Test-Path $ConfigPath) {
            $c = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            if ($c.pins) { $script:Pins = @($c.pins) }
            if ($null -ne $c.x) { $script:PosX = [int]$c.x }
            if ($null -ne $c.y) { $script:PosY = [int]$c.y }
            if ($c.names) {
                $h = @{}
                foreach ($p in $c.names.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
                $script:Names = $h
            }
            if ($c.pinInfo) {
                $h = @{}
                foreach ($p in $c.pinInfo.PSObject.Properties) {
                    $v = $p.Value
                    $h[$p.Name] = @{
                        project        = [string]$v.project
                        cwd            = [string]$v.cwd
                        title          = [string]$v.title
                        transcriptPath = [string]$v.transcriptPath
                    }
                }
                $script:PinInfo = $h
            }
            if ($c.groups) {
                $h = @{}
                foreach ($p in $c.groups.PSObject.Properties) { if ($p.Value) { $h[$p.Name] = [string]$p.Value } }
                $script:Groups = $h
            }
            if ($c.groupOrder) { $script:GroupOrder = @($c.groupOrder) }
            if ($c.collapsed) {
                $h = @{}
                foreach ($p in $c.collapsed.PSObject.Properties) { $h[$p.Name] = [bool]$p.Value }
                $script:Collapsed = $h
            }
            if ($c.autoPinned) {
                $h = @{}
                foreach ($p in $c.autoPinned.PSObject.Properties) { $h[$p.Name] = [bool]$p.Value }
                $script:AutoPinned = $h
            }
            if ($c.groupCmd) {
                $h = @{}
                foreach ($p in $c.groupCmd.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
                $script:GroupCmd = $h
            }
            if ($c.theme) { $script:Theme = [string]$c.theme }
            if ($null -ne $c.compact) { $script:Compact = [bool]$c.compact }
        }
    } catch { }
}

function Save-Config {
    try {
        $obj = [ordered]@{
            pins       = @($script:Pins)
            x          = $script:PosX
            y          = $script:PosY
            names      = $script:Names
            pinInfo    = $script:PinInfo
            groups     = $script:Groups
            groupOrder = @($script:GroupOrder)
            collapsed  = $script:Collapsed
            autoPinned = $script:AutoPinned
            groupCmd   = $script:GroupCmd
            theme      = $script:Theme
            compact    = $script:Compact
        }
        ($obj | ConvertTo-Json -Compress) | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch { }
}

# Display label priority: custom name (panel rename) > "#name" label > "project (shortid)".
function Get-Display($sid, $s) {
    if ($script:Names.ContainsKey($sid) -and $script:Names[$sid]) { return $script:Names[$sid] }
    if ($s.title) { return $s.title }
    $short = $sid.Substring(0, [Math]::Min(8, $sid.Length))
    if ($s.project) { return ('{0} ({1})' -f $s.project, $short) }
    return $short
}

# A conversation's transcript file (~/.claude/projects/<mangled-cwd>/<sid>.jsonl)
# stays on disk while the conversation merely sits idle / backgrounded, and is
# only removed when the conversation is deleted. The desktop app fires
# SessionEnd (which deletes our status file) for BOTH cases, so transcript
# existence is what lets us keep an idle conversation as "Waiting" and reserve
# "Ended" for a genuinely deleted one.
$script:ProjectsDir = Join-Path $Home_ '.claude\projects'
function Test-TranscriptAlive($sid, $tpath) {
    try {
        if ($tpath -and (Test-Path $tpath)) { return $true }
        if ($sid -and (Test-Path $script:ProjectsDir)) {
            $hit = Get-ChildItem -Path $script:ProjectsDir -Filter ($sid + '.jsonl') -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $true }
        }
    } catch { }
    return $false
}

# ----------------------------------------------------- data acquisition -----
# Returns hashtable: sessionId -> [pscustomobject]@{ sid, project, cwd, state, message, live, updatedAt }
function Get-Sessions {
    $map = @{}

    # Live pids
    $alivePids = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) { $alivePids[$p.Id] = $true }

    # 1) Live sessions from ~/.claude/sessions/*.json
    if (Test-Path $SessionDir) {
        foreach ($f in (Get-ChildItem (Join-Path $SessionDir '*.json') -ErrorAction SilentlyContinue)) {
            try {
                $j = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                $sid = $j.sessionId
                if (-not $sid) { continue }
                $isLive = $alivePids.ContainsKey([int]$j.pid)
                $proj = ''
                if ($j.cwd) { $proj = Split-Path $j.cwd -Leaf }
                $map[$sid] = [pscustomobject]@{
                    sid            = $sid
                    project        = $proj
                    cwd            = [string]$j.cwd
                    title          = ''
                    group          = ''
                    state          = 'waiting'
                    message        = ''
                    transcriptPath = ''
                    live           = $isLive
                    updatedAt      = 0
                }
            } catch { }
        }
    }

    # Set of cwds that currently host a live session record. Used to rescue
    # "orphan" status files: the desktop app sometimes gives the hook a
    # session_id that differs from the sessionId Claude writes into
    # sessions/<pid>.json for the SAME window, so an active session's status
    # file has no id-match here and would otherwise look ended.
    $liveCwds = @{}
    foreach ($k in @($map.Keys)) {
        $e = $map[$k]
        if ($e.live -and $e.cwd) { $liveCwds[([string]$e.cwd).ToLower()] = $true }
    }
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $staleMs = 6 * 60 * 60 * 1000   # 6h: a status file not updated this long is treated as ended

    # 2) Overlay status files (the real run-state)
    if (Test-Path $StatusDir) {
        foreach ($f in (Get-ChildItem (Join-Path $StatusDir '*.json') -ErrorAction SilentlyContinue)) {
            try {
                $j = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                $sid = $j.sessionId
                if (-not $sid) { continue }
                if ($map.ContainsKey($sid)) {
                    $map[$sid].state     = [string]$j.state
                    $map[$sid].message   = [string]$j.message
                    $map[$sid].updatedAt = [long]$j.updatedAt
                    if ($j.transcriptPath) { $map[$sid].transcriptPath = [string]$j.transcriptPath }
                    if ($j.title) { $map[$sid].title = [string]$j.title }
                    if ($j.group) { $map[$sid].group = [string]$j.group }
                    if (-not $map[$sid].project -and $j.project) { $map[$sid].project = [string]$j.project }
                    if (-not $map[$sid].cwd -and $j.cwd) { $map[$sid].cwd = [string]$j.cwd }
                } else {
                    # No id-match in sessions/*.json. A status file only exists
                    # while the session is alive (SessionEnd deletes it), so
                    # treat it as live if either another live session shares its
                    # cwd (same window, different id) or it was updated recently.
                    $ts      = [long]$j.updatedAt
                    $cwdLive = $j.cwd -and $liveCwds.ContainsKey(([string]$j.cwd).ToLower())
                    $fresh   = ($ts -gt 0) -and (($nowMs - $ts) -lt $staleMs)
                    $map[$sid] = [pscustomobject]@{
                        sid            = $sid
                        project        = [string]$j.project
                        cwd            = [string]$j.cwd
                        title          = [string]$j.title
                        group          = [string]$j.group
                        state          = [string]$j.state
                        message        = [string]$j.message
                        transcriptPath = [string]$j.transcriptPath
                        live           = [bool]($cwdLive -or $fresh)
                        updatedAt      = $ts
                    }
                }
            } catch { }
        }
    }

    # Escalate 'pending' tools to 'permission'. A tool that has been pending
    # longer than the threshold is almost certainly blocked on a permission
    # prompt (auto-approved tools return in well under a second); until then it
    # is just normal work, so keep it 'running'. Recomputed every refresh.
    foreach ($k in @($map.Keys)) {
        $e = $map[$k]
        if ($e.state -eq 'pending') {
            if ($e.updatedAt -gt 0 -and ($nowMs - $e.updatedAt) -ge $script:PendingPermMs) {
                $e.state = 'permission'
            } else {
                $e.state = 'running'
            }
        }
    }

    return $map
}

# Resolve a pinned session to a row object. If it is still present in $all we
# use that and refresh its remembered identity; if it has vanished (status file
# deleted on SessionEnd, or a transient read error) we DON'T drop it -- we
# synthesize an "Ended" row from the last-known project/title instead.
function Resolve-Pin($sid, $all) {
    if ($all.ContainsKey($sid)) {
        $s = $all[$sid]
        $prev = $script:PinInfo[$sid]
        # The live status file may have lost its "#name" title (it is recreated
        # empty after the desktop app fires SessionEnd on idle). Don't revert to
        # the auto name: fall back to the last-known cached label. status-hook
        # also re-injects it from the label file, but this covers the gap.
        if (-not $s.title -and $prev -and $prev.title) { $s.title = [string]$prev.title }
        if (-not $prev -or
            [string]$prev.project        -ne [string]$s.project -or
            [string]$prev.cwd            -ne [string]$s.cwd -or
            [string]$prev.title          -ne [string]$s.title -or
            [string]$prev.transcriptPath -ne [string]$s.transcriptPath) {
            $script:PinInfo[$sid] = @{
                project        = [string]$s.project
                cwd            = [string]$s.cwd
                title          = [string]$s.title
                transcriptPath = [string]$s.transcriptPath
            }
            $script:pinInfoDirty = $true
        }
        return $s
    }
    # Not in $all: the status file is gone (SessionEnd deleted it). The
    # conversation may merely be idle/backgrounded, or genuinely deleted. Its
    # transcript file tells them apart: present -> still "Waiting" (green),
    # gone -> truly "Ended" (gray).
    $info  = $script:PinInfo[$sid]
    $tpath = if ($info) { [string]$info.transcriptPath } else { '' }
    $alive = Test-TranscriptAlive $sid $tpath
    return [pscustomobject]@{
        sid            = $sid
        project        = if ($info) { [string]$info.project } else { '' }
        cwd            = if ($info) { [string]$info.cwd }     else { '' }
        title          = if ($info) { [string]$info.title }   else { '' }
        group          = ''
        transcriptPath = $tpath
        state          = if ($alive) { 'waiting' } else { 'ended' }
        message        = ''
        live           = $alive
        updatedAt      = 0
    }
}

# state -> color + label
function Get-StateStyle($state, $live) {
    if (-not $live) {
        return @{ color = [System.Drawing.Color]::FromArgb(107,114,128); label = 'Ended' }   # gray
    }
    switch ($state) {
        'running'    { return @{ color = [System.Drawing.Color]::FromArgb(59,130,246);  label = 'Running' } }       # blue
        'pending'    { return @{ color = [System.Drawing.Color]::FromArgb(59,130,246);  label = 'Running' } }       # blue (escalates to permission in Get-Sessions)
        'permission' { return @{ color = [System.Drawing.Color]::FromArgb(249,115,22);  label = 'Needs permission' } } # orange
        'ask'        { return @{ color = [System.Drawing.Color]::FromArgb(168,85,247);  label = 'Needs answer' } }   # purple
        # done + idle are merged into one "waiting" state (green).
        'waiting'    { return @{ color = [System.Drawing.Color]::FromArgb(34,197,94);   label = 'Waiting' } }        # green
        'done'       { return @{ color = [System.Drawing.Color]::FromArgb(34,197,94);   label = 'Waiting' } }        # green (legacy)
        'idle'       { return @{ color = [System.Drawing.Color]::FromArgb(34,197,94);   label = 'Waiting' } }        # green (legacy)
        default      { return @{ color = [System.Drawing.Color]::FromArgb(148,163,184); label = 'Live' } }          # slate
    }
}

# --------------------------------------------------------------- colors -----
# Chrome colors are theme-driven (dark / light). State dot colors stay fixed --
# they read clearly on both backgrounds. Set-ThemeColors fills the $script:c*
# palette from $script:Theme; Apply-Theme re-applies it live to the panel.
function Set-ThemeColors {
    if ($script:Theme -eq 'light') {
        $script:cBg     = [System.Drawing.Color]::FromArgb(250,250,251)
        $script:cBar    = [System.Drawing.Color]::FromArgb(234,235,239)
        $script:cText   = [System.Drawing.Color]::FromArgb(24,24,28)
        $script:cDim    = [System.Drawing.Color]::FromArgb(100,116,139)
        $script:cBorder = [System.Drawing.Color]::FromArgb(205,209,218)
        $script:cField  = [System.Drawing.Color]::FromArgb(255,255,255)
        $script:cHover  = [System.Drawing.Color]::FromArgb(210,216,228)
    } else {
        $script:cBg     = [System.Drawing.Color]::FromArgb(17,17,19)
        $script:cBar    = [System.Drawing.Color]::FromArgb(28,28,32)
        $script:cText   = [System.Drawing.Color]::FromArgb(229,231,235)
        $script:cDim    = [System.Drawing.Color]::FromArgb(148,163,184)
        $script:cBorder = [System.Drawing.Color]::FromArgb(55,55,62)
        $script:cField  = [System.Drawing.Color]::FromArgb(38,38,44)
        $script:cHover  = [System.Drawing.Color]::FromArgb(58,58,70)
    }
}

# Apply the dark/light theme + custom renderer to a context menu so it matches
# the panel (no white gutter, readable hover). Call right after creating one.
function Style-Menu($m) {
    [CMColorTable]::Bg     = $script:cBar
    [CMColorTable]::Hover  = $script:cHover
    [CMColorTable]::Border = $script:cBorder
    if (-not $script:menuRenderer) {
        $script:menuRenderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer ([CMColorTable]::new())
        $script:menuRenderer.RoundedEdges = $false
    }
    # Set the GLOBAL renderer too, so nested submenus (e.g. "Add to group") and
    # any dropdown match instead of falling back to the default light style.
    [System.Windows.Forms.ToolStripManager]::Renderer = $script:menuRenderer
    $m.BackColor       = $script:cBar
    $m.ForeColor       = $script:cText
    $m.ShowImageMargin = $false
    $m.Renderer        = $script:menuRenderer
}
function Apply-Theme {
    Set-ThemeColors
    $form.BackColor      = $script:cBg
    $bar.BackColor       = $script:cBar
    $title.ForeColor     = $script:cText
    $btnCompact.ForeColor = $script:cText
    $btnMenu.ForeColor   = $script:cText
    $btnClose.ForeColor  = $script:cDim
    $content.BackColor   = $script:cBg
    $form.Invalidate()
    Refresh-Rows -force
}
# Toggle compact mode (show only sessions needing answer/permission).
function Set-Compact($on) {
    $script:Compact = [bool]$on
    if ($btnCompact) { $btnCompact.Text = if ($script:Compact) { [char]0x25BE } else { [char]0x25B4 } }
    Save-Config
    Refresh-Rows -force
}
$cBg = $cBar = $cText = $cDim = $null   # filled by Set-ThemeColors after Load-Config
$fName   = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
$fState  = New-Object System.Drawing.Font('Segoe UI', 8.5)
$fIcon   = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$W       = 290
$TitleH  = 30
$RowH    = 28
$HeaderH = 22
$fGroup  = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
$script:tip = New-Object System.Windows.Forms.ToolTip
$script:tip.AutoPopDelay = 8000
$script:tip.InitialDelay = 350

# ----------------------------------------------------------------- form -----
Load-Config
Set-ThemeColors

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.BackColor       = $cBg
$form.Width           = $W
$form.Height          = $TitleH + $RowH + 8
$form.StartPosition   = 'Manual'

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($null -ne $script:PosX -and $null -ne $script:PosY) {
    $form.Location = New-Object System.Drawing.Point($script:PosX, $script:PosY)
} else {
    $form.Location = New-Object System.Drawing.Point([int](($screen.Width - $W) / 2), 4)
}

# thin border
$form.Add_Paint({
    param($s,$e)
    $pen = New-Object System.Drawing.Pen ($script:cBorder), 1
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
    $pen.Dispose()
})

# ---- title bar (drag handle + buttons) ----
$bar = New-Object System.Windows.Forms.Panel
$bar.Height    = $TitleH
$bar.Dock      = 'Top'
$bar.BackColor = $cBar
$form.Controls.Add($bar)

$title = New-Object System.Windows.Forms.Label
$title.Text      = [char]0x25C9 + ' Claude Monitor'
$title.ForeColor = $cText
$title.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$title.AutoSize  = $false
$title.Location  = New-Object System.Drawing.Point(10, 0)
$title.Size      = New-Object System.Drawing.Size(($W - 96), $TitleH)
$title.TextAlign = 'MiddleLeft'
$bar.Controls.Add($title)

# Compact-mode toggle (shows only sessions that need you).
$btnCompact = New-Object System.Windows.Forms.Label
$btnCompact.Text      = if ($script:Compact) { [char]0x25BE } else { [char]0x25B4 }
$btnCompact.ForeColor = $cText
$btnCompact.Font      = $fIcon
$btnCompact.Size      = New-Object System.Drawing.Size(26, $TitleH)
$btnCompact.Location  = New-Object System.Drawing.Point(($W - 82), 0)
$btnCompact.TextAlign = 'MiddleCenter'
$btnCompact.Cursor    = 'Hand'
$bar.Controls.Add($btnCompact)
$btnCompact.Add_Click({ Set-Compact (-not $script:Compact) })
$script:tip.SetToolTip($btnCompact, 'Compact mode: show only sessions that need you')

$btnMenu = New-Object System.Windows.Forms.Label
$btnMenu.Text      = [char]0x2261   # triple bar
$btnMenu.ForeColor = $cText
$btnMenu.Font      = $fIcon
$btnMenu.Size      = New-Object System.Drawing.Size(26, $TitleH)
$btnMenu.Location  = New-Object System.Drawing.Point(($W - 56), 0)
$btnMenu.TextAlign = 'MiddleCenter'
$btnMenu.Cursor    = 'Hand'
$bar.Controls.Add($btnMenu)

$btnClose = New-Object System.Windows.Forms.Label
$btnClose.Text      = [char]0x2715   # x
$btnClose.ForeColor = $cDim
$btnClose.Font      = $fIcon
$btnClose.Size      = New-Object System.Drawing.Size(26, $TitleH)
$btnClose.Location  = New-Object System.Drawing.Point(($W - 28), 0)
$btnClose.TextAlign = 'MiddleCenter'
$btnClose.Cursor    = 'Hand'
$bar.Controls.Add($btnClose)
$btnClose.Add_Click({ $form.Close() })
$btnClose.Add_MouseEnter({ $btnClose.ForeColor = [System.Drawing.Color]::FromArgb(239,68,68) })
$btnClose.Add_MouseLeave({ $btnClose.ForeColor = $cDim })

# ---- rows container ----
$content = New-Object System.Windows.Forms.Panel
$content.Dock      = 'Fill'
$content.BackColor = $cBg
$form.Controls.Add($content)
$content.BringToFront()

# ------------------------------------------------------------- dragging -----
$script:dragging = $false
$script:dragOff  = New-Object System.Drawing.Point(0,0)
$startDrag = {
    param($s,$e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragging = $true
        $script:dragOff  = New-Object System.Drawing.Point($e.X, $e.Y)
    }
}
$doDrag = {
    param($s,$e)
    if ($script:dragging) {
        $p = [System.Windows.Forms.Cursor]::Position
        $form.Location = New-Object System.Drawing.Point(($p.X - $script:dragOff.X), ($p.Y - $script:dragOff.Y))
    }
}
$endDrag = {
    param($s,$e)
    if ($script:dragging) {
        $script:dragging = $false
        $script:PosX = $form.Location.X
        $script:PosY = $form.Location.Y
        Save-Config
    }
}
foreach ($ctl in @($bar, $title)) {
    $ctl.Add_MouseDown($startDrag)
    $ctl.Add_MouseMove($doDrag)
    $ctl.Add_MouseUp($endDrag)
}

# ----------------------------------------------------------- pin toggle -----
function Toggle-Pin($sid) {
    if ($script:Pins -contains $sid) {
        $script:Pins = @($script:Pins | Where-Object { $_ -ne $sid })
        if ($script:Groups.ContainsKey($sid)) { $script:Groups.Remove($sid) }
        $script:AutoPinned[$sid] = $true   # user unpinned: don't auto-re-pin from #name/#group
    } else {
        $script:Pins = @($script:Pins) + $sid
        if ($script:AutoPinned.ContainsKey($sid)) { $script:AutoPinned.Remove($sid) }
    }
    Normalize-Groups
    Save-Config
    Refresh-Rows -force
}

# --------------------------------------------------------------- groups -----
function Get-GroupOf($sid) {
    if ($script:Groups.ContainsKey($sid) -and $script:Groups[$sid]) { return [string]$script:Groups[$sid] }
    return ''
}

# Drop memberships for sids no longer pinned and prune empty groups so the
# group list never shows a header with nothing under it.
function Normalize-Groups {
    $pinset = @{}; foreach ($p in $script:Pins) { $pinset[$p] = $true }
    foreach ($k in @($script:Groups.Keys)) { if (-not $pinset.ContainsKey($k)) { $script:Groups.Remove($k) } }
    $used = @{}; foreach ($v in $script:Groups.Values) { if ($v) { $used[$v] = $true } }
    $script:GroupOrder = @($script:GroupOrder | Where-Object { $used.ContainsKey($_) })
    foreach ($v in @($used.Keys)) { if ($script:GroupOrder -notcontains $v) { $script:GroupOrder = @($script:GroupOrder) + $v } }
    foreach ($k in @($script:Collapsed.Keys)) {
        if ($k -ne $script:UngroupedName -and -not $used.ContainsKey($k)) { $script:Collapsed.Remove($k) }
    }
}

function Set-Group($sid, $name) {
    $name = ([string]$name).Trim()
    if (-not $name) { return }
    if ($name.Length -gt 40) { $name = $name.Substring(0, 40) }
    $script:Groups[$sid] = $name
    if ($script:GroupOrder -notcontains $name) { $script:GroupOrder = @($script:GroupOrder) + $name }
    Normalize-Groups
    Save-Config
    Refresh-Rows -force
}

function Remove-FromGroup($sid) {
    if ($script:Groups.ContainsKey($sid)) { $script:Groups.Remove($sid) }
    Normalize-Groups
    Save-Config
    Refresh-Rows -force
}

function New-GroupFor($sid) {
    $new = Show-InputDialog 'New group' 'Name for the new group:' ''
    if (-not [string]::IsNullOrWhiteSpace($new)) { Set-Group $sid $new }
}

function Rename-Group($old) {
    $new = Show-InputDialog 'Rename group' 'New name for this group:' $old
    $new = ([string]$new).Trim()
    if (-not $new -or $new -eq $old) { return }
    if ($new.Length -gt 40) { $new = $new.Substring(0, 40) }
    foreach ($k in @($script:Groups.Keys)) { if ($script:Groups[$k] -eq $old) { $script:Groups[$k] = $new } }
    $script:GroupOrder = @($script:GroupOrder | ForEach-Object { if ($_ -eq $old) { $new } else { $_ } })
    if ($script:Collapsed.ContainsKey($old)) { $script:Collapsed[$new] = $script:Collapsed[$old]; $script:Collapsed.Remove($old) }
    $seen = @{}; $script:GroupOrder = @($script:GroupOrder | Where-Object { if ($seen.ContainsKey($_)) { $false } else { $seen[$_] = $true; $true } })
    Normalize-Groups
    Save-Config
    Refresh-Rows -force
}

function Move-Group($name, $delta) {
    $list = @($script:GroupOrder)
    $i = [array]::IndexOf($list, [string]$name)
    if ($i -lt 0) { return }
    $j = $i + $delta
    if ($j -lt 0 -or $j -ge $list.Count) { return }
    $tmp = $list[$i]; $list[$i] = $list[$j]; $list[$j] = $tmp
    $script:GroupOrder = @($list)
    Save-Config
    Refresh-Rows -force
}

function Toggle-Collapse($name) {
    if ($script:Collapsed.ContainsKey($name) -and $script:Collapsed[$name]) { $script:Collapsed.Remove($name) }
    else { $script:Collapsed[$name] = $true }
    Save-Config
    Refresh-Rows -force
}

# Returns the render plan: an ordered list of group blocks. When no groups are
# defined the single block has hasHeader=$false (flat list, unchanged UX).
function Get-OrderedGroups {
    $result = @()
    if ($script:GroupOrder.Count -eq 0) {
        $result += [pscustomobject]@{ name = ''; members = @($script:Pins); isUngrouped = $true; hasHeader = $false }
        return , $result
    }
    foreach ($g in $script:GroupOrder) {
        $members = @($script:Pins | Where-Object { (Get-GroupOf $_) -eq $g })
        $result += [pscustomobject]@{ name = $g; members = $members; isUngrouped = $false; hasHeader = $true }
    }
    $ung = @($script:Pins | Where-Object { -not (Get-GroupOf $_) })
    if ($ung.Count -gt 0) {
        $result += [pscustomobject]@{ name = $script:UngroupedName; members = $ung; isUngrouped = $true; hasHeader = $true }
    }
    return , $result
}

# ----------------------------------------------------------- input dialog ---
# A small dark-themed modal input box that matches the panel, replacing the
# dated Microsoft.VisualBasic InputBox. Returns the entered string, or $null if
# the user cancelled (Esc / Cancel / X). An empty string means "submitted blank".
function Show-InputDialog($title, $prompt, $default) {
    $dBg    = $script:cBg
    $dTxt   = $script:cText
    $dDim   = $script:cDim
    $dAcc   = [System.Drawing.Color]::FromArgb(59,130,246)
    $dField = $script:cField

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.FormBorderStyle = 'None'
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.TopMost         = $true
    $dlg.ShowInTaskbar   = $false
    $dlg.BackColor       = $dBg
    $dlg.ClientSize      = New-Object System.Drawing.Size(320, 138)
    $dlg.KeyPreview      = $true
    $dlg.Add_Paint({ param($s, $e)
        $pen = New-Object System.Drawing.Pen ($script:cBorder), 1
        $e.Graphics.DrawRectangle($pen, 0, 0, $s.ClientSize.Width - 1, $s.ClientSize.Height - 1)
        $pen.Dispose() })

    $lt = New-Object System.Windows.Forms.Label
    $lt.Text = [string]$title; $lt.ForeColor = $dTxt
    $lt.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lt.AutoSize = $false; $lt.Location = New-Object System.Drawing.Point(16, 14); $lt.Size = New-Object System.Drawing.Size(288, 22)
    $dlg.Controls.Add($lt)

    $lp = New-Object System.Windows.Forms.Label
    $lp.Text = [string]$prompt; $lp.ForeColor = $dDim
    $lp.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $lp.AutoSize = $false; $lp.Location = New-Object System.Drawing.Point(16, 38); $lp.Size = New-Object System.Drawing.Size(288, 16)
    $dlg.Controls.Add($lp)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = [string]$default; $box.ForeColor = $dTxt; $box.BackColor = $dField
    $box.BorderStyle = 'FixedSingle'
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $box.Location = New-Object System.Drawing.Point(16, 60); $box.Size = New-Object System.Drawing.Size(288, 26)
    $dlg.Controls.Add($box)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.ForeColor = [System.Drawing.Color]::White; $ok.BackColor = $dAcc
    $ok.FlatStyle = 'Flat'; $ok.FlatAppearance.BorderSize = 0
    $ok.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $ok.Size = New-Object System.Drawing.Size(74, 30); $ok.Location = New-Object System.Drawing.Point(230, 98)
    $dlg.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.ForeColor = $dTxt; $cancel.BackColor = $dBg
    $cancel.FlatStyle = 'Flat'; $cancel.FlatAppearance.BorderColor = $dDim; $cancel.FlatAppearance.BorderSize = 1
    $cancel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $cancel.Size = New-Object System.Drawing.Size(74, 30); $cancel.Location = New-Object System.Drawing.Point(148, 98)
    $dlg.Controls.Add($cancel)

    $script:dlgResult = $null
    $ok.Add_Click({ $script:dlgResult = $box.Text; $dlg.Close() })
    $cancel.Add_Click({ $script:dlgResult = $null; $dlg.Close() })
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel
    $dlg.Add_Shown({ $box.Focus(); $box.SelectAll() })
    [void]$dlg.ShowDialog()
    return $script:dlgResult
}

# ------------------------------------------------------------- renaming -----
function Set-Name($sid, $current) {
    $new = Show-InputDialog 'Rename session' 'Enter a name (submit empty to use the auto title):' $current
    if ($null -eq $new) { return }                 # cancelled: no change
    if ([string]::IsNullOrWhiteSpace($new)) {      # submitted blank: revert to auto title
        if ($script:Names.ContainsKey($sid)) { $script:Names.Remove($sid) }
    } else {
        $script:Names[$sid] = $new.Trim()
    }
    Save-Config
    Refresh-Rows -force
}

function Clear-Name($sid) {
    if ($script:Names.ContainsKey($sid)) { $script:Names.Remove($sid) }
    Save-Config
    Refresh-Rows -force
}

# ---------------------------------------------------------- reordering ------
# Move a pinned session up (-1) or down (+1) in the panel order.
function Move-Pin($sid, $delta) {
    $list = @($script:Pins)
    $i = [array]::IndexOf($list, [string]$sid)
    if ($i -lt 0) { return }
    # Move within the session's own group: find the nearest pin in the same group
    # in the requested direction and swap with it (pins of other groups in between
    # keep their slots, so only same-group order changes).
    $g = Get-GroupOf $sid
    $j = $i + $delta
    while ($j -ge 0 -and $j -lt $list.Count -and (Get-GroupOf $list[$j]) -ne $g) { $j += $delta }
    if ($j -lt 0 -or $j -ge $list.Count) { return }
    $tmp = $list[$i]; $list[$i] = $list[$j]; $list[$j] = $tmp
    $script:Pins = @($list)
    Save-Config
    Refresh-Rows -force
}

# Commit a drag-reorder. Flat view: move the dragged session to the slot under
# where it was dropped. Grouped view: also move it into whichever group's band it
# was dropped on (or out of any group if dropped on the Ungrouped band).
function Commit-Drag {
    $sid = [string]$script:dragSid
    $dropMid = $script:dragRow.Top + [int]($RowH / 2)

    if (-not $script:LayoutGrouped) {
        $list = @($script:Pins)
        $from = [array]::IndexOf($list, $sid)
        if ($from -lt 0) { Refresh-Rows -force; return }
        $target = [int][Math]::Round(($script:dragRow.Top - 4) / $RowH)
        if ($target -lt 0) { $target = 0 }
        if ($target -gt ($list.Count - 1)) { $target = $list.Count - 1 }
        if ($target -ne $from) {
            $al = New-Object System.Collections.ArrayList
            [void]$al.AddRange($list)
            $item = $al[$from]; $al.RemoveAt($from); $al.Insert($target, $item)
            $script:Pins = @($al.ToArray())
            Save-Config
        }
        Refresh-Rows -force
        return
    }

    # ---- grouped: find the target group band the drop landed in ----
    $tg = $script:LayoutGroups[0]
    foreach ($g in $script:LayoutGroups) { if ($g.top -le $dropMid) { $tg = $g } }
    if (-not $tg) { Refresh-Rows -force; return }
    $targetKey = [string]$tg.name
    $targetIsUng = [bool]$tg.isUngrouped

    # Existing members of that group (in pins order), excluding the dragged one.
    if ($targetIsUng) {
        $existing = @($script:Pins | Where-Object { -not (Get-GroupOf $_) -and $_ -ne $sid })
    } else {
        $existing = @($script:Pins | Where-Object { (Get-GroupOf $_) -eq $targetKey -and $_ -ne $sid })
    }

    # Insertion index = how many of the target group's rendered rows sit above the drop.
    $grows = @($script:LayoutRows | Where-Object { $_.group -eq $targetKey -and $_.sid -ne $sid } | Sort-Object top)
    $idx = 0
    foreach ($r in $grows) { if (($r.top + [int]($RowH / 2)) -lt $dropMid) { $idx++ } }
    if ($idx -gt $existing.Count) { $idx = $existing.Count }

    # New ordering of the target group's members with the dragged sid inserted.
    $al = New-Object System.Collections.ArrayList
    foreach ($m in $existing) { [void]$al.Add($m) }
    [void]$al.Insert($idx, $sid)
    $newMembers = @($al.ToArray())

    # Update membership, then rebuild pins as the flattened group order.
    if ($targetIsUng) {
        if ($script:Groups.ContainsKey($sid)) { $script:Groups.Remove($sid) }
    } else {
        $script:Groups[$sid] = $targetKey
    }

    $result = @()
    foreach ($g in @($script:GroupOrder)) {
        if ($g -eq $targetKey) { $result += $newMembers }
        else { $result += @($script:Pins | Where-Object { (Get-GroupOf $_) -eq $g -and $_ -ne $sid }) }
    }
    if ($targetIsUng) { $result += $newMembers }
    else { $result += @($script:Pins | Where-Object { -not (Get-GroupOf $_) -and $_ -ne $sid }) }
    $script:Pins = @($result)

    Normalize-Groups
    Save-Config
    Refresh-Rows -force
}

# ------------------------------------------------------------ menu (≡) ------
$btnMenu.Add_Click({
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    Style-Menu $menu
    $all = Get-Sessions

    $hdr = New-Object System.Windows.Forms.ToolStripMenuItem('Pin sessions to watch:')
    $hdr.Enabled = $false
    [void]$menu.Items.Add($hdr)

    # List the union of detected sessions ($all) and everything currently pinned,
    # so every session shown in the panel also appears here (checked) and can be
    # toggled off. Pins that are idle/backgrounded (gone from $all) are resolved
    # from the cached identity.
    $seen = @{}
    $entries = @()
    foreach ($sid in (@($all.Keys) + @($script:Pins))) {
        if ($seen.ContainsKey($sid)) { continue }
        $seen[$sid] = $true
        $s = if ($all.ContainsKey($sid)) { $all[$sid] } else { Resolve-Pin $sid $all }
        $entries += [pscustomobject]@{ sid = $sid; s = $s }
    }
    if ($entries.Count -eq 0) {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem('(no sessions detected)')
        $none.Enabled = $false
        [void]$menu.Items.Add($none)
    }
    $entries = @($entries | Sort-Object { -([int][bool]$_.s.live) }, { [string]$_.s.project })
    foreach ($en in $entries) {
        $sid = $en.sid; $s = $en.s
        $st = Get-StateStyle $s.state $s.live
        $tag = if ($s.live) { $st.label } else { 'ended' }
        # Show the pinned state as a leading check glyph in the text. The native
        # ToolStripMenuItem.Checked mark lives in the image/check margin, which we
        # hide (ShowImageMargin = false) to kill the white gutter, so we draw our
        # own. Unpinned items get a same-width blank to keep the labels aligned.
        $mark = if ($script:Pins -contains $sid) { [char]0x2713 } else { ' ' }
        $label = ('{0}  {1}  [{2}]' -f $mark, (Get-Display $sid $s), $tag)
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($label)
        $item.Tag = $sid
        $item.Add_Click({ Toggle-Pin $this.Tag }.GetNewClosure())
        [void]$menu.Items.Add($item)
    }

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $clean = New-Object System.Windows.Forms.ToolStripMenuItem('Unpin ended sessions')
    $clean.Add_Click({
        $all2 = Get-Sessions
        # Keep any pin that resolves to a non-ended row (live session, or an idle
        # conversation whose transcript still exists); drop only truly ended ones.
        $script:Pins = @($script:Pins | Where-Object { (Resolve-Pin $_ $all2).state -ne 'ended' })
        Normalize-Groups
        Save-Config
        Refresh-Rows -force
    })
    [void]$menu.Items.Add($clean)
    $themeItem = New-Object System.Windows.Forms.ToolStripMenuItem(
        $(if ($script:Theme -eq 'light') { 'Switch to dark theme' } else { 'Switch to light theme' }))
    $themeItem.Add_Click({
        $script:Theme = if ($script:Theme -eq 'light') { 'dark' } else { 'light' }
        Save-Config
        Apply-Theme
    })
    [void]$menu.Items.Add($themeItem)
    $quit = New-Object System.Windows.Forms.ToolStripMenuItem('Close panel')
    $quit.Add_Click({ $form.Close() })
    [void]$menu.Items.Add($quit)

    $menu.Show($btnMenu, (New-Object System.Drawing.Point(0, $TitleH)))
})

# --------------------------------------------------------- render rows ------
$script:lastSig = '__init__'

function Refresh-Rows {
    param([switch]$force)

    # Never rebuild while a row is being dragged: clearing/recreating the rows
    # would destroy the control under the cursor and freeze the drag. The drag's
    # own MouseUp (Commit-Drag) re-renders once it finishes.
    if ($script:dragRowOn) { return }

    $all = Get-Sessions

    # Apply in-session "#name"/"#group" commands. A live session that has been
    # given a label or a group is auto-pinned (once: AutoPinned remembers it, and
    # a later manual unpin sticks). "#group" is applied as a latch via GroupCmd:
    # we only (re)assign the group when the requested value changes, so a manual
    # drag to a different group afterwards is never overridden.
    $cfgChanged = $false
    foreach ($k in @($all.Keys)) {
        $sv = $all[$k]
        if (-not $sv.live) { continue }
        if (-not $sv.title -and -not $sv.group) { continue }
        if (($script:Pins -notcontains $k) -and (-not $script:AutoPinned.ContainsKey($k))) {
            $script:Pins = @($script:Pins) + $k
            $script:AutoPinned[$k] = $true
            $cfgChanged = $true
        }
        if (($script:Pins -contains $k) -and $sv.group) {
            $want = [string]$sv.group
            if ($script:GroupCmd[$k] -ne $want) {
                if ($want.Length -gt 40) { $want = $want.Substring(0, 40) }
                $script:Groups[$k] = $want
                if ($script:GroupOrder -notcontains $want) { $script:GroupOrder = @($script:GroupOrder) + $want }
                $script:GroupCmd[$k] = $want
                $cfgChanged = $true
            }
        }
    }
    if ($cfgChanged) { Normalize-Groups; Save-Config }

    # Compact mode: one line. A small status dot per pinned session (so you can
    # see they're all still here, colored by state) plus text: the top session
    # that needs you (permission first), else just the session count. Click
    # anywhere to expand; hover a dot to name it.
    if ($script:Compact) {
        $items = @()
        $i = 0
        foreach ($sid in @($script:Pins)) {
            $s  = Resolve-Pin $sid $all
            $st = Get-StateStyle $s.state $s.live
            $att = if ($s.state -eq 'permission') { 1 } elseif ($s.state -eq 'ask') { 2 } else { 0 }
            $items += [pscustomobject]@{ sid = $sid; s = $s; st = $st; ord = $i; att = $att }
            $i++
        }
        $attn  = @($items | Where-Object { $_.att -gt 0 } | Sort-Object att, ord)
        $total = $items.Count

        $stateSig = ($items | ForEach-Object { '{0}:{1}:{2}' -f $_.sid, $_.s.state, $_.s.live }) -join ','
        $csig = 'CD|{0}|{1}' -f $stateSig, $(if ($attn.Count) { '{0}:{1}' -f $attn[0].sid, $attn.Count } else { '0' })
        if ($script:pinInfoDirty) { Save-Config; $script:pinInfoDirty = $false }
        if (-not $force -and $csig -eq $script:lastSig) { return }
        $script:lastSig = $csig

        $content.SuspendLayout()
        $content.Controls.Clear()
        $expand = { Set-Compact $false }

        if ($total -eq 0) {
            $hint = New-Object System.Windows.Forms.Label
            $hint.Text = 'No sessions pinned.  Click  ' + [char]0x2261 + '  to pick.'
            $hint.ForeColor = $cDim; $hint.Font = $fState; $hint.AutoSize = $false
            $hint.Dock = 'Fill'; $hint.TextAlign = 'MiddleCenter'
            $content.Controls.Add($hint)
        } else {
            $row = New-Object System.Windows.Forms.Panel
            $row.Location = New-Object System.Drawing.Point(0, 4)
            $row.Size = New-Object System.Drawing.Size($W, $RowH)
            $row.BackColor = $cBg; $row.Cursor = 'Hand'
            $row.Add_Click($expand)

            $x = 10
            foreach ($it in $items) {
                $d = New-Object System.Windows.Forms.Label
                $d.Text = [char]0x25CF; $d.ForeColor = $it.st.color; $d.Font = $fIcon
                $d.AutoSize = $false; $d.Location = New-Object System.Drawing.Point($x, 0)
                $d.Size = New-Object System.Drawing.Size(14, $RowH); $d.TextAlign = 'MiddleCenter'
                $d.Cursor = 'Hand'; $d.Add_Click($expand)
                $script:tip.SetToolTip($d, ('{0} - {1}' -f (Get-Display $it.sid $it.s), $it.st.label))
                $row.Controls.Add($d)
                $x += 14
            }

            if ($attn.Count) {
                $top = $attn[0]
                $txt = if ($attn.Count -gt 1) { '{0} · {1} · {2}' -f (Get-Display $top.sid $top.s), $top.st.label, $attn.Count }
                       else { '{0} · {1}' -f (Get-Display $top.sid $top.s), $top.st.label }
                $txtColor = $top.st.color
            } else {
                $txt = '{0} session{1}' -f $total, $(if ($total -eq 1) { '' } else { 's' })
                $txtColor = $cDim
            }
            $tx = [Math]::Min($x + 8, $W - 60)
            $lbl = New-Object System.Windows.Forms.Label
            $lbl.Text = $txt; $lbl.ForeColor = $txtColor; $lbl.Font = $fState
            $lbl.AutoSize = $false; $lbl.AutoEllipsis = $true
            $lbl.Location = New-Object System.Drawing.Point($tx, 0)
            $lbl.Size = New-Object System.Drawing.Size(($W - $tx - 10), $RowH); $lbl.TextAlign = 'MiddleLeft'
            $lbl.Cursor = 'Hand'; $lbl.Add_Click($expand)
            $row.Controls.Add($lbl)

            $content.Controls.Add($row)
        }
        $form.Height = $TitleH + $RowH + 8
        $content.ResumeLayout()
        return
    }

    # Never permanently unpin a session just because it vanished from $all. An
    # ended session loses its sessions/<pid>.json and its status file, so it
    # would otherwise be dropped forever instead of shown as "Ended". Pins are
    # only removed via the explicit "Unpin ended sessions" menu or per-row Unpin.

    # Build the render plan (group blocks) and a signature to avoid needless
    # rebuilds. Resolve every pin (so pinInfo caching still runs) but only render
    # members of expanded groups.
    $ordered = Get-OrderedGroups
    $grouped = ($script:GroupOrder.Count -gt 0)
    $sigParts = @()
    foreach ($blk in $ordered) {
        $col = if ($script:Collapsed.ContainsKey($blk.name) -and $script:Collapsed[$blk.name]) { 1 } else { 0 }
        $sigParts += ('H:{0}:{1}:{2}:{3}' -f $blk.name, $blk.hasHeader, $col, $blk.members.Count)
        foreach ($sid in $blk.members) {
            $s = Resolve-Pin $sid $all
            $nm = if ($script:Names.ContainsKey($sid)) { $script:Names[$sid] } else { '' }
            $sigParts += ('{0}:{1}:{2}:{3}:{4}' -f $sid, $s.state, $s.live, $s.title, $nm)
        }
    }
    $sig = $sigParts -join '|'
    if ($script:pinInfoDirty) { Save-Config; $script:pinInfoDirty = $false }
    if (-not $force -and $sig -eq $script:lastSig) { return }
    $script:lastSig = $sig

    $content.SuspendLayout()
    $content.Controls.Clear()

    if (@($script:Pins).Count -eq 0) {
        $hint = New-Object System.Windows.Forms.Label
        $hint.Text      = 'No sessions pinned.  Click  ' + [char]0x2261 + '  to pick.'
        $hint.ForeColor = $cDim
        $hint.Font      = $fState
        $hint.AutoSize  = $false
        $hint.Dock      = 'Fill'
        $hint.TextAlign = 'MiddleCenter'
        $content.Controls.Add($hint)
        $form.Height = $TitleH + $RowH + 8
        $content.ResumeLayout()
        return
    }

    # Layout maps captured for group-aware drag-and-drop: where each member row
    # and each group header sits vertically, so a drop can be mapped to a target
    # group + insertion index.
    $script:LayoutRows    = @()
    $script:LayoutGroups  = @()
    $script:LayoutGrouped = $grouped

    # Drag handlers are defined ONCE here as plain (non-closure) scriptblocks so
    # their inline `$script:` writes hit the real script scope (a GetNewClosure
    # block would write to its own captured scope, leaving onMove/onUp blind).
    # Per-row data is carried on each control's .Tag instead of a closure.
    $onDown = {
        param($snd, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $info = $snd.Tag
        if (-not $info) { return }
        $script:dragSid     = $info.sid
        $script:dragRow     = $info.row
        $script:dragOrigTop = $info.row.Top
        $script:dragStartY  = [System.Windows.Forms.Cursor]::Position.Y
        $script:dragRowOn   = $true
        $info.row.BringToFront()
    }
    $onMove = {
        param($snd, $e)
        if (-not $script:dragRowOn) { return }
        $dy = [System.Windows.Forms.Cursor]::Position.Y - $script:dragStartY
        $script:dragRow.Top = $script:dragOrigTop + $dy
    }
    $onUp = {
        param($snd, $e)
        if (-not $script:dragRowOn) { return }
        $script:dragRowOn = $false
        if ($script:dragRow.Top -ne $script:dragOrigTop) { Commit-Drag }
    }

    $y = 4
    foreach ($blk in $ordered) {
        $collapsed = ($script:Collapsed.ContainsKey($blk.name) -and $script:Collapsed[$blk.name])

        # ---- group header ----
        if ($blk.hasHeader) {
            $grpName = $blk.name
            $gIdx = [array]::IndexOf(@($script:GroupOrder), $grpName)
            $chev = if ($collapsed) { [char]0x25B8 } else { [char]0x25BE }   # > / v

            $hp = New-Object System.Windows.Forms.Panel
            $hp.Location  = New-Object System.Drawing.Point(0, $y)
            $hp.Size      = New-Object System.Drawing.Size($W, $HeaderH)
            $hp.BackColor = $cBar
            $script:LayoutGroups += , ([pscustomobject]@{ name = $grpName; top = $y; isUngrouped = $blk.isUngrouped })

            $hl = New-Object System.Windows.Forms.Label
            $hl.Text      = ('{0}  {1}  ({2})' -f $chev, $grpName, $blk.members.Count)
            $hl.ForeColor = $cDim
            $hl.Font      = $fGroup
            $hl.AutoSize  = $false
            $hl.Location  = New-Object System.Drawing.Point(8, 0)
            $hl.Size      = New-Object System.Drawing.Size(($W - 16), $HeaderH)
            $hl.TextAlign = 'MiddleLeft'
            $hl.Cursor    = 'Hand'
            $hp.Controls.Add($hl)

            $toggle = { Toggle-Collapse $grpName }.GetNewClosure()
            $hp.Add_Click($toggle); $hl.Add_Click($toggle)

            # Ungrouped is a synthetic block: collapsible, but not renamable/movable.
            if (-not $blk.isUngrouped) {
                $hMenu = New-Object System.Windows.Forms.ContextMenuStrip
                Style-Menu $hMenu
                $hRen = New-Object System.Windows.Forms.ToolStripMenuItem('Rename group...')
                $hRen.Add_Click({ Rename-Group $grpName }.GetNewClosure())
                [void]$hMenu.Items.Add($hRen)
                [void]$hMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
                $hUp = New-Object System.Windows.Forms.ToolStripMenuItem('Move group up')
                $hUp.Enabled = ($gIdx -gt 0)
                $hUp.Add_Click({ Move-Group $grpName -1 }.GetNewClosure())
                [void]$hMenu.Items.Add($hUp)
                $hDn = New-Object System.Windows.Forms.ToolStripMenuItem('Move group down')
                $hDn.Enabled = ($gIdx -lt (@($script:GroupOrder).Count - 1))
                $hDn.Add_Click({ Move-Group $grpName 1 }.GetNewClosure())
                [void]$hMenu.Items.Add($hDn)
                $hp.ContextMenuStrip = $hMenu; $hl.ContextMenuStrip = $hMenu
            }

            $content.Controls.Add($hp)
            $y += $HeaderH
            if ($collapsed) { continue }
        }

        # ---- member rows ----
        $indent = if ($blk.hasHeader) { 16 } else { 0 }
        $mCount = $blk.members.Count
        $mIdx = 0
        foreach ($sid in $blk.members) {
            $s = Resolve-Pin $sid $all
            $st = Get-StateStyle $s.state $s.live

            $row = New-Object System.Windows.Forms.Panel
            $row.Location  = New-Object System.Drawing.Point(0, $y)
            $row.Size      = New-Object System.Drawing.Size($W, $RowH)
            $row.BackColor = $cBg
            $script:LayoutRows += , ([pscustomobject]@{ sid = $sid; group = $blk.name; top = $y })

            $dot = New-Object System.Windows.Forms.Label
            $dot.Text      = [char]0x25CF   # filled circle
            $dot.ForeColor = $st.color
            $dot.Font      = $fIcon
            $dot.AutoSize  = $false
            $dot.Location  = New-Object System.Drawing.Point((10 + $indent), 0)
            $dot.Size      = New-Object System.Drawing.Size(18, $RowH)
            $dot.TextAlign = 'MiddleCenter'
            $row.Controls.Add($dot)

            $display = Get-Display $sid $s
            $name = New-Object System.Windows.Forms.Label
            $name.Text         = $display
            $name.ForeColor    = $cText
            $name.Font         = $fName
            $name.AutoSize     = $false
            $name.AutoEllipsis = $true
            $name.Location     = New-Object System.Drawing.Point((32 + $indent), 0)
            $name.Size         = New-Object System.Drawing.Size((150 - $indent), $RowH)
            $name.TextAlign    = 'MiddleLeft'
            $row.Controls.Add($name)
            $shortId = $sid.Substring(0, [Math]::Min(8, $sid.Length))
            $tipText = "{0}`r`nid {1}`r`nRight-click: rename, group, reorder.  Or type  #name <label>  in the session." -f $s.project, $shortId
            $script:tip.SetToolTip($name, $tipText)
            $script:tip.SetToolTip($dot, $tipText)

            $stt = New-Object System.Windows.Forms.Label
            $stt.Text      = $st.label
            $stt.ForeColor = $st.color
            $stt.Font      = $fState
            $stt.AutoSize  = $false
            $stt.Location  = New-Object System.Drawing.Point(182, 0)
            $stt.Size      = New-Object System.Drawing.Size(($W - 188), $RowH)
            $stt.TextAlign = 'MiddleRight'
            $row.Controls.Add($stt)

            # Right-click menu for this row: rename / group / reorder / unpin.
            $rowMenu = New-Object System.Windows.Forms.ContextMenuStrip
            Style-Menu $rowMenu
            $miRename = New-Object System.Windows.Forms.ToolStripMenuItem('Rename...')
            $miRename.Add_Click({ Set-Name $sid $display }.GetNewClosure())
            [void]$rowMenu.Items.Add($miRename)
            if ($script:Names.ContainsKey($sid)) {
                $miReset = New-Object System.Windows.Forms.ToolStripMenuItem('Use auto title')
                $miReset.Add_Click({ Clear-Name $sid }.GetNewClosure())
                [void]$rowMenu.Items.Add($miReset)
            }
            [void]$rowMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

            # Add to group -> existing groups + New group...
            $miAdd = New-Object System.Windows.Forms.ToolStripMenuItem('Add to group')
            # Submenu items do NOT inherit the parent menu's ForeColor, so on the
            # dark background their default (black) text is invisible. Style the
            # dropdown and set each item's color explicitly.
            $miAdd.DropDown.BackColor       = $cBar
            $miAdd.DropDown.ForeColor       = $cText
            $miAdd.DropDown.ShowImageMargin = $false
            $curG = Get-GroupOf $sid
            foreach ($gname in @($script:GroupOrder)) {
                $mark = if ($curG -eq $gname) { [char]0x2713 + ' ' } else { '' }
                $sub = New-Object System.Windows.Forms.ToolStripMenuItem(($mark + $gname))
                $sub.ForeColor = $cText
                $sub.Add_Click({ Set-Group $sid $gname }.GetNewClosure())
                [void]$miAdd.DropDownItems.Add($sub)
            }
            if (@($script:GroupOrder).Count -gt 0) { [void]$miAdd.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }
            $miNew = New-Object System.Windows.Forms.ToolStripMenuItem('New group...')
            $miNew.ForeColor = $cText
            $miNew.Add_Click({ New-GroupFor $sid }.GetNewClosure())
            [void]$miAdd.DropDownItems.Add($miNew)
            [void]$rowMenu.Items.Add($miAdd)
            if ($curG) {
                $miRem = New-Object System.Windows.Forms.ToolStripMenuItem('Remove from group')
                $miRem.Add_Click({ Remove-FromGroup $sid }.GetNewClosure())
                [void]$rowMenu.Items.Add($miRem)
            }
            [void]$rowMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

            $miUp = New-Object System.Windows.Forms.ToolStripMenuItem('Move up')
            $miUp.Enabled = ($mIdx -gt 0)
            $miUp.Add_Click({ Move-Pin $sid -1 }.GetNewClosure())
            [void]$rowMenu.Items.Add($miUp)
            $miDown = New-Object System.Windows.Forms.ToolStripMenuItem('Move down')
            $miDown.Enabled = ($mIdx -lt ($mCount - 1))
            $miDown.Add_Click({ Move-Pin $sid 1 }.GetNewClosure())
            [void]$rowMenu.Items.Add($miDown)
            [void]$rowMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
            $miUnpin = New-Object System.Windows.Forms.ToolStripMenuItem('Unpin')
            $miUnpin.Add_Click({ Toggle-Pin $sid }.GetNewClosure())
            [void]$rowMenu.Items.Add($miUnpin)
            $row.ContextMenuStrip  = $rowMenu
            $name.ContextMenuStrip = $rowMenu
            $dot.ContextMenuStrip  = $rowMenu
            $stt.ContextMenuStrip  = $rowMenu

            # Left-drag to reorder. In the flat view it just reorders; once groups
            # exist, dropping a row into another group's band also moves it into
            # that group (and dropping into the Ungrouped band removes it).
            $dragInfo = @{ row = $row; sid = $sid }
            foreach ($c in @($row, $dot, $name, $stt)) {
                $c.Cursor = 'SizeAll'
                $c.Tag = $dragInfo
                $c.Add_MouseDown($onDown); $c.Add_MouseMove($onMove); $c.Add_MouseUp($onUp)
            }

            $content.Controls.Add($row)
            $y += $RowH
            $mIdx++
        }
    }
    $form.Height = $TitleH + $y + 6

    $content.ResumeLayout()
}

# ----------------------------------------------------------- refresh timer --
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1500
$timer.Add_Tick({ Refresh-Rows })
$timer.Start()

$form.Add_Shown({ Refresh-Rows -force })
$form.Add_FormClosing({
    $script:PosX = $form.Location.X
    $script:PosY = $form.Location.Y
    Save-Config
    $timer.Stop()
})

[void][System.Windows.Forms.Application]::Run($form)
