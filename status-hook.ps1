<#
  status-hook.ps1
  Invoked by Claude Code hooks. Reads the hook event JSON from stdin and
  writes a tiny per-session status file to ~/.claude/session-status/<session_id>.json
  that the floating panel reads.

  Must NEVER throw / block Claude: everything is wrapped in try/catch and we
  always exit 0.

  Usage (from settings.json hooks):
    powershell -NoProfile -ExecutionPolicy Bypass -File "<this>" -Event running
    powershell -NoProfile -ExecutionPolicy Bypass -File "<this>" -Event done
    powershell -NoProfile -ExecutionPolicy Bypass -File "<this>" -Event idle
    powershell -NoProfile -ExecutionPolicy Bypass -File "<this>" -Event notify
    powershell -NoProfile -ExecutionPolicy Bypass -File "<this>" -Event end
#>
param([Parameter(Mandatory = $true)][string]$Event)

try {
    # Read stdin as raw bytes and decode as UTF-8. Do NOT use [Console]::In,
    # which decodes with the console's OEM code page and mangles non-ASCII
    # (e.g. Chinese prompts) into '?'.
    $stdin = [System.Console]::OpenStandardInput()
    $sr    = New-Object System.IO.StreamReader($stdin, [System.Text.Encoding]::UTF8)
    $raw   = $sr.ReadToEnd()
    $sr.Dispose()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

    # Optional debugging: append every raw payload to
    # ~/.claude/session-status/_debug.log. Enable either by setting
    # $env:CLAUDE_MONITOR_DEBUG=1, or by creating an empty marker file
    # ~/.claude/session-status/_debug.on (no restart needed). Use this to
    # confirm what fields a real permission prompt actually sends (TODO item 1).
    $dbgDir = Join-Path $env:USERPROFILE '.claude\session-status'
    if ($env:CLAUDE_MONITOR_DEBUG -or (Test-Path (Join-Path $dbgDir '_debug.on'))) {
        try {
            if (-not (Test-Path $dbgDir)) { New-Item -ItemType Directory -Path $dbgDir -Force | Out-Null }
            $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'o'), $Event, ($raw -replace '\s+', ' '))
            Add-Content -Path (Join-Path $dbgDir '_debug.log') -Value $line -Encoding UTF8
        } catch { }
    }

    $j = $raw | ConvertFrom-Json
    $sid = $j.session_id
    if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }

    $dir = Join-Path $env:USERPROFILE '.claude\session-status'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ($sid + '.json')
    # A "#name" label is durable session metadata, so it is also stored in its
    # own tiny file that, unlike the status file, is NOT deleted on SessionEnd.
    # The desktop app fires SessionEnd whenever a conversation goes idle, which
    # used to drop the label: the status file (and its title) was deleted, then
    # recreated empty on resume, reverting the panel to the auto name. Keeping
    # the label out-of-band lets us re-inject it after any SessionEnd.
    $labelFile = Join-Path $dir ($sid + '.label')
    # Same idea for the "#group" assignment: durable, survives SessionEnd.
    $groupFile = Join-Path $dir ($sid + '.group')

    # Session ended: remove the status file but KEEP the label so the name
    # survives an idle/backgrounded conversation coming back.
    if ($Event -eq 'end') {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
        exit 0
    }

    # Preserve an existing custom label (set via "#name"), group, prior state, and
    # the last "#name/#group command" stamp (so the panel can tell a freshly
    # issued command from a lingering title and re-pin even if it was unpinned).
    $title = ''
    $group = ''
    $prevState = ''
    $transcriptPath = ''
    $cmdAt = 0
    if (Test-Path $file) {
        try {
            $prev = Get-Content $file -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($prev.title) { $title = [string]$prev.title }
            if ($prev.group) { $group = [string]$prev.group }
            if ($prev.state) { $prevState = [string]$prev.state }
            if ($prev.transcriptPath) { $transcriptPath = [string]$prev.transcriptPath }
            if ($prev.cmdAt) { $cmdAt = [long]$prev.cmdAt }
        } catch { }
    }

    # If the status file carried no title/group (e.g. it was just recreated after
    # a SessionEnd), recover the persisted "#name"/"#group" values from their
    # out-of-band files.
    if (-not $title -and (Test-Path $labelFile)) {
        try { $title = (Get-Content $labelFile -Raw -ErrorAction Stop).Trim() } catch { }
    }
    if (-not $group -and (Test-Path $groupFile)) {
        try { $group = (Get-Content $groupFile -Raw -ErrorAction Stop).Trim() } catch { }
    }

    # The hook payload carries the path to this session's conversation transcript
    # (~/.claude/projects/<mangled-cwd>/<session_id>.jsonl). The panel uses its
    # existence to tell a backgrounded/idle conversation (transcript still on
    # disk -> stay "Waiting") apart from a deleted one (transcript gone ->
    # "Ended"), because the desktop app fires SessionEnd for both. Keep the last
    # known path if a given event omits it.
    if ($j.transcript_path) { $transcriptPath = [string]$j.transcript_path }

    $cwd = [string]$j.cwd
    $proj = ''
    if ($cwd) { $proj = Split-Path $cwd -Leaf }

    # In-session command(s) on UserPromptSubmit. A prompt may set the panel label
    # and/or the group, in any order, e.g.:
    #   #name Frontend refactor
    #   #group Career
    #   #name Frontend refactor #group Career
    # Such a prompt is consumed (blocked below) so Claude never processes it.
    # The values are persisted out-of-band (.label/.group) so they survive the
    # SessionEnd the desktop app fires whenever a conversation goes idle.
    $isMarker = $false
    $setName  = $false
    $setGroup = $false
    if ($Event -eq 'running' -and $j.prompt -and ([string]$j.prompt) -match '^\s*#(name|group)\b') {
        $p = [string]$j.prompt
        if ($p -match '(?i)#name\s+(.+?)(?=\s+#group\b|\s*$)') {
            $v = (($matches[1]) -replace '\s+', ' ').Trim()
            if ($v) {
                # Only append _MMDDYYYY when this name is ALREADY used by ANOTHER
                # session (disambiguation). Scan the other sessions' persisted
                # label files and compare base names (ignoring any _date suffix).
                # If the user already typed a trailing _ddddddd date, leave it.
                if ($v -notmatch '_\d{8}$') {
                    $clash = $false
                    try {
                        foreach ($lf in (Get-ChildItem (Join-Path $dir '*.label') -ErrorAction SilentlyContinue)) {
                            if ($lf.BaseName -eq $sid) { continue }
                            $o = ''
                            try { $o = (Get-Content $lf.FullName -Raw -ErrorAction Stop).Trim() } catch { }
                            if (($o -replace '_\d{8}$', '') -eq $v) { $clash = $true; break }
                        }
                    } catch { }
                    if ($clash) { $v = $v + '_' + (Get-Date -Format 'MMddyyyy') }
                }
                if ($v.Length -gt 60) { $v = $v.Substring(0, 60) }
                $title = $v; $setName = $true
                try { Set-Content -Path $labelFile -Value $title -Encoding UTF8 -NoNewline } catch { }
            }
        }
        if ($p -match '(?i)#group\s+(.+?)(?=\s+#name\b|\s*$)') {
            $v = (($matches[1]) -replace '\s+', ' ').Trim()
            if ($v) {
                if ($v.Length -gt 40) { $v = $v.Substring(0, 40) }
                $group = $v; $setGroup = $true
                try { Set-Content -Path $groupFile -Value $group -Encoding UTF8 -NoNewline } catch { }
            }
        }
        $isMarker = ($setName -or $setGroup)
        # Stamp the command time so the panel re-pins this session on a fresh
        # command even if it was previously unpinned/dismissed.
        if ($isMarker) { $cmdAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    }

    # Map the incoming -Event to a panel state.
    #   running  : Claude is working (prompt submitted, or continuing after a tool)
    #   waiting  : Claude's turn is over / fresh session -> your turn (green)
    #   pending  : a tool is about to run. The panel keeps this blue (Running)
    #              but escalates it to orange "Needs permission" if it stays
    #              pending for more than a few seconds -- the desktop app does
    #              NOT fire a Notification hook for permission prompts, so this
    #              "tool stuck waiting" heuristic is how we detect them.
    #   ask      : an AskUserQuestion tool is open -> needs your answer (purple)
    $state = $Event
    $message = ''
    switch ($Event) {
        'pretool' {
            if (([string]$j.tool_name) -eq 'AskUserQuestion') { $state = 'ask' }
            else { $state = 'pending' }
        }
        'posttool' { $state = 'running' }   # tool finished; Claude keeps working
        'notify' {
            # Bonus path: if a Notification ever does fire, classify it. The
            # payload's `message` is the reliable field; `notification_type` is
            # often absent on the desktop app.
            $ntype = [string]$j.notification_type
            $msg   = [string]$j.message
            if ($msg) { $message = $msg }

            if ($ntype -like 'permission*' -or $msg -match '(?i)permission|needs your (approval|permission)') {
                $state = 'permission'                          # needs your approval
            } elseif ($ntype -eq 'elicitation_dialog') {
                $state = 'ask'                                 # MCP form: needs your answer
            } elseif ($ntype -like 'idle*' -or $msg -match '(?i)waiting for your input|is waiting') {
                $state = 'waiting'                             # waiting, your turn
            } else {
                $state = if ($prevState) { $prevState } else { 'waiting' }
            }
        }
    }
    # A label command is not real work, so keep whatever state we were in.
    if ($isMarker -and $prevState) { $state = $prevState }

    $obj = [ordered]@{
        sessionId      = $sid
        cwd            = $cwd
        project        = $proj
        title          = $title
        group          = $group
        cmdAt          = $cmdAt
        state          = $state
        message        = $message
        transcriptPath = $transcriptPath
        updatedAt      = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }

    # Write atomically (write tmp, then move over) so the panel never reads a
    # half-written file.
    $tmp = $file + '.tmp'
    ($obj | ConvertTo-Json -Compress) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force -Path $tmp -Destination $file

    # If this was a "#name" label command, block the prompt with clean feedback
    # (JSON decision=block, exit 0) so it never reaches Claude. UTF-8 stdout for
    # non-ASCII labels.
    if ($isMarker) {
        $parts = @()
        if ($setName)  { $parts += ('labelled "{0}"' -f $title) }
        if ($setGroup) { $parts += ('grouped under "{0}"' -f $group) }
        $resp  = @{ decision = 'block'; reason = ('Claude Monitor: session ' + ($parts -join ', ')) } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
        $out   = [System.Console]::OpenStandardOutput()
        $out.Write($bytes, 0, $bytes.Length)
        $out.Flush()
    }
}
catch { }

exit 0
