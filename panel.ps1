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
Add-Type -AssemblyName Microsoft.VisualBasic   # InputBox for the Rename dialog
[System.Windows.Forms.Application]::EnableVisualStyles()

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
        }
    } catch { }
}

function Save-Config {
    try {
        $obj = [ordered]@{
            pins    = @($script:Pins)
            x       = $script:PosX
            y       = $script:PosY
            names   = $script:Names
            pinInfo = $script:PinInfo
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
$cBg     = [System.Drawing.Color]::FromArgb(17,17,19)     # near-black
$cBar    = [System.Drawing.Color]::FromArgb(28,28,32)
$cText   = [System.Drawing.Color]::FromArgb(229,231,235)
$cDim    = [System.Drawing.Color]::FromArgb(148,163,184)
$fName   = New-Object System.Drawing.Font('Segoe UI', 9,  [System.Drawing.FontStyle]::Bold)
$fState  = New-Object System.Drawing.Font('Segoe UI', 8.5)
$fIcon   = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$W       = 290
$TitleH  = 30
$RowH    = 28
$script:tip = New-Object System.Windows.Forms.ToolTip
$script:tip.AutoPopDelay = 8000
$script:tip.InitialDelay = 350

# ----------------------------------------------------------------- form -----
Load-Config

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
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(55,55,62)), 1
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
$title.Size      = New-Object System.Drawing.Size(($W - 80), $TitleH)
$title.TextAlign = 'MiddleLeft'
$bar.Controls.Add($title)

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
    } else {
        $script:Pins = @($script:Pins) + $sid
    }
    Save-Config
    Refresh-Rows -force
}

# ------------------------------------------------------------- renaming -----
function Set-Name($sid, $current) {
    $new = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Custom name for this session (clear and OK, or Cancel, to keep the auto title):",
        "Rename session", $current)
    # InputBox returns '' on Cancel and on an emptied box. Treat empty as "use auto title".
    if ([string]::IsNullOrWhiteSpace($new)) {
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
    $j = $i + $delta
    if ($j -lt 0 -or $j -ge $list.Count) { return }
    $tmp = $list[$i]; $list[$i] = $list[$j]; $list[$j] = $tmp
    $script:Pins = @($list)
    Save-Config
    Refresh-Rows -force
}

# Commit a drag-reorder: move the dragged session to the slot under where it was dropped.
function Commit-Drag {
    $list = @($script:Pins)
    $from = [array]::IndexOf($list, [string]$script:dragSid)
    if ($from -lt 0) { Refresh-Rows -force; return }
    $target = [int][Math]::Round(($script:dragRow.Top - 4) / $RowH)
    if ($target -lt 0) { $target = 0 }
    if ($target -gt ($list.Count - 1)) { $target = $list.Count - 1 }
    if ($target -ne $from) {
        $al = New-Object System.Collections.ArrayList
        [void]$al.AddRange($list)
        $item = $al[$from]
        $al.RemoveAt($from)
        $al.Insert($target, $item)
        $script:Pins = @($al.ToArray())
        Save-Config
    }
    Refresh-Rows -force
}

# ------------------------------------------------------------ menu (≡) ------
$btnMenu.Add_Click({
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.BackColor = $cBar
    $menu.ForeColor = $cText
    $all = Get-Sessions

    $hdr = New-Object System.Windows.Forms.ToolStripMenuItem('Pin sessions to watch:')
    $hdr.Enabled = $false
    [void]$menu.Items.Add($hdr)

    $keys = $all.Keys | Sort-Object { -$all[$_].live }, { $all[$_].project }
    if ($keys.Count -eq 0) {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem('(no sessions detected)')
        $none.Enabled = $false
        [void]$menu.Items.Add($none)
    }
    foreach ($sid in $keys) {
        $s = $all[$sid]
        $st = Get-StateStyle $s.state $s.live
        $tag = if ($s.live) { $st.label } else { 'ended' }
        $label = ('{0}  [{1}]' -f (Get-Display $sid $s), $tag)
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($label)
        $item.Checked = ($script:Pins -contains $sid)
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
        Save-Config
        Refresh-Rows -force
    })
    [void]$menu.Items.Add($clean)
    $quit = New-Object System.Windows.Forms.ToolStripMenuItem('Close panel')
    $quit.Add_Click({ $form.Close() })
    [void]$menu.Items.Add($quit)

    $menu.Show($btnMenu, (New-Object System.Drawing.Point(0, $TitleH)))
})

# --------------------------------------------------------- render rows ------
$script:lastSig = '__init__'

function Refresh-Rows {
    param([switch]$force)

    $all = Get-Sessions

    # Never permanently unpin a session just because it vanished from $all. An
    # ended session loses its sessions/<pid>.json and its status file, so it
    # would otherwise be dropped forever instead of shown as "Ended". Pins are
    # only removed via the explicit "Unpin ended sessions" menu or per-row Unpin.

    # Signature to avoid needless rebuilds (no flicker when nothing changed).
    $sig = ($script:Pins | ForEach-Object {
        $s = Resolve-Pin $_ $all
        $nm = if ($script:Names.ContainsKey($_)) { $script:Names[$_] } else { '' }
        '{0}:{1}:{2}:{3}:{4}' -f $_, $s.state, $s.live, $s.title, $nm
    }) -join '|'
    if ($script:pinInfoDirty) { Save-Config; $script:pinInfoDirty = $false }
    if (-not $force -and $sig -eq $script:lastSig) { return }
    $script:lastSig = $sig

    $content.SuspendLayout()
    $content.Controls.Clear()

    $rows = @($script:Pins)
    if ($rows.Count -eq 0) {
        $hint = New-Object System.Windows.Forms.Label
        $hint.Text      = 'No sessions pinned.  Click  ' + [char]0x2261 + '  to pick.'
        $hint.ForeColor = $cDim
        $hint.Font      = $fState
        $hint.AutoSize  = $false
        $hint.Dock      = 'Fill'
        $hint.TextAlign = 'MiddleCenter'
        $content.Controls.Add($hint)
        $form.Height = $TitleH + $RowH + 8
    } else {
        $y = 4
        $rowIdx = 0
        foreach ($sid in $rows) {
            $s = Resolve-Pin $sid $all
            $st = Get-StateStyle $s.state $s.live

            $row = New-Object System.Windows.Forms.Panel
            $row.Location  = New-Object System.Drawing.Point(0, $y)
            $row.Size      = New-Object System.Drawing.Size($W, $RowH)
            $row.BackColor = $cBg

            $dot = New-Object System.Windows.Forms.Label
            $dot.Text      = [char]0x25CF   # filled circle
            $dot.ForeColor = $st.color
            $dot.Font      = $fIcon
            $dot.AutoSize  = $false
            $dot.Location  = New-Object System.Drawing.Point(10, 0)
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
            $name.Location     = New-Object System.Drawing.Point(32, 0)
            $name.Size         = New-Object System.Drawing.Size(150, $RowH)
            $name.TextAlign    = 'MiddleLeft'
            $row.Controls.Add($name)
            $shortId = $sid.Substring(0, [Math]::Min(8, $sid.Length))
            $tipText = "{0}`r`nid {1}`r`nDrag to reorder. Rename: right-click, or type  #name <label>  in the session." -f $s.project, $shortId
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

            # Right-click menu for this row: rename / reset / unpin.
            $rowMenu = New-Object System.Windows.Forms.ContextMenuStrip
            $rowMenu.BackColor = $cBar
            $rowMenu.ForeColor = $cText
            $miRename = New-Object System.Windows.Forms.ToolStripMenuItem('Rename...')
            $miRename.Add_Click({ Set-Name $sid $display }.GetNewClosure())
            [void]$rowMenu.Items.Add($miRename)
            if ($script:Names.ContainsKey($sid)) {
                $miReset = New-Object System.Windows.Forms.ToolStripMenuItem('Use auto title')
                $miReset.Add_Click({ Clear-Name $sid }.GetNewClosure())
                [void]$rowMenu.Items.Add($miReset)
            }
            [void]$rowMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
            $miUp = New-Object System.Windows.Forms.ToolStripMenuItem('Move up')
            $miUp.Enabled = ($rowIdx -gt 0)
            $miUp.Add_Click({ Move-Pin $sid -1 }.GetNewClosure())
            [void]$rowMenu.Items.Add($miUp)
            $miDown = New-Object System.Windows.Forms.ToolStripMenuItem('Move down')
            $miDown.Enabled = ($rowIdx -lt ($rows.Count - 1))
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

            # Left-drag a row up/down to reorder it.
            $row.Cursor = 'SizeAll'; $dot.Cursor = 'SizeAll'; $name.Cursor = 'SizeAll'; $stt.Cursor = 'SizeAll'
            $onDown = {
                param($snd, $e)
                if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
                $script:dragSid     = $sid
                $script:dragRow     = $row
                $script:dragOrigTop = $row.Top
                $script:dragStartY  = [System.Windows.Forms.Cursor]::Position.Y
                $script:dragRowOn   = $true
                $row.BringToFront()
            }.GetNewClosure()
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
            foreach ($c in @($row, $dot, $name, $stt)) {
                $c.Add_MouseDown($onDown); $c.Add_MouseMove($onMove); $c.Add_MouseUp($onUp)
            }

            $content.Controls.Add($row)
            $y += $RowH
            $rowIdx++
        }
        $form.Height = $TitleH + $y + 6
    }

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
