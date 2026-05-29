# Claude Monitor

> A status light for your Claude Code sessions.

A small always-on-top, draggable floating panel that shows the live state of the
Claude Code sessions you pin: which one is **running**, which one **needs your
permission**, and which one is **waiting for you**. Zero install: pure PowerShell
+ WinForms, no Python/Node required.

**English** below · [中文版见下方](#中文)

---

## What it shows

Each pinned session is one row: a colored dot + a label + its current state.

| Dot | State | Meaning | Fired by hook |
|---|---|---|---|
| 🔵 | `Running` | Claude is working | `UserPromptSubmit` |
| 🟠 | `Needs permission` | Waiting for you to approve a tool | `Notification` (permission) |
| 🟣 | `Needs answer` | Claude asked you a question | `PreToolUse` (AskUserQuestion) |
| 🟢 | `Done` | Finished its turn | `Stop` |
| 🟡 | `Idle` | Idle, waiting for input | `Notification` (idle) / `SessionStart` |
| ⚪ | `Ended` | Session closed / process gone | `SessionEnd` or pid no longer alive |

## Naming sessions

By default a row shows `project-folder (shortid)`, e.g. `MividaDemo (cce08d93)`.
To give a session a meaningful name, use either method:

- **From inside the session** (recommended): type
  ```
  #name <your label>
  ```
  for example `#name Frontend refactor`. The hook captures it, labels that exact
  session, and **blocks the prompt so Claude never processes it** (you just see a
  small "session labelled" confirmation). Re-run any time to change it. It binds
  to the correct session automatically, so you never look up an id.
- **From the panel:** right-click a row → **Rename**. Right-click → **Use auto
  title** clears it.

**Label priority:** panel custom name > `#name` label > `project (shortid)`.

> Note: `#name` only works in sessions started *after* the hooks were installed
> (see Install). The desktop app's own sidebar titles cannot be reused: they live
> in the app's IndexedDB under an internal `local_<uuid>` id, a different id space
> from the CLI `session_id` the hooks see, with no exposed mapping.

## Install

1. Copy this whole folder to the machine (anywhere).
2. Run setup once (PowerShell):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"
   ```
   Add `-Startup` to also launch the panel automatically at login:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1" -Startup
   ```
3. **Restart any open Claude Code sessions** so the hooks take effect.
4. Double-click `start-panel.vbs` to show the panel.

`install.ps1` figures out its own folder, so the hook paths are always correct
for that machine regardless of username or install location. It backs up any
existing `settings.json` to `settings.json.bak` and preserves other hooks.

> `~/.claude/settings.json` is per-user / per-device and is **not** synced between
> machines, so each machine needs `install.ps1` run once.

## Usage

- **Launch:** double-click `start-panel.vbs` (or run `panel.ps1`).
- **Pick sessions:** click the menu button (≡), tick the sessions to watch. Pins persist.
- **Rename:** `#name <label>` in the session, or right-click a row → Rename.
- **Reorder:** drag a row up or down (or right-click → Move up / Move down).
- **Move:** drag the title bar. Position is remembered.
- **Close:** click ✕ (the panel only; hooks keep running and cost ~nothing).
- **Autostart:** `install.ps1 -Startup`, or drop a shortcut to `start-panel.vbs`
  into the `shell:startup` folder. Remove that shortcut to disable.

## How it works

```
Claude Code session --(hooks)--> status-hook.ps1 --> ~/.claude/session-status/<id>.json
                                                              |
                                       panel.ps1 (reads every 1.5s) --> floating panel
```

- Global hooks in `~/.claude/settings.json` run `status-hook.ps1` on
  SessionStart / UserPromptSubmit / Stop / Notification / SessionEnd. It writes
  one tiny JSON file per session and never blocks Claude (always exits 0).
- `panel.ps1` reads those files plus `~/.claude/sessions/*.json` (for liveness,
  via a pid check) every 1.5 seconds and redraws.

## Files

| File | Role |
|---|---|
| `install.ps1` | One-shot, re-runnable, non-destructive setup for a machine. |
| `status-hook.ps1` | Invoked by hooks. Writes per-session status. Reads stdin as UTF-8. |
| `panel.ps1` | The floating WinForms panel. |
| `start-panel.vbs` | Launches the panel with no console window. |
| `config.json` | Auto-created, git-ignored. Pins, window position, custom names. |

## Notes & limitations

- State only updates for sessions started **after** the hooks were installed.
- After you approve a permission prompt, the row stays `Needs permission` until
  the turn finishes (`Stop` → `Done`); no per-tool event is wired up, to keep
  hook latency near zero.
- A pinned session that ends shows `Ended`; menu → "Unpin ended sessions" clears them.
- Windows only (PowerShell + WinForms).

---

<a name="中文"></a>

# 中文

> 给你的 Claude Code 会话装一盏状态灯。

一个常驻置顶、可拖动的悬浮小面板，实时显示你 pin 的 Claude Code 会话状态：哪个**在跑**、哪个**等你给权限**、哪个**轮到你了**。零安装，纯 PowerShell + WinForms，不需要 Python/Node。

## 显示什么

每个 pin 的会话一行：彩色圆点 + 标签 + 当前状态。

| 圆点 | 状态 | 含义 | 触发的 hook |
|---|---|---|---|
| 🔵 | `Running` | Claude 正在工作 | `UserPromptSubmit` |
| 🟠 | `Needs permission` | 等你批准某个工具 | `Notification`（权限） |
| 🟣 | `Needs answer` | Claude 问了你一个问题 | `PreToolUse`（AskUserQuestion） |
| 🟢 | `Done` | 它这一轮结束了，轮到你 | `Stop` |
| 🟡 | `Idle` | 闲置，等待输入 | `Notification`（idle）/ `SessionStart` |
| ⚪ | `Ended` | 会话关闭 / 进程没了 | `SessionEnd` 或 pid 已退出 |

## 给会话命名

默认显示 `项目文件夹 (短id)`，例如 `MividaDemo (cce08d93)`。想起个有意义的名字，两种方式任选：

- **在会话窗口里**（推荐）：直接打一句
  ```
  #name <名字>
  ```
  例如 `#name 前端重构`。hook 会抓到它、给这个会话打上标签，并**拦下这条提问、不发给 Claude**（你只会看到一行 “session labelled” 的提示）。想改随时再打一次。它自动绑定到当前会话，你不用去查 id。
- **在面板里**：右键某一行 → **Rename**；右键 → **Use auto title** 还原成默认。

**优先级：** 面板手动改的名 > `#name` 设的名 > `项目 (短id)`。

> 注意：`#name` 只在「安装 hooks 之后新开的会话」里生效（见下方安装）。桌面 App 侧边栏那个标题用不了：它存在 App 的 IndexedDB 里、挂在内部的 `local_<uuid>` 上，和 hooks 看到的 CLI `session_id` 不是一套，App 也不暴露两者的对应关系。

## 安装

1. 把整个文件夹拷到目标机器（任意位置）。
2. 运行一次安装（PowerShell）：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"
   ```
   加 `-Startup` 顺便配开机自启：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1" -Startup
   ```
3. **重启所有已打开的 Claude Code 会话**，让 hooks 生效。
4. 双击 `start-panel.vbs` 显示面板。

`install.ps1` 会自动定位自己所在文件夹，所以 hook 路径在任何机器上都正确，不受用户名或安装位置影响。它会先把已有的 `settings.json` 备份成 `settings.json.bak`，并保留其他 hooks。

> `~/.claude/settings.json` 是按「用户/设备」走的，**不会在多台机器间同步**，所以每台机器都要跑一次 `install.ps1`。

## 用法

- **启动：** 双击 `start-panel.vbs`（或直接跑 `panel.ps1`）。
- **选会话：** 点 ≡ 菜单，勾选要盯的会话。pin 会被记住。
- **改名：** 会话里打 `#name <名字>`，或面板右键某行 → Rename。
- **调整顺序：** 直接拖动某一行上下移动（或右键 → Move up / Move down）。
- **移动：** 拖标题栏，位置会被记住。
- **关闭：** 点 ✕（只关面板；hooks 继续跑，几乎不耗资源）。
- **开机自启：** `install.ps1 -Startup`，或把 `start-panel.vbs` 的快捷方式放进 `shell:startup` 文件夹。删掉那个快捷方式即可取消。

## 工作原理

```
Claude Code 会话 --(hooks)--> status-hook.ps1 --> ~/.claude/session-status/<id>.json
                                                          |
                                  panel.ps1 (每 1.5 秒读一次) --> 悬浮面板
```

- `~/.claude/settings.json` 里的全局 hooks 在 SessionStart / UserPromptSubmit / Stop / Notification / SessionEnd 时调用 `status-hook.ps1`，给每个会话写一个很小的 JSON 状态文件，且永不阻塞 Claude（总是 exit 0）。
- `panel.ps1` 每 1.5 秒读这些文件 + `~/.claude/sessions/*.json`（配合 pid 检查判断存活）并重绘。

## 文件

| 文件 | 作用 |
|---|---|
| `install.ps1` | 一次性、可重复运行、非破坏的装机脚本。 |
| `status-hook.ps1` | 被 hooks 调用，写每个会话的状态；按 UTF-8 读 stdin。 |
| `panel.ps1` | 悬浮 WinForms 面板。 |
| `start-panel.vbs` | 无控制台窗口启动面板。 |
| `config.json` | 自动生成、已 git 忽略。存 pin、窗口位置、自定义名。 |

## 说明 / 局限

- 状态只对「安装 hooks 之后新开的会话」更新。
- 批准权限后，那一行会一直停在 `Needs permission`，直到该轮结束（`Stop` → `Done`）；为把 hook 延迟降到最低，没有挂逐个工具的事件。
- pin 的会话结束后显示 `Ended`；菜单 → “Unpin ended sessions” 可清理。
- 仅支持 Windows（PowerShell + WinForms）。
