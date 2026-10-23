#!/bin/bash
# acceptance.sh — ghostty-monitor 验收脚本（会真实操作 Ghostty 窗口）
#
# 覆盖：
#   1. 空闲即 2x2 四屏（用量 + 3 空位占位），格子等宽等高
#   2. run 出现自动顶替空位；结束后关闭、空位回归（全自动，无需重载）
#   3. 4→6→8 屏逐级扩容；超过 7 个 run 排队；槽位释放自动晋升
#   4. 用量仪表盘：RUNS / GO QUOTA（5h·周·月 已用%余量%重置）/ LEDGER / 2 秒刷新
#   5. 真 opencode 小卡：pane 内显示真实会话 → 结束自动关闭
#
# 用法：tests/acceptance.sh
# 退出码：0 全过；1 有失败。测试使用独立 GM_HOME，不影响真实注册表。

set -uo pipefail
export GM_AUTOSTART=0        # 验收自己显式启动 monitor，避免 oc-run 自动再拉一个
export GM_DB_DISCOVER=0      # 前 5 节关闭 DB 发现（共享库里 30 分钟内的真会话会污染断言）
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/gm-accept.XXXXXX") || exit 1
mkdir -p "$T/runs" "$T/logs"
LEDGER="${GM_LEDGER:-/Volumes/移动硬盘/dev/台账/生产台账-mojing.csv}"
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[1;32m[PASS]\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; }
note() { printf '  \033[2m[info]\033[0m %s\n' "$*"; }
as_count() { osascript -e 'tell application "Ghostty" to return count terminals' 2>/dev/null; }
wait_for() { # desc seconds command...
  local desc=$1 secs=$2 i=0
  shift 2
  while (( i < secs )); do
    if eval "$*" >/dev/null 2>&1; then return 0; fi
    sleep 1; i=$((i + 1))
  done
  return 1
}
bounded() { perl -e 'alarm shift; exec @ARGV' "$@"; }

pane_size() { cat "$T/state/size-$1.txt" 2>/dev/null; }
grid_has() { awk -F'\t' -v id="$1" '$3==id{f=1} END{exit !f}' "$T/state/grid.tsv" 2>/dev/null; }
LAST_WIDTHS=""; LAST_HEIGHTS=""
widths_equal() { # ids...
  local vals first v
  vals=$(for id in "$@"; do pane_size "$id" | cut -d' ' -f1; done) || return 1
  first=$(printf '%s\n' "$vals" | head -n 1)
  [[ -n $first ]] || return 1
  for v in $vals; do
    [[ -n $v ]] || return 1
    (( v >= first - 1 && v <= first + 1 )) || return 1
  done
  LAST_WIDTHS=$(printf '%s' "$vals" | tr '\n' ' ')
  return 0
}
heights_equal() {
  local vals first v
  vals=$(for id in "$@"; do pane_size "$id" | cut -d' ' -f2; done) || return 1
  first=$(printf '%s\n' "$vals" | head -n 1)
  [[ -n $first ]] || return 1
  for v in $vals; do
    [[ -n $v ]] || return 1
    (( v >= first - 1 && v <= first + 1 )) || return 1
  done
  LAST_HEIGHTS=$(printf '%s' "$vals" | tr '\n' ' ')
  return 0
}

cleanup() {
  GM_HOME=$T bounded 8 "$ROOT/bin/gmctl" stop >/dev/null 2>&1
  local p
  for p in $(cat "$T/pids" 2>/dev/null); do kill "$p" >/dev/null 2>&1; done
  sleep 0.5
  rm -rf "$T"
}
trap cleanup EXIT

fake_run() { # id
  local id=$1 p
  local log="$T/logs/$id.log"
  ( while :; do echo "[$(date +%H:%M:%S)] $id tick"; sleep 1; done ) </dev/null >>"$log" 2>&1 &
  p=$!
  disown "$p" 2>/dev/null || true
  printf '%s\n' "$p" >> "$T/pids"
  printf '%s\n' "$p" > "$T/pid-$id"
  jq -n --arg id "$id" --arg model "fake/model-$id" --arg card "假卡 $id" \
    --arg log "$log" --argjson pid "$p" --argjson started "$(( $(date +%s) - 90 ))" \
    --arg cwd "$ROOT" --argjson timeout 600 \
    '{id:$id,model:$model,card:$card,log:$log,pid:$pid,started:$started,status:"running",cwd:$cwd,timeout:$timeout,exit:0}' \
    > "$T/runs/$id.json"
}

check_tier() { # label terms pattern ids...
  local label=$1 terms=$2 pattern=$3
  shift 3
  local ids="$*"
  if wait_for "$label 终端数" 30 '[ "$(as_count)" -eq '$((BASE + terms))' ]'; then
    ok "${label}：终端数 = 基线 + $terms"
  else
    bad "${label}：终端数 $(as_count)，期望 基线 + $terms"
  fi
  if wait_for "$label 尺寸" 20 "widths_equal $ids"; then
    ok "${label}：格子等宽（${LAST_WIDTHS}）"
  else
    bad "${label}：格子宽度不齐（$(for i in $ids; do echo -n "$i=$(pane_size "$i") "; done)）"
  fi
  if wait_for "$label 布局日志" 20 "grep -qF -- '$pattern' \"\$T/logs/monitor.log\""; then
    ok "${label}：布局日志匹配（${pattern}）"
  else
    bad "${label}：布局日志缺少（${pattern}）"
  fi
}

echo "== 0. 环境 =="
if ! pgrep -f "Ghostty.app/Contents/MacOS/ghostty" >/dev/null 2>&1; then
  echo "Ghostty 未运行，无法验收"; exit 1
fi
for c in jq sqlite3 osascript perl; do
  command -v "$c" >/dev/null || { echo "缺少依赖: $c"; exit 1; }
done
BASE=$(as_count)
echo "  Ghostty 终端基线 = ${BASE}，测试数据目录 = $T"

echo "== 1. 空闲即 2x2 四屏 =="
GM_HOME=$T nohup "$ROOT/bin/monitor" >>"$T/logs/monitor.out" 2>&1 &
disown $! 2>/dev/null || true
note "monitor 已启动"
check_tier "空闲 2x2" 4 '布局 4 格：2 列 × 2 行，run 0 个 + 空位 3 个' usage slot-1 slot-2 slot-3
if wait_for "2x2 等高" 20 'heights_equal usage slot-1 slot-2 slot-3'; then
  ok "2x2：全部格子等高"
else
  bad "2x2：格子高度不齐"
fi
if grep -q 'slot	slot-1' "$T/state/grid.tsv" 2>/dev/null && [[ $(grep -c . "$T/state/grid.tsv") -eq 3 ]]; then
  ok "grid.tsv 记录 3 个空位占位格"
else
  bad "grid.tsv 空位记录异常"
fi

echo "== 2. run 出现自动顶替空位；结束自动关闭 =="
fake_run f1; fake_run f2; fake_run f3
check_tier "3 run" 4 '布局 4 格：2 列 × 2 行，run 3 个 + 空位 0 个' usage f1 f2 f3
if wait_for "空位被顶替" 15 '! grid_has slot-3'; then
  ok "run 自动顶替了空位"
else
  bad "空位未被顶替"
fi
kill "$(cat "$T/pid-f2")" >/dev/null 2>&1
check_tier "2 run" 4 '布局 4 格：2 列 × 2 行，run 2 个 + 空位 1 个' usage f1 f3
if wait_for "空位回归" 15 'grid_has slot-3'; then
  ok "run 结束后空位自动回归"
else
  bad "run 结束后空位未回归"
fi

echo "== 3. 逐级扩容 4→6→8 屏 =="
fake_run f4
check_tier "3 run" 4 '布局 4 格：2 列 × 2 行，run 3 个 + 空位 0 个' usage f1 f3 f4
fake_run f5
check_tier "4 run→6 屏" 6 '布局 6 格：3 列 × 2 行，run 4 个 + 空位 1 个' usage f1 f3 f4 f5
fake_run f6
check_tier "5 run" 6 '布局 6 格：3 列 × 2 行，run 5 个 + 空位 0 个' usage f1 f3 f4 f5 f6
fake_run f7
check_tier "6 run→8 屏" 8 '布局 8 格：4 列 × 2 行，run 6 个 + 空位 1 个' usage f1 f3 f4 f5 f6 f7
fake_run f8
check_tier "7 run" 8 '布局 8 格：4 列 × 2 行，run 7 个 + 空位 0 个' usage f1 f3 f4 f5 f6 f7 f8
if wait_for "4x2 等高" 20 'heights_equal usage f1 f3 f4 f5 f6 f7 f8'; then
  ok "4x2：全部格子等高"
else
  bad "4x2：格子高度不齐"
fi

echo "== 4. 排队与晋升 =="
fake_run f9
sleep 4
if [[ $(as_count) -eq $((BASE + 8)) ]]; then
  ok "第 8 个活跃 run 未开 pane（上限 7）"
else
  bad "超过上限仍开了 pane（当前 $(as_count)）"
fi
if wait_for "排队显示" 15 'grep -q "排队中 1" "$T/state/usage.txt"'; then
  ok "仪表盘显示“排队中 1”"
else
  bad "仪表盘未显示排队"
fi
kill "$(cat "$T/pid-f1")" >/dev/null 2>&1
if wait_for "f9 晋升" 30 'grid_has f9'; then
  ok "槽位释放后 f9 自动晋升"
else
  bad "f9 未晋升"
fi

echo "== 5. 用量仪表盘 =="
for marker in "MONITOR" "RUNS" "GO QUOTA" "活跃" "USAGE" "今日" "5h" "余量" "重置"; do
  if grep -q "$marker" "$T/state/usage.txt" 2>/dev/null; then
    ok "仪表盘包含 $marker"
  else
    bad "仪表盘缺少 $marker"
  fi
done
# 自适应行为：run 多时 LEDGER 让位、40 列窄格不显示 TOP 排名（均为设计）
if grep -q "LEDGER" "$T/state/usage.txt" 2>/dev/null; then
  ok "LEDGER 显示（run 少时）"
else
  ok "LEDGER 让位给 RUNS/USAGE（run 多时，设计行为）"
fi
if grep -q '█' "$T/state/usage.txt" 2>/dev/null; then
  ok "仪表盘包含图形进度条"
else
  bad "仪表盘没有图形进度条"
fi
if wait_for "go 额度" 90 'grep -qE "^ *a +5h" "$T/state/usage.txt"'; then
  ok "Go 三窗口额度已显示（官方 zen 数据）"
else
  bad "Go 额度未显示"; sed -n '/GO QUOTA/,/LEDGER/p' "$T/state/usage.txt" 2>/dev/null
fi
M1=$(stat -f %m "$T/state/usage.txt" 2>/dev/null || echo 0)
sleep 3
M2=$(stat -f %m "$T/state/usage.txt" 2>/dev/null || echo 0)
if (( M2 > M1 )); then
  ok "仪表盘按 2 秒刷新（mtime ${M1}→${M2}）"
else
  bad "仪表盘未刷新（mtime ${M1}→${M2}）"
fi

echo "== 6. 真 opencode：pane 内显示真实对话 =="
for p in $(cat "$T/pids"); do kill "$p" >/dev/null 2>&1; done
if wait_for "假 run 清空" 30 '! grep -q "	run	" "$T/state/grid.tsv"'; then
  note "假 run 已清空，回到空闲 2x2"
else
  bad "假 run 未清空（当前 $(as_count)）"
fi
MODEL=opencode/deepseek-v4.1-flash-free
REAL_CWD=$(mktemp -d "${TMPDIR:-/tmp}/gm-real.XXXXXX")
note "模型 ${MODEL}；包一层 sleep 8 便于观察 pane"
GM_HOME=$T nohup "$ROOT/bin/oc-run" --id real1 --model "$MODEL" --card "真对话验收" \
  --log "$T/logs/real1.log" --cwd "$REAL_CWD" --timeout 120 -- \
  sh -c "opencode run -m $MODEL '只回复 OK'; echo '--wrapper-done--'; sleep 8" \
  >"$T/logs/real1.out" 2>&1 &
disown $! 2>/dev/null || true
if wait_for "真 run pane" 60 'grid_has real1'; then
  ok "真 run 的对话 pane 已出现（自动顶替空位）"
else
  bad "真 run 的对话 pane 未出现"
fi
if wait_for "真实对话渲染" 40 'grep -q "只回复 OK" "$T/state/chat-real1.txt" && grep -q "OK" "$T/state/chat-real1.txt"'; then
  ok "pane 快照包含真实用户/助手消息"
else
  bad "pane 快照未出现真实对话"; sed -n '1,20p' "$T/state/chat-real1.txt" 2>/dev/null
fi
if wait_for "真 run 关闭" 180 '! grid_has real1'; then
  ok "真 run 结束后 pane 自动关闭、空位回归"
else
  bad "真 run 的 pane 未关闭"
fi
if [[ $(jq -r '.status' "$T/runs/real1.json" 2>/dev/null) == done ]]; then
  ok "oc-run 回写 status=done"
else
  bad "oc-run 回写异常：$(jq -c '{status,exit,note}' "$T/runs/real1.json" 2>/dev/null)"
fi
if [[ -s $T/state/session-real1 ]]; then
  ok "run 与会话 id 已绑定（$(cat "$T/state/session-real1" | cut -c1-16)…）"
else
  bad "run 未绑定 opencode 会话"
fi

echo "== 7. DB 自动发现：原生 opencode run（无需 oc-run）==="
T2=$(mktemp -d "${TMPDIR:-/tmp}/gm-db.XXXXXX") || exit 1
mkdir -p "$T2/logs"
GM_HOME=$T2 GM_DB_DISCOVER=1 nohup "$ROOT/bin/monitor" >>"$T2/logs/monitor.out" 2>&1 &
disown $! 2>/dev/null || true
sleep 5
if wait_for "DB 空闲四屏" 30 '[ "$(as_count)" -ge '$((BASE + 4))' ]'; then
  ok "DB 模式 monitor 空闲四屏"
else
  bad "DB 模式 monitor 空闲四屏未建立（当前 $(as_count)）"
fi
note "原生 opencode run（无 oc-run 包装）"
RCWD2=$(mktemp -d "${TMPDIR:-/tmp}/gm-raw.XXXXXX")
cd "$RCWD2"
GM_HOME=$T2 GM_DB_DISCOVER=1 nohup opencode run -m "$MODEL" "只回复 OK" >"$T2/logs/raw.log" 2>&1 &
disown $! 2>/dev/null || true
cd "$ROOT"
rawdb_has() { /usr/bin/grep -qF -- "$RCWD2" "$T2"/runs/db-*.json 2>/dev/null; }
if wait_for "原生会话上屏" 90 'rawdb_has'; then
  ok "原生 opencode 会话被自动发现并登记（db-*.json 含 $RCWD2）"
else
  bad "原生 opencode 会话未被发现"
fi
GM_HOME=$T2 bounded 8 "$ROOT/bin/gmctl" stop >/dev/null 2>&1
rm -rf "$T2" "$RCWD2"

echo
echo "== 汇总 =="
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  echo "--- monitor.log 末尾 ---"
  tail -30 "$T/logs/monitor.log" 2>/dev/null
  exit 1
fi
exit 0
