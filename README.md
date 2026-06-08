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
| 🔵 | `Running` | Claude is working / a tool is running | `UserPromptSubmit`, `PreToolUse`/`PostToolUse` |
| 🟠 | `Needs permission` | A tool has been blocked > ~3s — almost always a permission prompt | `PreToolUse` timing (see below) |
| 🟣 | `Needs answer` | Claude asked you a question | `PreToolUse` (AskUserQuestion) |
| 🟢 | `Waiting` | Your turn — finished its reply, or a fresh session | `Stop` / `SessionStart` |
| ⚪ | `Ended` | Conversation **deleted** (its transcript is gone) | transcript file no longer on disk |

> **Why permission is detected by timing:** the desktop app does **not** fire a
> `Notification` hook when a permission dialog appears (verified). So instead,
> `PreToolUse` marks the session pending and the panel turns it orange once a
> tool has been pending longer than `$script:PendingPermMs` in `panel.ps1`
> (default **3000 ms**) — auto-approved tools return in well under a second and
> never flip. Caveat: a genuinely long-running approved tool (e.g. a 30s build)
> also shows orange until it returns; raise the threshold if that is noisy.

## Install

1. Copy this whole folder to the machine (anywhere).
2. Open the folder in a terminal first (in Explorer, right-click the folder →
   **Open in Terminal**, or type `powershell` in the address bar). The `.\` below
   means "this folder", so PowerShell must already be in it.
3. Run setup once:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"
   ```
   Add `-Startup` to also launch the panel automatically at login:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1" -Startup
   ```
   (Or skip step 2 and pass the full path instead of `.\install.ps1` — it works
   from any directory, since the script locates its own folder.)
4. **Restart any open Claude Code sessions** so the hooks take effect.
5. Double-click `start-panel.vbs` to show the panel.

`install.ps1` figures out its own folder, so the hook paths are always correct
for that machine regardless of username or install location. It backs up any
existing `settings.json` to `settings.json.bak` and preserves other hooks.

> `~/.claude/settings.json` is per-user / per-device and is **not** synced between
> machines, so each machine needs `install.ps1` run once.

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
- **Set the group too:** `#group <group name>` puts the session in a group
  (creating it if new). You can do both in one prompt, in any order, e.g.
  `#name Frontend refactor #group Career` or `#group Career`.
- **From the panel:** right-click a row → **Rename**. Right-click → **Use auto
  title** clears it.

> `#name` / `#group` only work in **Claude Code** sessions (they rely on a hook
> intercepting the prompt). **Cowork** sessions run in an isolated VM where those
> hooks don't reach the host, so rename a Cowork session with **right-click →
> Rename** instead, or rename it in the Claude app — the panel reads the app's
> title and syncs it automatically.

Naming or grouping a session with `#name` / `#group` also **auto-pins it** to
the panel, so you do not have to add it from the menu first. (Unpin it manually
and it stays unpinned; a later manual drag to another group is never overridden.)

**Label priority:** panel custom name > `#name` label > `project (shortid)`.

> Note: `#name` only works in sessions started *after* the hooks were installed
> (see Install). The desktop app's own sidebar titles cannot be reused: they live
> in the app's IndexedDB under an internal `local_<uuid>` id, a different id space
> from the CLI `session_id` the hooks see, with no exposed mapping.

## Usage

- **Launch:** double-click `start-panel.vbs` (or run `panel.ps1`).
- **Pick sessions:** click the menu button (≡), tick the sessions to watch. Pins persist.
- **Rename:** `#name <label>` in the session, or right-click a row → Rename.
- **Group:** right-click a row → **Add to group** → pick a group or **New group…**;
  right-click → **Remove from group** to take it out. Group headers are
  **collapsible** (click to collapse/expand; the state is remembered), and
  right-clicking a header lets you **rename** or **move the whole group** up/down.
  Sessions in no group are shown under an **Ungrouped** header. A group vanishes
  automatically once its last member leaves.
- **Jump to Claude:** click a session row (a plain click, not a drag) to bring
  the Claude app window to the front. (It surfaces the app; it can't switch to
  that specific conversation — the desktop app exposes no working way to do that.)
- **Reorder:** drag a row up or down, or right-click → Move up / Move down. When
  you have groups, dragging a row into another group's band also **moves it into
  that group** (drop it on the **Ungrouped** band to take it out); Move up/down
  stays within the group.
- **Move:** drag the title bar. Position is remembered.
- **Theme:** click the menu (≡) → **Switch to light/dark theme**. Dark by default; the choice is remembered.
- **Compact mode:** click ▴ in the title bar to collapse the panel to a single line: one status dot per session (colored by state, hover to name it) plus the top session needing your **answer**/**permission** (permission first) and a count, or just the session count when all is calm. Clicking the line brings the Claude app to the front; use the ▾ arrow to expand.
- **Update check:** on launch (and via the ≡ menu's *Check for updates*) the panel asks GitHub for the latest release. If a newer one exists, an amber dot appears in the title bar and the menu shows *Update available: vX.Y.Z* (click to open the release page). Turn it off by setting `updateCheck` to `false` in `config.json`.
- **Auto-reload:** the panel watches its own script and, when it changes (an update or `git pull`), relaunches itself so you never have to restart it by hand. It waits for the file to settle and parse-checks it first, so a half-saved or broken edit won't be loaded. Disable with `autoReload` in `config.json`.
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
  SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Stop /
  Notification / SessionEnd. It writes one tiny JSON file per session and never
  blocks Claude (always exits 0).
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
- `Needs permission` is a timing heuristic (see the table above), so it appears
  ~3s after a prompt opens and clears the moment you approve/deny (`PostToolUse`
  → `Running`). Long-running approved tools also show orange meanwhile.
- A pinned session that ends shows `Ended` and **stays pinned** (it is never
  auto-dropped); clear it via menu → "Unpin ended sessions" or right-click →
  Unpin. The desktop app sometimes gives the hook a `session_id` that differs
  from the one in `~/.claude/sessions/<pid>.json`; the panel rescues such
  sessions as live by matching `cwd` so they aren't shown `Ended` by mistake.
- **Idle ≠ ended.** The desktop app fires `SessionEnd` even when you just leave a
  conversation idle/backgrounded, not only when you delete it. So `Ended` is
  decided by whether the conversation's **transcript file**
  (`~/.claude/projects/**/<id>.jsonl`) still exists: an idle conversation keeps
  its transcript and stays `Waiting`; only deleting the conversation removes the
  transcript and flips the row to `Ended`.
- **Cowork sessions** show up in the list alongside Claude Code sessions (same
  look, pinnable, groupable). Code is tracked via hooks; Cowork runs in an
  isolated VM, so the panel reads the Claude desktop app's log
  (`%APPDATA%\Claude\logs\main.log`) to surface Cowork state (running / needs
  permission / needs answer) and titles. This relies on the app's log format, so
  it's best-effort — if a future app update changes the log, only Cowork tracking
  is affected (Code keeps working). A Cowork session never shows `Ended` on its
  own (there's no reliable "deleted" signal in the log): an idle one stays green
  `Waiting` and turns blue when it works again — clear it by unpinning.
- **Cowork tracking requires that host log to exist.** It only works if the
  Claude desktop app on this machine actually writes `%APPDATA%\Claude\logs\main.log`
  (or a sibling `Claude*\logs\main.log`) with the agent-mode lifecycle lines. On
  some setups that log isn't produced on the host (the Cowork run-log stays inside
  the isolated VM), in which case **no Cowork sessions will appear and there's
  nothing to point the panel at** — Code/CLI sessions are unaffected. To check
  your machine, run in PowerShell:
  `Get-ChildItem "$env:APPDATA","$env:LOCALAPPDATA" -Recurse -Filter main.log -Depth 3 -ErrorAction SilentlyContinue | ? FullName -like '*Claude*'`
- Windows only (PowerShell + WinForms).

## License

[MIT](LICENSE) © Sophophobia

---

<a name="中文"></a>

# 中文

> 给你的 Claude Code 会话装一盏状态灯。

一个常驻置顶、可拖动的悬浮小面板，实时显示你 pin 的 Claude Code 会话状态：哪个**在跑**、哪个**等你给权限**、哪个**轮到你了**。零安装，纯 PowerShell + WinForms，不需要 Python/Node。

## 显示什么

每个 pin 的会话一行：彩色圆点 + 标签 + 当前状态。

| 圆点 | 状态 | 含义 | 触发的 hook |
|---|---|---|---|
| 🔵 | `Running` | Claude 正在工作 / 工具运行中 | `UserPromptSubmit`、`PreToolUse`/`PostToolUse` |
| 🟠 | `Needs permission` | 某个工具卡住超过约 3 秒——几乎肯定是在等你授权 | `PreToolUse` 时序（见下） |
| 🟣 | `Needs answer` | Claude 问了你一个问题 | `PreToolUse`（AskUserQuestion） |
| 🟢 | `Waiting` | 轮到你了——答完一轮，或刚开的会话 | `Stop` / `SessionStart` |
| ⚪ | `Ended` | 对话被**删除**（transcript 文件没了） | 磁盘上 transcript 文件已不存在 |

> **为什么权限靠时序判断：** 桌面 App 在弹出权限对话框时**不会**触发 `Notification` hook（已实测确认）。所以改成：`PreToolUse` 把会话标记为 pending，当某个工具 pending 超过 `panel.ps1` 里的 `$script:PendingPermMs`（默认 **3000 毫秒**）时面板就变橙——自动批准的工具毫秒级就返回，根本不会变橙。代价：一个真的要跑很久的工具（比如 30 秒的 build）在返回前也会一直显示橙色;嫌烦就把阈值调大。

## 安装

1. 把整个文件夹拷到目标机器（任意位置）。
2. **先在该文件夹里打开终端**（资源管理器里右键文件夹 →「在终端中打开」，或在地址栏敲 `powershell` 回车）。下面的 `.\` 表示"当前这个文件夹"，所以 PowerShell 的当前目录必须就是它。
3. 运行一次安装：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"
   ```
   加 `-Startup` 顺便配开机自启：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1" -Startup
   ```
   （或者跳过第 2 步，把 `.\install.ps1` 换成完整路径 —— 在哪个目录运行都行，脚本会自己定位所在文件夹。）
4. **重启所有已打开的 Claude Code 会话**，让 hooks 生效。
5. 双击 `start-panel.vbs` 显示面板。

`install.ps1` 会自动定位自己所在文件夹，所以 hook 路径在任何机器上都正确，不受用户名或安装位置影响。它会先把已有的 `settings.json` 备份成 `settings.json.bak`，并保留其他 hooks。

> `~/.claude/settings.json` 是按「用户/设备」走的，**不会在多台机器间同步**，所以每台机器都要跑一次 `install.ps1`。

## 给会话命名

默认显示 `项目文件夹 (短id)`，例如 `MividaDemo (cce08d93)`。想起个有意义的名字，两种方式任选：

- **在会话窗口里**（推荐）：直接打一句
  ```
  #name <名字>
  ```
  例如 `#name 前端重构`。hook 会抓到它、给这个会话打上标签，并**拦下这条提问、不发给 Claude**（你只会看到一行 “session labelled” 的提示）。想改随时再打一次。它自动绑定到当前会话，你不用去查 id。
- **顺便设分组：** `#group <组名>` 把会话归到某个分组（不存在就新建）。两者可一行连写、顺序随意，例如 `#name 前端重构 #group 职业` 或单独 `#group 职业`。
- **在面板里**：右键某一行 → **Rename**；右键 → **Use auto title** 还原成默认。

用 `#name` / `#group` 命名或分组后，会**自动把该会话加进面板**，不用先去菜单里勾选。（你手动取消后它就不再被自动加回；之后手动拖到别的分组也不会被覆盖。）

**优先级：** 面板手动改的名 > `#name` 设的名 > `项目 (短id)`。

> 注意：`#name` 只在「安装 hooks 之后新开的会话」里生效（见上方安装）。桌面 App 侧边栏那个标题用不了：它存在 App 的 IndexedDB 里、挂在内部的 `local_<uuid>` 上，和 hooks 看到的 CLI `session_id` 不是一套，App 也不暴露两者的对应关系。

## 用法

- **启动：** 双击 `start-panel.vbs`（或直接跑 `panel.ps1`）。
- **选会话：** 点 ≡ 菜单，勾选要盯的会话。pin 会被记住。
- **改名：** 会话里打 `#name <名字>`，或面板右键某行 → Rename。
- **分组：** 右键某行 → **Add to group** → 选一个已有分组或 **New group…**（新建）；
  右键 → **Remove from group** 移出分组。分组标题**可折叠**（点一下收起/展开，状态会被
  记住），右键标题可以**重命名**或把**整组上下移动**。不在任何分组里的会话归在
  **Ungrouped** 标题下。某个分组的最后一个成员离开后，这个分组会自动消失。
- **跳到 Claude：** 左键单击某行会话（点一下、别拖）会把 Claude 应用窗口提到前台。
  （只能把 App 切到前台，没法切到那个具体对话——桌面 App 没有可用的对外入口。）
- **调整顺序：** 拖动某一行上下移动，或右键 → Move up / Move down。建了分组之后，把某行
  **拖到另一个分组的区域**就会**把它加入那个组**（拖到 **Ungrouped** 区域则移出分组）；
  右键 Move up/down 只在本组内移动。
- **移动：** 拖标题栏，位置会被记住。
- **主题：** 点 ≡ 菜单 → **Switch to light/dark theme** 切换亮/暗主题。默认暗色，选择会被记住。
- **超折叠模式：** 点标题栏的 ▴ 收成一行：每个会话一个状态点（按状态上色，hover 看名字），外加最需要处理的那条（**回答**/**权限**，permission 优先）+ 总数；都没事时显示会话总数。点这一行会把 Claude 提到前台；用 ▾ 箭头展开。
- **更新检查：** 启动时（以及 ≡ 菜单里的 *Check for updates*）会联网问 GitHub 最新 release。有新版时标题栏出现一个琥珀色小点、菜单里出现 *Update available: vX.Y.Z*（点开发布页）。在 `config.json` 里把 `updateCheck` 设为 `false` 可关闭。
- **自动重载：** 面板会监视自己的脚本，一旦更新（改动或 `git pull`）就自动关掉重开，不用你手动重启。它会先等文件稳定、并做语法检查，所以改到一半或语法坏的版本不会被加载。在 `config.json` 里把 `autoReload` 设为 `false` 可关闭。
- **关闭：** 点 ✕（只关面板；hooks 继续跑，几乎不耗资源）。
- **开机自启：** `install.ps1 -Startup`，或把 `start-panel.vbs` 的快捷方式放进 `shell:startup` 文件夹。删掉那个快捷方式即可取消。

## 工作原理

```
Claude Code 会话 --(hooks)--> status-hook.ps1 --> ~/.claude/session-status/<id>.json
                                                          |
                                  panel.ps1 (每 1.5 秒读一次) --> 悬浮面板
```

- `~/.claude/settings.json` 里的全局 hooks 在 SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Stop / Notification / SessionEnd 时调用 `status-hook.ps1`，给每个会话写一个很小的 JSON 状态文件，且永不阻塞 Claude（总是 exit 0）。
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
- `Needs permission` 是时序启发式（见上表），所以弹窗后约 3 秒才变橙，你一批准/拒绝就清掉（`PostToolUse` → `Running`）；其间长工具也会显示橙色。
- pin 的会话结束后显示 `Ended`，并**保持 pin 不会被自动移除**；用菜单 → “Unpin ended sessions” 或右键 → Unpin 清理。桌面 App 有时给 hook 的 `session_id` 跟 `~/.claude/sessions/<pid>.json` 里的不一致，面板会用 `cwd` 匹配把这类会话救回判为存活，避免被误判成 `Ended`。
- **挂着 ≠ 结束。** 桌面 App 在你只是把对话晾在一边/切到后台时也会触发 `SessionEnd`，不只是删除时才触发。所以 `Ended` 是靠对话的 **transcript 文件**（`~/.claude/projects/**/<id>.jsonl`）是否还在判断的：挂着的对话 transcript 还在，会一直显示 `Waiting`；只有删掉对话、transcript 没了，这一行才会变成 `Ended`。
- **Cowork 会话**会和 Claude Code 会话一起出现在列表里（外观一致，可 pin、可分组）。Code 靠 hooks 跟踪；Cowork 跑在隔离的 VM 里，所以面板改读 Claude 桌面 App 的日志（`%APPDATA%\Claude\logs\main.log`）来显示 Cowork 的状态（运行中 / 等权限 / 等回答）和标题。这依赖 App 的日志格式，属尽力而为——将来 App 改了日志，也只影响 Cowork 跟踪，Code 照常工作。Cowork 会话**不会自己变成 `Ended`**（日志里没有可靠的"已删除"信号）：闲置时一直是绿色 `Waiting`，再次工作就变蓝，要清理就手动 unpin。
- 仅支持 Windows（PowerShell + WinForms）。

## 许可证

[MIT](LICENSE) © Sophophobia
