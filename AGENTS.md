# AGENTS.md — ghostty-monitor 项目规则

## 定位
个人自用工具：Ghostty 分屏实时监控并行 opencode 任务。
每个对话 pane 显示该 run 的**真实 opencode 会话**（user/assistant/thinking/tool），
另有图形化用量仪表盘（额度/token/台账/队列）。纯本地 shell，零 AI token 依赖。

## 关键决策（2026-10-23）
- 分屏走 **Ghostty AppleScript 字典**（`new window` / `split` with surface configuration）。
  CLI 1.3.1 没有 `+new_split`；System Events keystroke 无辅助访问权限；`open -na` 会另起实例。
- 网格默认即 2x2 四屏：空闲格用 `slot-pane` 占位，run 出现自动顶替、结束自动关闭并还回空位；
  4-5 run → 6 屏，6-7 run → 8 屏，≥8 排队。比例用 `equalize_splits` 均衡。
- 额度三窗口（5h/周/月）数据源 = `GET https://opencode.ai/zen/go/v1/usage`（Bearer Go Key，
  rolling/weekly/monthly 的 percent+resetsAt）；billing drawer 需浏览器登录态，Key 读不到。
- token 用量/模型排名 = `GET /console/api/v2/usage/export?range=7d`（按天×模型 CSV，
  requests+四类 token+cost），今日/7天汇总与 TOP 模型由 go-quota 计算后写 cache/go-usage.txt。
- DB 自动发现模式：monitor 直接读 session_v2（parent_id 为空 + 10 分钟内更新）发现原生
  opencode 会话，写 runs/db-*.json 伪注册表上屏；150 秒无更新自动标 done 关闭。
  不依赖 oc-run，跑批器零改动。
- 配置传给 pane 用 **launcher 脚本**（monitor 写 state/launch-*.sh，命令只传单个脚本路径）：
  Ghostty 会吞掉以 `-` 开头的命令参数，surface 环境变量在快速分屏时也可能丢，都不能依赖；
  `GM_HOME` 是唯一真源，GM_STATE/RUNS/LOGS/CACHE 一律从它派生（Ghostty 进程会继承被污染的 GM_*）。
- pane 关闭后进程必须自退（循环里 `stty size </dev/tty` 检测），否则孤儿进程常驻。
- 看板列合并/对齐用一次 python3（按 CJK=2 精确截断补齐）；bash 3.2 判断不了字符宽度，
  且 `printf "'字"` 在 C locale 下返回有符号首字节，不要用它判断宽窄。
- 网格比例用 `perform action "equalize_splits"` 均衡；3x2/4x2 实测等宽等高。
  布局按“用量 + 活跃 run”总格数自适应：1/2/3/4/5/6/7/8 格，活跃上限 7，超出排队。
- 命令退出后 Ghostty **不会**自动关 pane → monitor 显式 `close`。
- 对话数据源 = `opencode.db` 的 `session_message`，每秒跟随；不做 TUI 附身，
  避免输入干扰正在跑的 run。需要交互时用 `gmctl open <id> [--force]` 另开窗口。
- `oc-run --cwd` **必须真正 cd**；opencode 会话按 cwd 归属，且 macOS 要解析成物理路径（/private/…）。
- 会话绑定：oc-run 后台写 `state/session-<id>`；缺失时按 cwd+起始时间兜底。
- 启动链路（2026-10-23 定）：`./install.sh` 往 `~/.local/bin` 写 **wrapper**（不是软链）；
  `gm` 一条命令起面板，`gm run` 连任务一起起，`oc-run` 默认自动拉起面板
  （`--no-start` / `GM_AUTOSTART=0` 关闭）。
- 不做双击 `.app`：macOS 首次启动需要 TCC/Gatekeeper 人工点“允许”，
  无人值守场景不可靠；终端里的 `gm` 已验证可用。
- 安装器禁忌：**绝不能 `cat > 软链`**（会写穿覆盖项目源文件）；写 wrapper 前先 `rm -f` 目标。
- 运行期数据 `runs/ state/ logs/ cache/` 全部 gitignore；`GM_HOME` 可覆盖（测试隔离）。

## 禁止与边界
- 不修改 `/Volumes/移动硬盘/dev/mojing`（只读参考跑批器接口）。
- 不修改 opencode 配置/凭据；不碰 `dev/secrets` 下 Key（`go-status.sh` 只读调用）。
- 不 commit / push，除非用户明确要求。
- 同时运行多个 Ghostty 实例会让 AppleScript 目标不确定；不要用 `open -na` 起实例。
- 不要用 `kill -0 0` / `kill 0`（会命中整个进程组）；进程校验统一走 `gm_alive`。

## 布局/刷新约定
- 对话 pane 只显示最近一屏（最近 40 条消息取末屏），不做滚动/输入。
- 活跃集合变化时重建对话网格；用量 pane 永久保留、2 秒刷新。
- 40 列窄格有专门排版，改动 `usage-pane` 后要用 `GM_FORCE_SIZE=40x25` 验证不折行。

## 验证
```bash
gmctl doctor
./tests/acceptance.sh   # 43 项，真实操作 Ghostty；PASS=43 FAIL=0（2026-10-23）
```
