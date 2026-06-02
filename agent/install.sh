#!/usr/bin/env bash
# Claude 红绿灯 · 一键部署(macOS / Linux,自动判断模式)
#
#   服务端(插灯那台):
#       bash agent/install.sh
#     起 agent(macOS 用 launchd 常驻)+ 本机 hooks。多机同步时让 agent 监听 tailnet:
#       CLAUDE_LIGHT_BIND=0.0.0.0 bash agent/install.sh
#
#   客户端(其它机器,把状态同步到插灯那台):
#       CLAUDE_LIGHT_AGENT_HOST=<插灯那台的 tailscale IP> bash agent/install.sh
#     只配 hooks(状态 POST 到那台 agent),不起 agent、不碰串口。
#
# 前提:服务端的 Pico 已烧好固件 + 接好线(见 firmware/README.md、HARDWARE.md)。

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIGHT_SH="$REPO/host/light.sh"
AGENT_PY="$REPO/agent/agent.py"
SETTINGS="$HOME/.claude/settings.json"
PORT="${CLAUDE_LIGHT_AGENT_PORT:-7321}"
AGENT_HOST="${CLAUDE_LIGHT_AGENT_HOST:-}"

[ -f "$LIGHT_SH" ] || { echo "✗ 找不到 $LIGHT_SH,确认在仓库目录里运行"; exit 1; }
chmod +x "$LIGHT_SH" "$AGENT_PY" 2>/dev/null || true

# hooks 合并(两模式共用)。$1 = 命令前缀(CLAUDE_LIGHT_SERIAL=... 或 CLAUDE_LIGHT_AGENT_HOST=...)
# 逐事件幂等追加:某事件已含引用 host/light.sh 的 hook 就跳过(不重复加、保留你其它 hook)。
# 状态映射:UserPromptSubmit→R 推理 / Notification→Y 等你 / Stop→G 完成
#          PreToolUse(AskUserQuestion)→Y(Claude 问你=等你) / PostToolUse(同)→R(答完继续)
merge_hooks() {
  local cmd="$1 '$LIGHT_SH'"
  if ! command -v jq >/dev/null 2>&1; then
    echo "⚠ 未装 jq,请手动把这些并进 $SETTINGS 的 \"hooks\":"
    echo "  UserPromptSubmit → $cmd R || true"
    echo "  Notification     → $cmd Y || true"
    echo "  Stop             → $cmd G || true"
    echo "  PreToolUse(matcher AskUserQuestion)  → $cmd Y || true"
    echo "  PostToolUse(matcher AskUserQuestion) → $cmd R || true"
    return
  fi
  mkdir -p "$HOME/.claude"; [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  local tmp; tmp="$(mktemp)"
  jq --arg r "$cmd R || true" --arg y "$cmd Y || true" --arg g "$cmd G || true" '
    def add($ev; $obj):
      .hooks[$ev] = ((.hooks[$ev] // []) as $a
        | if ($a | tostring | test("host/light\\.sh")) then $a else $a + [$obj] end);
    add("UserPromptSubmit"; {hooks:[{type:"command",command:$r}]}) |
    add("Notification";     {hooks:[{type:"command",command:$y}]}) |
    add("Stop";             {hooks:[{type:"command",command:$g}]}) |
    add("PreToolUse";       {matcher:"AskUserQuestion",hooks:[{type:"command",command:$y}]}) |
    add("PostToolUse";      {matcher:"AskUserQuestion",hooks:[{type:"command",command:$r}]})
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "✓ hooks 已幂等合并到 $SETTINGS(含 AskUserQuestion→黄;原文件已备份)"
}

# ===== 客户端模式 =====
if [ -n "$AGENT_HOST" ]; then
  echo "模式:客户端 → 状态上报到 $AGENT_HOST:$PORT(本机不起 agent)"
  merge_hooks "CLAUDE_LIGHT_AGENT_HOST='$AGENT_HOST'"
  echo ""
  echo "完成!本机的 Claude 会话状态会同步到 $AGENT_HOST 的灯。"
  echo "  自测: echo '{\"session_id\":\"test\"}' | CLAUDE_LIGHT_AGENT_HOST=$AGENT_HOST \"$LIGHT_SH\" R"
  exit 0
fi

# ===== 服务端模式(插灯那台)=====
PY="$(command -v python3 || true)"
SERIAL="${CLAUDE_LIGHT_SERIAL:-/dev/cu.usbmodem*}"
BIND="${CLAUDE_LIGHT_BIND:-127.0.0.1}"   # 多机同步设 0.0.0.0(让 tailnet 上的机器够得着)
[ -n "$PY" ] || { echo "✗ 找不到 python3"; exit 1; }
echo "模式:服务端  仓库=$REPO  python3=$PY  串口=$SERIAL  监听=$BIND:$PORT"

if [ "$(uname)" = "Darwin" ]; then
  PLIST="$HOME/Library/LaunchAgents/com.claudelight.agent.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.claudelight.agent</string>
  <key>ProgramArguments</key>
  <array><string>$PY</string><string>$AGENT_PY</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CLAUDE_LIGHT_SERIAL</key><string>$SERIAL</string>
    <key>CLAUDE_LIGHT_BIND</key><string>$BIND</string>
    <key>CLAUDE_LIGHT_AGENT_PORT</key><string>$PORT</string>
    <key>PYTHONUNBUFFERED</key><string>1</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/claude-light-agent.log</string>
  <key>StandardErrorPath</key><string>/tmp/claude-light-agent.log</string>
</dict>
</plist>
EOF
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load -w "$PLIST"
  echo "✓ launchd 已加载(开机自启 + 崩溃重启),日志 /tmp/claude-light-agent.log"
else
  echo "⚠ 非 macOS:请自行让 agent 常驻(systemd/nohup 等),用这些环境变量:"
  echo "    CLAUDE_LIGHT_SERIAL='$SERIAL' CLAUDE_LIGHT_BIND='$BIND' CLAUDE_LIGHT_AGENT_PORT='$PORT' '$PY' '$AGENT_PY'"
fi

merge_hooks "CLAUDE_LIGHT_SERIAL='$SERIAL'"
echo ""
echo "完成!插上红绿灯 USB,在 Claude Code 里聊一句就会动。"
echo "  健康检查: curl -s localhost:$PORT/health"
