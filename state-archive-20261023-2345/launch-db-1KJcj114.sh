#!/bin/bash
export GM_HOME='/Volumes/移动硬盘/devtools/ghostty-monitor' GM_MAX_RUNS='7' GM_POLL='2'
export GM_GOSTATUS='/Volumes/移动硬盘/dev/secrets/opencode-go/go-status.sh' GM_LEDGER='/Volumes/移动硬盘/dev/台账/生产台账-mojing.csv' GM_OPENCODE_DB='/Users/dagen/.local/share/opencode/opencode.db'
exec '/Volumes/移动硬盘/devtools/ghostty-monitor/bin/pane-watcher' 'db-1KJcj114'
