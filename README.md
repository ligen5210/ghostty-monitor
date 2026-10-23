# ghostty-monitor

Ghostty 分屏跑批监控器：每个 pane 实时显示一个 opencode 任务的**真实对话**，
外加一块图形化用量仪表盘（额度 / token / 台账 / 队列）。
纯本地 shell，零 AI token 依赖。

> 基线：2026-10-23 · macOS 27 (arm64) · Ghostty 1.3.1 · bash 3.2 · jq/sqlite3（系统自带）

## 它长什么样

4 格（2x2）时的对话 pane：

```
▌M06-1 修复登录 M06-1
● 运行中 · opencode/deepseek-v4.1-flash · 3m12s · tok 12.3k · 消息 42
─────────────────────────────────────────────────────
▌用户 执行 tickets/M06-1.md 中的任务。先读卡片与项目规则…
▌思考 先定位登录入口，再看路由守卫…
⚙ shell [completed] grep -rn "LoginScreen" mobile/src
  ⎿ mobile/src/screens/Login.tsx:42:export function LoginScreen…
▌助手 已定位到登录组件，接下来修复 token 刷新分支…
```

用量仪表盘：

```
◈ GHOSTTY MONITOR  ● LIVE  10-23 01:42:10
  ─────────────────────────────────────────────
 活跃 5/7   TOK ≈ 82.4k  ▁▂▃▅▆▇█▇▆▅▃▂
  RUNS ────────────────────────────────────────
  ● M06-1   deepseek-v4.1  3m12s ████████░░░░  42%  12.3k
  ● M06-2   mimo-v2.6      1m45s ████░░░░░░░░  21%   3.1k
  ○ M06-6   …              排队中 1
  GO QUOTA ────────────────────────────────────
  a ████░░░░░░  spent $0.00 / limit —  you@example…
  b key 未填
  LEDGER ──────────────────────────────────────
  日期 │ 卡片 │ 结果 │ 耗时
  2026-10-23 │ ZZ-selftest │ PASS │ 56s
```

## 能力探针结论（2026-10-23 实测）

| 方式 | 结果 | 结论 |
|---|---|---|
| `ghostty +new_split:down` | 1.3.1 CLI 没有该 action，只有 `+new-window` | ❌ |
| System Events keystroke | `-1728 osascript 不允许辅助访问` | ❌ |
| **AppleScript 直连 Ghostty 字典** | `new window` / `split … with configuration` 可用，支持命令/env/cwd/wait | ✅ 采用 |
| `open -na Ghostty.app --args -e` | 另起独立实例，带空格命令不可靠 | ❌ |
| 命令退出后 pane 自动关闭 | **不会**（`wait-after-command=false` 也不生效） | monitor 显式 close |
| `perform action "equalize_splits"` | 任意分割树 → 等面积格子（3x2 实测全部 51×25） | ✅ 布局均衡 |
| `resize_split` | 可移动分隔线，但 equalize 已够用 | 备用 |
| `stty size` | pane 内返回真实尺寸；`tput cols` 会误报 80×24 | ✅ 用 stty |
| `split` 抢焦点 | 不抢；`new window` 会抢，创建后恢复原前台 App | ✅ |

## 架构

```
        oc-run（登记 → 执行 → 回写；后台绑定 opencode session id）
             │ runs/<id>.json          │ state/session-<id>
             ▼                         ▼
   monitor（每 2s 轮询）        pane-watcher（每个对话 pane）
   · 活跃集合变化 → 重建网格      · 读 session_message → 渲染真实对话
   · equalize_splits 均衡比例     · 每秒跟随，显示最近一屏
   · run 结束 → close pane        · 结束渲染终态后退出
             │
             ▼
        usage-pane（永不退出）
        · 图形化 RUNS / GO QUOTA / LEDGER
        · 2s 刷新，纯文本快照 state/usage.txt
```

### 对话 pane 显示什么

直接读 `~/.local/share/opencode/opencode.db` 的 `session_message` 表，按时间顺序渲染：

- `user` → 蓝色「用户」
- `assistant` 的 `text` → 绿色「助手」
- `assistant` 的 `reasoning` → 灰色「思考」（截断）
- `assistant` 的 `tool` → 黄色「⚙ 工具名 [状态] 参数」+ 输出首几行
- `system` / `compaction` / `idle` → 灰色状态行

每秒重查并重绘，始终显示**最后 40 条消息里的最近一屏**；会话建立前退回原始日志预览。
不做交互输入，因此不会干扰正在跑的 opencode。

### 自适应网格

总格数 = 1 个用量 pane + N 个对话 pane（N=活跃 run 数，最多 7）：

| 活跃 run | 总格数 | 布局 | 空位占位 |
|---|---|---|---|
| 0–3 | 4 | 2 × 2 | 空位用 `slot-pane` 占位（“空闲槽位，等待任务分配”） |
| 4–5 | 6 | 3 × 2 | 同上 |
| 6–7 | 8 | 4 × 2 | 同上 |
| 8+ | 8 | 4 × 2 | 超出排队，仪表盘显示“排队中 N” |

- **默认至少四屏**：面板一开就是 2x2（用量 + 3 个空闲槽位），永远不会缩成一条。
- **面板窗口自动最大化**，看板按宽度自适应分列：≥150 列三列（RUNS │ USAGE+模型排行 │ QUOTA+LEDGER）、
  ≥104 列两列、其余单列；所有行按显示宽度（CJK=2）精确截断/对齐（列合并由 python 完成）。
- 每次建完网格调用 `equalize_splits`，实测 2x2 = 77×25、3x2 = 51×25、4x2 = 40×25，比例正常。
- **全自动跟随，无需任何重载**：monitor 每 2 秒轮询，新任务自动顶替空位；
  任务结束 pane 自动关闭、空位自动回归；对话内容本身每秒跟随 opencode 数据库。
- **原生会话自动发现（DB 模式）**：跑批器不改一行，直接 `opencode run` 的任务也会被
  自动发现并上屏（读 session_v2 表，parent_id 为空 + 10 分钟内活跃；150 秒无更新视为结束）。
  关闭监控器再打开，正在进行的对话会自动重新接上。
- 活跃集合变化时重建对话 pane 网格（用量 pane 不动）；watcher 从数据库重放，重连无数据损失。
- 资源占用：slot 空闲格 3 秒一帧、零查询；对话格 1 秒一帧 + 每 5 秒一次 sqlite；
  额度接口缓存 60 秒；pane 被手动关闭后进程自动退出（pty 检测），不留孤儿。

## 文件

```
bin/
  gm-lib.sh      公共函数（路径、JSON、进程校验、会话解析、尺寸）
  gm             日常入口（gm / gm run / gm stop / gm open / gm logs）
  oc-run         登记式执行包装（确认 cd 到 --cwd，后台绑定 session，默认自动拉起面板）
  monitor        常驻监控（自适应网格、equalize、增删 pane）
  pane-watcher   对话 pane：真实会话渲染
  usage-pane     用量 pane：图形化仪表盘
  gmctl          start / stop / status / open / doctor / attach
install.sh       装 wrapper 到 ~/.local/bin（绝不写穿软链）
tests/
  acceptance.sh  43 项自动验收（真实操作 Ghostty）
runs/            注册表（运行期，gitignore）
state/           grid/dashboard/session/chat/usage 快照（运行期）
logs/ cache/     日志与 go-status 缓存（运行期）
```

数据根目录默认=本仓库，`GM_HOME` 可覆盖（测试隔离）。

## 快速开始（优雅启动）

```bash
./install.sh          # 一次性：把 gm / gmctl / oc-run 装到 ~/.local/bin（已在 PATH）

gm                    # 一条命令：启动监控面板并切到前台
gm run --id M06-1 --model opencode-go/deepseek-v4.1-flash \
       --card "M06-1" --cwd /path/to/worktree --timeout 900 \
       -- opencode run -m opencode-go/deepseek-v4.1-flash "执行 tickets/M06-1.md…"
                      # 面板 + 任务一条命令起
oc-run …              # 不先开面板也行：oc-run 默认自动拉起
gm status | gm stop | gm open <id> | gm logs | gm doctor
```

- 首次启动会弹一次“控制 Ghostty”的自动化授权，点允许即可。
- 不需要辅助访问（Accessibility）权限。
- 不要同时开多个 Ghostty 实例（AppleScript 目标会不确定）。
- 不想自动拉面板：`oc-run --no-start …` 或 `GM_AUTOSTART=0`。
- 更细的控制仍可用 `gmctl start|stop|status|doctor|attach`。

### 登记任务

```bash
oc-run --id M06-1 --model opencode-go/deepseek-v4.1-flash \
       --card "M06-1 修复登录" --log /tmp/M06-1.log \
       --cwd /path/to/worktree --timeout 900 \
       -- opencode run -m opencode-go/deepseek-v4.1-flash \
          "执行 tickets/M06-1.md 中的任务。先读卡片与项目规则，完成后输出 DONE。"
```

| 参数 | 说明 |
|---|---|
| `--id` | 必填；只允许 `A-Za-z0-9._-` |
| `--model` | 必填；展示用 |
| `--card` | pane 标题，默认=id |
| `--log` | 日志路径，默认 `logs/<id>.log` |
| `--cwd` | **会真正 cd 进去**（opencode 会话按 cwd 归属） |
| `--timeout` | 超时 TERM→3s→KILL，注册表标 `note=timeout` |
| `--no-start` | 本次不自动拉起监控面板（等价 `GM_AUTOSTART=0`） |

与跑批器集成：把 `( cd "$WORKTREE" && opencode run … ) >"$log" 2>&1 &`
替换为 `oc-run --id "$card" --model "$model" --card "$card" --log "$logf" --cwd "$WORKTREE" -- … &`。
跑批器第一次调用时面板会自动出现，无需额外启动步骤。

### 用 opencode 本体打开会话

```bash
gmctl open M06-1            # 新窗口运行 opencode --session <sid>（run 结束后）
gmctl open M06-1 --force    # run 还在跑时强制附身（可能干扰执行）
```

日常看对话不需要它：对话 pane 已经是真实会话内容；`open` 适合需要继续交互时。

## 用量仪表盘

| 区块 | 内容 |
|---|---|
| 顶栏 | `◈ GHOSTTY MONITOR`、LIVE/STOPPED、时间 |
| 汇总 | 活跃/上限、排队数、总 token + 迷你走势（宽屏） |
| RUNS | 每个 run 的 id、模型、耗时、进度条（有 timeout 按百分比，无则活动条）、token |
| USAGE | **官方 token 用量**：今日 / 7天 的 token 总量与花费（含缓存），+ 7天模型用量 TOP3/TOP5 排名 |
| GO QUOTA | 每个账号：**5 小时 / 本周 / 本月** 的已用%、余量%、官方重置时间（UTC），70%/90% 变黄变红 |
| LEDGER | 台账末 2-4 行（run 多或高度不足时自动让位） |

额度数据源（2026-10-23 实测）：
`GET https://opencode.ai/zen/go/v1/usage`（`Authorization: Bearer <Go API Key>`），
返回 rolling(=5h)/weekly/monthly 三个窗口的 `percent + resetsAt` —— 与开源插件
[oc-usage-limits-plugin](https://github.com/mynameistito/oc-usage-limits-plugin) 同款接口。
由 `bin/go-quota` 读取（缓存 60s）；token/花费明细来自
`GET /console/api/v2/usage/export?range=7d`（按天×模型 CSV，含服务账号）。
注意：控制台的 billing drawer（美元明细 UI）需要浏览器登录态，API Key 读不到。

- 面板每 2 秒重绘；go-status 数据缓存 60 秒（避免高频打预算 API）。
- 40 列的 4x2 格子也有窄屏排版（无百分比、缩短 id/模型/台账列），不会折行。
- token 优先用 run 绑定的 session 精确统计；无会话显示 `—`。
- 纯文本快照：`state/usage.txt`（去 ANSI，可 grep/远程看）。

## 验收

```bash
./tests/acceptance.sh
```

2026-10-23 实测：**PASS=43 FAIL=0**

覆盖：3 假 run → 2x2 等宽等高；kill 收缩；4→5→6→7→8 格逐级扩容且宽度一致；
8 个活跃 run 排队；槽位释放晋升；仪表盘各区块/图形条/2 秒刷新；
真 opencode（`opencode/deepseek-v4.1-flash-free`）pane 内出现用户与助手消息、
结束自动关闭、`oc-run` 回写 done、session id 绑定成功。

## 已知限制

- **单 Ghostty 实例**：AppleScript 按 bundle id 找应用；多实例时目标不确定。
- **pane 不自动关**：Ghostty 1.3.1 在命令退出后保留 surface，由 monitor 显式 close。
- **活跃集合变化会重建对话网格**：用量 pane 不动；watcher 从 DB 重放，无数据损失。
- **对话只显示最近一屏**：查询最近 40 条消息后取末屏；不做滚动/交互。
- **会话匹配**：优先用 `oc-run` 绑定的 `state/session-<id>`；缺失时按 `cwd + 起始时间`
  取最早创建的新会话。同一 cwd 并发多个 run 时可能匹配到同一会话（建议一 run 一 worktree）。
- **token 统计**：绑定会话后精确；未绑定时按目录+时间近似。
- **bash 3.2**：脚本已避开 bash 4 特性；依赖 `jq`、`sqlite3`、`perl`（系统自带）。
- **调试**：`GM_FORCE_SIZE=40x25` 可强制渲染尺寸；`GM_MAX_RUNS`、`GM_POLL`、`GM_HOME` 可调。

## 附录：关键探针命令

```bash
# 分屏 + 配置
osascript <<'AS'
tell application "Ghostty"
  set cfg to new surface configuration
  set command of cfg to "/path/script arg"
  set environment variables of cfg to {"FOO=bar"}
  set wait after command of cfg to false
  set t to focused terminal of selected tab of front window
  set nt to split t direction right with configuration cfg
end tell
AS

# 均衡格子
osascript -e 'tell application "Ghostty" to perform action "equalize_splits" on (terminal id "…")'

# pane 真实尺寸
stty size </dev/tty     # 52 155；tput cols 会误报 80

# 关闭（注意：close (window id …) 会静默失败）
osascript -e 'tell application "Ghostty" to close (terminal id "…")'
osascript -e 'tell application "Ghostty" to close window (window id "…")'
```
