#!/bin/bash
# install.sh — 安装/卸载优雅启动入口
#
#   ./install.sh              装 gm / gmctl / oc-run 到 ~/.local/bin
#   ./install.sh --uninstall  移除上述入口（不动项目本身）
#
# 装完后：
#   gm                        一条命令启动/聚焦面板
#   gm run --id … -- …        连任务一起起
#   oc-run …                  默认自动拉起面板

set -uo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"
APP="$HOME/Applications/Ghostty Monitor.app"

if [[ ${1:-} == --uninstall ]]; then
  for n in gm gmctl oc-run; do
    if [[ -L $BIN/$n ]] || grep -q 'ghostty-monitor wrapper' "$BIN/$n" 2>/dev/null; then
      rm -f "$BIN/$n" && echo "已移除 $BIN/$n"
    fi
  done
  [[ -d $APP ]] && rm -rf "$APP" && echo "已移除 $APP"
  echo "卸载完成（项目文件未动）"
  exit 0
fi

mkdir -p "$BIN" "$HOME/Applications" "$ROOT/logs"

link_cmd() { # name —— 写真实路径 wrapper（不用软链，避免 $0 解析不到 gm-lib）
  local n=$1 dest="$BIN/$1"
  if [[ -L $dest ]]; then
    rm -f "$dest"                      # 先删旧软链，绝不写穿到项目文件
  elif [[ -e $dest ]] && ! grep -q 'ghostty-monitor wrapper' "$dest" 2>/dev/null; then
    echo "[跳过] $dest 已存在且不是本工具安装的" >&2
    return 1
  fi
  rm -f "$dest"
  cat > "$dest" <<EOF
#!/bin/bash
# ghostty-monitor wrapper (regenerate with install.sh)
exec "$ROOT/bin/$n" "\$@"
EOF
  chmod +x "$dest"
  echo "[ok] $dest → bin/$n"
}

link_cmd gm
link_cmd gmctl
link_cmd oc-run

echo
echo "安装完成。常用命令："
echo "  gm                         启动/聚焦监控面板（一条命令）"
echo "  gm run --id X --model M --cwd DIR -- opencode run ...   （连任务一起起）"
echo "  oc-run …                   默认自动拉起面板，什么都不用先开"
echo "  gm status | gm stop | gm open <id> | gm logs"
echo
case ":$PATH:" in
  *":$BIN:"*) echo "PATH 已包含 ${BIN}，可直接敲 gm" ;;
  *) echo "请把下面一行加入 ~/.zshrc："; echo "  export PATH=\"\$PATH:$BIN\"" ;;
esac
