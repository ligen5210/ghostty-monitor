#!/bin/bash
# gm-lib.sh — ghostty-monitor 公共函数（被 bin/* 脚本 source）
#
# 数据目录：
#   GM_HOME  默认 = 本仓库根目录；可用环境变量覆盖（测试隔离用）
#   runs/    注册表 <id>.json（oc-run 写、monitor/usage-pane 读）
#   state/   monitor 状态、usage 渲染快照、watcher 心跳
#   logs/    oc-run 日志默认落点、monitor 日志
#   cache/   go-status 等外部查询缓存

# ---------- 路径解析（支持符号链接安装） ----------
_gm_self=${BASH_SOURCE[0]}
while [ -L "$_gm_self" ]; do
  _gm_dir=$(cd -P "$(dirname "$_gm_self")" && pwd)
  _gm_self=$(readlink "$_gm_self")
  case $_gm_self in /*) ;; *) _gm_self=$_gm_dir/$_gm_self ;; esac
done
GM_ROOT=$(cd -P "$(dirname "$_gm_self")/.." && pwd)
unset _gm_self _gm_dir

# 面板/脚本需要 UTF-8 locale 才能正确处理中文宽度（launchd 环境可能是 C）
export LANG=${LANG:-zh_CN.UTF-8}
export LC_ALL=zh_CN.UTF-8

export GM_ROOT
# GM_HOME 是唯一真源；其余路径无条件从它派生。
# （不能写作 ${GM_STATE:-...}：Ghostty 进程可能从 monitor 继承被污染的 GM_* 环境变量）
export GM_HOME=${GM_HOME:-$GM_ROOT}
export GM_RUNS=$GM_HOME/runs
export GM_STATE=$GM_HOME/state
export GM_LOGS=$GM_HOME/logs
export GM_CACHE=$GM_HOME/cache

export GM_GOSTATUS=${GM_GOSTATUS:-/Volumes/移动硬盘/dev/secrets/opencode-go/go-status.sh}
export GM_LEDGER=${GM_LEDGER:-/Volumes/移动硬盘/dev/台账/生产台账-mojing.csv}
export GM_OPENCODE_DB=${GM_OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}
export GM_MAX_PANES=${GM_MAX_PANES:-4}
export GM_MAX_RUNS=${GM_MAX_RUNS:-7}
# 布局上限：8 格 = 1 用量 + 7 对话；再大没有对应均衡网格
(( GM_MAX_RUNS > 7 )) && GM_MAX_RUNS=7
(( GM_MAX_RUNS < 1 )) && GM_MAX_RUNS=1
export GM_POLL=${GM_POLL:-2}
export GM_GOSTATUS_TTL=${GM_GOSTATUS_TTL:-60}

mkdir -p "$GM_RUNS" "$GM_STATE/hb" "$GM_LOGS" "$GM_CACHE"

# ---------- 基础 ----------
gm_now() { date +%s; }

gm_now_ms() {
  # date +%s%N 在 macOS 不可用；用 perl（系统自带）避免 python 启动开销
  perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'
}

gm_alive() {
  # 注意：kill -0 0 会命中整个进程组（等于自杀），必须排除 0/1
  local p=${1:-}
  [[ $p =~ ^[0-9]+$ ]] || return 1
  (( p > 1 )) || return 1
  kill -0 "$p" 2>/dev/null
}

# 进程命令行是否包含指定片段（防 PID 复用误杀）
gm_is_cmd() { # pid pattern
  local p=${1:-} pat=${2:-}
  gm_alive "$p" || return 1
  [[ -n $pat ]] || return 0
  ps -p "$p" -o command= 2>/dev/null | grep -q -- "$pat"
}

# 进程启动时间（用于识别 PID 复用）
gm_pid_lstart() { # pid
  ps -p "${1:-0}" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//'
}

gm_fmt_dur() {
  local d=${1:-0}
  if (( d < 60 )); then printf '%ds' "$d"
  elif (( d < 3600 )); then printf '%dm%02ds' $((d / 60)) $((d % 60))
  else printf '%dh%02dm' $((d / 3600)) $(((d % 3600) / 60)); fi
}

gm_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

# 原子写：stdin -> 文件
gm_atomic_write() {
  local f=$1 tmp="$1.tmp.$$"
  cat > "$tmp" && mv -f "$tmp" "$f"
}

# 注册表字段读取（单字段）
gm_run_get() { # file jq_expr default
  local f=$1 expr=$2 def=${3:-}
  [[ -f $f ]] || { printf '%s' "$def"; return; }
  local v
  v=$(jq -r "($expr) // empty" "$f" 2>/dev/null) || { printf '%s' "$def"; return; }
  [[ -n $v ]] && printf '%s' "$v" || printf '%s' "$def"
}

# run 是否仍在跑：status=running 且 pid 活着（并用启动时间排除 PID 复用）
gm_run_active() { # file
  local f=$1 status pid recorded now_start
  status=$(gm_run_get "$f" .status running)
  pid=$(gm_run_get "$f" .pid "")
  [[ $status == running ]] && gm_alive "$pid" || return 1
  recorded=$(gm_run_get "$f" .pid_start "")
  if [[ -n $recorded ]]; then
    now_start=$(gm_pid_lstart "$pid")
    [[ $now_start == "$recorded" ]] || return 1
  fi
  return 0
}

# 按 started 升序输出活跃 run 的文件路径
gm_active_runs() {
  local f
  for f in "$GM_RUNS"/*.json; do
    [[ -f $f ]] || continue
    gm_run_active "$f" && printf '%s\t%s\n' "$(gm_run_get "$f" .started 0)" "$f"
  done | sort -n | cut -f2-
}

# 发现最近的 opencode 原生会话（DB 自动发现模式，无需 oc-run）
# 截断毫秒 -> TSV(\x1f 分隔)：sid \x1f 目录 \x1f 标题 \x1f 模型 \x1f created_ms \x1f updated_ms
gm_db_sessions() {
  local cutoff=${1:-0}
  sqlite3 -readonly "$GM_OPENCODE_DB" \
    "select id||char(9)||directory||char(9)||coalesce(title,char(32))||char(9)||coalesce(json_extract(model,'\$.id'),char(32))||char(9)||time_created||char(9)||time_updated
       from session_v2
      where parent_id is null and time_updated >= $cutoff
      order by time_created asc;" 2>/dev/null
}

# opencode 会话：run 的 cwd + 起始时间 → session id（取起始后最早创建的会话）
gm_find_session() { # cwd started_sec
  local cwd=${1:-} start=${2:-0} db=$GM_OPENCODE_DB esc sid
  [[ -n $cwd && -r $db ]] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1
  esc=${cwd//\'/\'\'}
  sid=$(sqlite3 -readonly "$db" \
    "select id from session_v2
      where directory='$esc' and time_created >= $((start * 1000 - 2000))
      order by time_created asc limit 1;" 2>/dev/null) || return 1
  [[ -n $sid ]] || return 1
  printf '%s' "$sid"
}

# 为注册表解析 session id（缓存到 state/session-<id>）
gm_session_for_registry() { # reg_file
  local f=$1 id cwd started sf sid
  [[ -f $f ]] || return 1
  id=$(gm_run_get "$f" .id "")
  [[ -n $id ]] || return 1
  sf="$GM_STATE/session-$id"
  if [[ -s $sf ]]; then cat "$sf"; return 0; fi
  cwd=$(gm_run_get "$f" .cwd "")
  started=$(gm_run_get "$f" .started 0)
  sid=$(gm_find_session "$cwd" "$started") || return 1
  [[ -n $sid ]] || return 1
  printf '%s' "$sid" > "$sf.tmp.$$" 2>/dev/null && mv -f "$sf.tmp.$$" "$sf" 2>/dev/null
  printf '%s' "$sid"
}

# 指定会话的 token 合计（精确）
gm_session_tokens_sid() { # sid
  local sid=${1:-} db=$GM_OPENCODE_DB esc v
  [[ -n $sid && -r $db ]] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1
  esc=${sid//\'/\'\'}
  v=$(sqlite3 -readonly "$db" \
    "select tokens_input+tokens_output+tokens_reasoning from session_v2 where id='$esc';" 2>/dev/null) || return 1
  [[ $v =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$v"
}

# 当前 pane 尺寸 → GM_TERM_LINES / GM_TERM_COLS（tput 在 Ghostty 里会误报，用 stty）
gm_term_size() {
  local sz
  if [[ ${GM_FORCE_SIZE:-} =~ ^([0-9]+)x([0-9]+)$ ]]; then
    GM_TERM_COLS=${BASH_REMATCH[1]}; GM_TERM_LINES=${BASH_REMATCH[2]}
    return
  fi
  sz=$(stty size </dev/tty 2>/dev/null) || sz=""
  if [[ $sz =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
    GM_TERM_LINES=${BASH_REMATCH[1]}
    GM_TERM_COLS=${BASH_REMATCH[2]}
  else
    GM_TERM_LINES=24; GM_TERM_COLS=80
  fi
  (( GM_TERM_LINES < 8 )) && GM_TERM_LINES=8
  (( GM_TERM_COLS < 40 )) && GM_TERM_COLS=40
}

# opencode 会话 token 合计（按目录 + 起始时间近似匹配；失败返回 1）
gm_session_tokens() { # cwd started_sec
  local cwd=${1:-} start=${2:-0} db=$GM_OPENCODE_DB esc v
  [[ -r $db ]] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1
  esc=${cwd//\'/\'\'}
  v=$(sqlite3 -readonly "$db" \
    "select coalesce(sum(tokens_input+tokens_output+tokens_reasoning),0)
       from session_v2
      where directory='$esc' and time_updated >= $((start * 1000 - 5000));" 2>/dev/null) || return 1
  [[ $v =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$v"
}

# 人类可读 token 数
gm_fmt_tokens() {
  local n=${1:-0}
  if (( n >= 1000000 )); then printf '%.1fM' "$(echo "$n" | awk '{printf "%.1f", $1/1000000}')"
  elif (( n >= 1000 )); then printf '%.1fk' "$(echo "$n" | awk '{printf "%.1f", $1/1000}')"
  else printf '%s' "$n"; fi
}

# 当前最前台 App 的 bundleID（lsappinfo 不需要辅助访问权限）
gm_front_bundle() {
  local asn
  asn=$(lsappinfo front 2>/dev/null) || return 0
  [[ -n $asn ]] || return 0
  lsappinfo info -only bundleID "$asn" 2>/dev/null | sed -n 's/.*bundleID="\([^"]*\)".*/\1/p'
}

# 终端宽度安全的截断
gm_cut() { # string maxchars
  local s=${1//$'\t'/ } max=${2:-120}
  printf '%s' "${s:0:$max}"
}

# 截断并加省略号
gm_ell() { # string maxchars
  local s=${1//$'\t'/ } max=${2:-20}
  if (( ${#s} <= max )); then printf '%s' "$s"
  else printf '%s…' "${s:0:$((max - 1))}"; fi
}
