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

    $j = $raw | ConvertFrom-Json
    $sid = $j.session_id
    if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }

    $dir = Join-Path $env:USERPROFILE '.claude\session-status'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ($sid + '.json')

    # Session ended: remove the status file and bail.
    if ($Event -eq 'end') {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
        exit 0
    }

    $state = $Event          # running | done | idle  (passed verbatim)
    $message = ''

    if ($Event -eq 'notify') {
        switch ($j.notification_type) {
            'permission_prompt' { $state = 'permission' }
            'idle_prompt'       { $state = 'idle' }
            default             { $state = 'idle' }
        }
        if ($j.message) { $message = [string]$j.message }
    }

    $cwd = [string]$j.cwd
    $proj = ''
    if ($cwd) { $proj = Split-Path $cwd -Leaf }

    # Preserve an existing auto-title across subsequent events.
    $title = ''
    if (Test-Path $file) {
        try {
            $prev = Get-Content $file -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($prev.title) { $title = [string]$prev.title }
        } catch { }
    }
    # On the first user prompt, derive a title from it (same idea as the app's
    # auto-generated title). Only set it once; later prompts don't overwrite.
    if ([string]::IsNullOrWhiteSpace($title) -and $j.prompt) {
        $p = (([string]$j.prompt) -replace '\s+', ' ').Trim()
        if ($p.Length -gt 48) { $p = $p.Substring(0, 48) + [char]0x2026 }
        $title = $p
    }

    $obj = [ordered]@{
        sessionId = $sid
        cwd       = $cwd
        project   = $proj
        title     = $title
        state     = $state
        message   = $message
        updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }

    # Write atomically (write tmp, then move over) so the panel never reads a
    # half-written file.
    $tmp = $file + '.tmp'
    ($obj | ConvertTo-Json -Compress) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force -Path $tmp -Destination $file
}
catch { }

exit 0
