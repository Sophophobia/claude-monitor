# Claude Monitor

> A status light for your Claude Code sessions.

A small always-on-top, draggable floating panel that shows the live state of the
Claude Code sessions you pin. Zero install: pure PowerShell + WinForms.

This whole folder is self-contained and portable: copy it to another machine and
run `install.ps1`.

## How it works

```
Claude Code session --(hooks)--> status-hook.ps1 --> ~/.claude/session-status/<id>.json
                                                              |
                                          panel.ps1 (reads every 1.5s) --> floating panel
```

- **Hooks** in `~/.claude/settings.json` fire on session events and run
  `status-hook.ps1`, which writes one tiny JSON file per session.
- **`panel.ps1`** reads those files (plus `~/.claude/sessions/*.json` for
  liveness) and draws the panel.

## Files

| File | Role |
|---|---|
| `install.ps1` | One-shot setup for this machine. Merges the hooks into `~/.claude/settings.json` with this machine's paths. Re-runnable / non-destructive. |
| `status-hook.ps1` | Invoked by hooks. Writes `~/.claude/session-status/<session_id>.json`. Never blocks Claude (always exits 0). |
| `panel.ps1` | The floating WinForms panel. |
| `start-panel.vbs` | Launches the panel with no console window. |
| `config.json` | Auto-created. Stores pinned session ids, window position, and custom names. |

## States

| Dot | Meaning | Triggered by hook |
|---|---|---|
| Blue `Running` | Claude is working | `UserPromptSubmit` |
| Red `Needs permission` | Waiting for you to approve | `Notification` (permission_prompt) |
| Green `Your turn` | Finished its turn | `Stop` |
| Amber `Idle` | Idle, waiting for input | `Notification` (idle_prompt) / `SessionStart` |
| Gray `Ended` | Session closed / process gone | `SessionEnd` or pid no longer running |

## Session labels

Each row is labelled with an **auto-title** taken from the session's first
prompt (the same idea as the desktop app's auto-generated titles). The folder
name is the fallback when no title is known.

To set your own label, **right-click a row -> Rename**. The custom name is saved
in `config.json` (keyed by session id) and overrides the auto-title. Right-click
-> "Use auto title" clears it. Label priority: custom name > auto-title > folder.

> The desktop app's own sidebar titles live in the app's IndexedDB keyed by an
> internal `local_<uuid>` id, which is a different id space from the CLI
> `session_id` these hooks see, and the app does not expose the mapping. So
> Claude Monitor generates its own label rather than reading the app's.

## Usage

1. **Launch the panel** - double-click `start-panel.vbs`
   (or `powershell -NoProfile -ExecutionPolicy Bypass -Sta -File panel.ps1`).
2. **Pick sessions** - click the menu button, tick the sessions you want to watch.
   Pins persist across restarts.
3. **Rename a session** - right-click its row -> Rename.
4. **Move it** - drag the title bar anywhere. Position is remembered.
5. **Close** - click the X (panel only; hooks keep running and cost ~nothing).

## Install / set up on another machine

1. Copy this whole folder to the new machine (anywhere you like).
2. Run setup once:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"
   ```
   Add `-Startup` to also launch the panel automatically at login:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1" -Startup
   ```
3. Restart any open Claude Code sessions so the hooks take effect.
4. Double-click `start-panel.vbs`.

`install.ps1` figures out its own folder, so the hook paths are always correct
for that machine regardless of username or install location. It backs up any
existing `settings.json` to `settings.json.bak` and preserves other hooks.

> `~/.claude/settings.json` is per-user/per-device and is **not** synced between
> machines, which is why each machine needs `install.ps1` run once.

## Notes / limitations

- State only updates for sessions started **after** the hooks were added to
  `settings.json`. Restart any open sessions to pick them up.
- After you approve a permission prompt, the row stays `Needs permission` until
  the turn finishes (`Stop` -> `Your turn`). There is no per-tool event wired up,
  to keep hook latency near zero.
- A pinned session that ends shows `Ended`; use the menu ->
  "Unpin ended sessions" to clear them.
