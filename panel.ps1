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

# --------------------------------------------------------------- config -----
$script:Pins  = @()
$script:PosX  = $null
$script:PosY  = $null
$script:Names = @{}   # sessionId -> custom display name (overrides the auto-title)

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
        }
    } catch { }
}

function Save-Config {
    try {
        $obj = [ordered]@{
            pins  = @($script:Pins)
            x     = $script:PosX
            y     = $script:PosY
            names = $script:Names
        }
        ($obj | ConvertTo-Json -Compress) | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch { }
}

# Display label priority: custom name > auto-title (first prompt) > project folder.
function Get-Display($sid, $s) {
    if ($script:Names.ContainsKey($sid) -and $script:Names[$sid]) { return $script:Names[$sid] }
    if ($s.title) { return $s.title }
    return $s.project
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
                    sid       = $sid
                    project   = $proj
                    cwd       = [string]$j.cwd
                    title     = ''
                    state     = 'idle'
                    message   = ''
                    live      = $isLive
                    updatedAt = 0
                }
            } catch { }
        }
    }

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
                    if ($j.title) { $map[$sid].title = [string]$j.title }
                    if (-not $map[$sid].project -and $j.project) { $map[$sid].project = [string]$j.project }
                    if (-not $map[$sid].cwd -and $j.cwd) { $map[$sid].cwd = [string]$j.cwd }
                } else {
                    # Status file with no live session record -> treat as ended.
                    $map[$sid] = [pscustomobject]@{
                        sid       = $sid
                        project   = [string]$j.project
                        cwd       = [string]$j.cwd
                        title     = [string]$j.title
                        state     = [string]$j.state
                        message   = [string]$j.message
                        live      = $false
                        updatedAt = [long]$j.updatedAt
                    }
                }
            } catch { }
        }
    }

    return $map
}

# state -> color + label
function Get-StateStyle($state, $live) {
    if (-not $live) {
        return @{ color = [System.Drawing.Color]::FromArgb(107,114,128); label = 'Ended' }   # gray
    }
    switch ($state) {
        'running'    { return @{ color = [System.Drawing.Color]::FromArgb(59,130,246);  label = 'Running' } }       # blue
        'permission' { return @{ color = [System.Drawing.Color]::FromArgb(239,68,68);   label = 'Needs permission' } } # red
        'done'       { return @{ color = [System.Drawing.Color]::FromArgb(34,197,94);   label = 'Your turn' } }     # green
        'idle'       { return @{ color = [System.Drawing.Color]::FromArgb(245,158,11);  label = 'Idle' } }          # amber
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
        $lbl2 = Get-Display $sid $s
        $disp = if ($lbl2 -ne $s.project) { '{0}: {1}' -f $s.project, $lbl2 } else { $s.project }
        $label = ('{0}  ({1})  [{2}]' -f $disp, $sid.Substring(0, [Math]::Min(8,$sid.Length)), $tag)
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
        $script:Pins = @($script:Pins | Where-Object { $all2.ContainsKey($_) -and $all2[$_].live })
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

    # Auto-drop pins whose session vanished entirely (no status file, no live record).
    $known = @($script:Pins | Where-Object { $all.ContainsKey($_) })
    if (@($known).Count -ne @($script:Pins).Count) {
        $script:Pins = $known
        Save-Config
    }

    # Signature to avoid needless rebuilds (no flicker when nothing changed).
    $sig = ($script:Pins | ForEach-Object {
        $s = $all[$_]
        if ($s) {
            $nm = if ($script:Names.ContainsKey($_)) { $script:Names[$_] } else { '' }
            '{0}:{1}:{2}:{3}:{4}' -f $_, $s.state, $s.live, $s.title, $nm
        } else { "$_:gone" }
    }) -join '|'
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
        foreach ($sid in $rows) {
            $s = $all[$sid]
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
            $auto = if ($s.title) { $s.title } else { $s.project }
            $tipText = "{0}`r`n{1}`r`n{2}" -f $s.project, $auto, ("id " + $shortId + "   (right-click to rename)")
            $script:tip.SetToolTip($name, $tipText.Trim())
            $script:tip.SetToolTip($dot, $tipText.Trim())

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
            $miUnpin = New-Object System.Windows.Forms.ToolStripMenuItem('Unpin')
            $miUnpin.Add_Click({ Toggle-Pin $sid }.GetNewClosure())
            [void]$rowMenu.Items.Add($miUnpin)
            $row.ContextMenuStrip  = $rowMenu
            $name.ContextMenuStrip = $rowMenu
            $dot.ContextMenuStrip  = $rowMenu
            $stt.ContextMenuStrip  = $rowMenu

            $content.Controls.Add($row)
            $y += $RowH
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
