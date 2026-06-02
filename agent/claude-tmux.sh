#!/usr/bin/env bash
# 在 tmux session 里启动/附着 Claude。
# T2 远程批准/拒绝必须把 Claude 跑在 tmux 里，agent 才能通过 send-keys 注入按键。
#
# 用法：
#   claude-tmux.sh          # 进入交互式 Claude
#   claude-tmux.sh -p "..." # 透传任意参数给 claude

SESSION="${CLAUDE_LIGHT_TMUX_TARGET:-claude}"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  exec tmux attach -t "$SESSION"
else
  exec tmux new-session -s "$SESSION" claude "$@"
fi
