#!/usr/bin/env bash
# Claude 红绿灯 · 一键本地部署(macOS,无 iOS)
#
# 在一台新机器上启用红绿灯,只需三步:
#   1. git clone 本仓库
#   2. 跑这个脚本:  bash agent/install.sh
#   3. 把红绿灯的 USB 插上
#
# 它会自动:
#   - 探测仓库路径 / python3 / 串口
#   - 生成并加载 launchd 服务(开机自启 + 崩溃重启 agent.py)
#   - 把 3 个 hook 合并进 ~/.claude/settings.json(先备份,幂等,不动你已有配置)
#
# 前提:Pico 已烧好 MicroPython + firmware/main.py(见 firmware/README.md),
#       且 3 颗 WS2812 已按 HARDWARE.md 接好。固件在 Pico 上,跟机器无关——
#       换机器只需把这个 USB 设备插到新机器即可,不用重新烧。

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIGHT_SH="$REPO/host/light.sh"
AGENT_PY="$REPO/agent/agent.py"
PY="$(command -v python3 || true)"
SERIAL="${CLAUDE_LIGHT_SERIAL:-/dev/cu.usbmodem*}"   # 换机器一般不用改;Linux 用 /dev/ttyACM*
PORT="${CLAUDE_LIGHT_AGENT_PORT:-7321}"
PLIST="$HOME/Library/LaunchAgents/com.claudelight.agent.plist"
SETTINGS="$HOME/.claude/settings.json"

[ -n "$PY" ]        || { echo "✗ 找不到 python3,请先装(brew install python3)"; exit 1; }
[ -f "$AGENT_PY" ]  || { echo "✗ 找不到 $AGENT_PY,确认在仓库里运行"; exit 1; }
chmod +x "$LIGHT_SH" "$AGENT_PY" 2>/dev/null || true

echo "仓库:    $REPO"
echo "python3: $PY"
echo "串口:    $SERIAL"
echo ""

# ---- 1) 生成 launchd plist ----
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
echo "✓ 已生成 $PLIST"

# ---- 2) 加载 launchd ----
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
echo "✓ launchd 已加载(开机自启 + 崩溃自动重启)"

# ---- 3) 合并 hooks 到 ~/.claude/settings.json(备份 + 幂等)----
CMD="CLAUDE_LIGHT_SERIAL='$SERIAL' '$LIGHT_SH'"
if [ -f "$SETTINGS" ] && grep -q "host/light.sh" "$SETTINGS" 2>/dev/null; then
  echo "✓ settings.json 已含 light.sh hooks,跳过合并"
elif command -v jq >/dev/null 2>&1; then
  mkdir -p "$HOME/.claude"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  tmp="$(mktemp)"
  jq --arg r "$CMD R || true" --arg y "$CMD Y || true" --arg g "$CMD G || true" '
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [{hooks:[{type:"command",command:$r}]}]) |
    .hooks.Notification     = ((.hooks.Notification     // []) + [{hooks:[{type:"command",command:$y}]}]) |
    .hooks.Stop             = ((.hooks.Stop             // []) + [{hooks:[{type:"command",command:$g}]}])
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "✓ 已把 hooks 合并进 $SETTINGS(原文件已备份为 .bak.*)"
else
  echo "⚠ 未装 jq,请手动把以下三段合并进 $SETTINGS 的 \"hooks\":"
  echo "  UserPromptSubmit → $CMD R || true"
  echo "  Notification     → $CMD Y || true"
  echo "  Stop             → $CMD G || true"
fi

echo ""
echo "完成!插上红绿灯 USB,在 Claude Code 里随便聊一句,灯就会动。"
echo "  健康检查: curl -s localhost:$PORT/health"
echo "  看日志:   tail -f /tmp/claude-light-agent.log"
echo "  停用:     launchctl unload $PLIST"
