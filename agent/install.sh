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
# 两步,都先备份 settings.json:
#   ① 就地更新:已存在的 light hook 命令里旧的 env 前缀(IP/串口)gsub 成本次的值——
#      换插灯机 / 改 AGENT_HOST 重跑时不再整段跳过,而是把旧 IP 原地改对(只动含 host/light.sh 的命令)。
#   ② 逐事件幂等追加:用各自的特征串判断是否已存在,已存在就不再加(保留你其它 hook)。
# 状态映射:UserPromptSubmit→R 推理 / Notification→Y 等你 / Stop→G 完成
#          PreToolUse(AskUserQuestion)→Y(Claude 问你=等你) / PostToolUse(同)→R(答完继续)
#          Pre/PostToolUse(所有工具)→PING 心跳:刷新会话 ts 保住 R;中断后无心跳 ~R_STALE_S(默认60s)降级 G
merge_hooks() {
  local cmd="$1 '$LIGHT_SH'"
  local newpfx="$1"          # 本次的完整前缀,如 CLAUDE_LIGHT_AGENT_HOST='100.119.112.116'
  local varname="${1%%=*}"   # 前缀的变量名,如 CLAUDE_LIGHT_AGENT_HOST
  if ! command -v jq >/dev/null 2>&1; then
    echo "⚠ 未装 jq,请手动把这些并进 $SETTINGS 的 \"hooks\":"
    echo "  UserPromptSubmit → $cmd R || true"
    echo "  Notification     → $cmd Y || true"
    echo "  Stop             → $cmd G || true"
    echo "  PreToolUse(matcher AskUserQuestion)  → $cmd Y || true"
    echo "  PostToolUse(matcher AskUserQuestion) → $cmd R || true"
    echo "  PreToolUse(matcher \"\" 所有工具)   → $cmd PING || true"
    echo "  PostToolUse(matcher \"\" 所有工具)  → $cmd PING || true"
    return
  fi
  mkdir -p "$HOME/.claude"; [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  local tmp; tmp="$(mktemp)"
  jq --arg r "$cmd R || true" --arg y "$cmd Y || true" --arg g "$cmd G || true" --arg p "$cmd PING || true" \
     --arg var_re "$varname='[^']*'" --arg newpfx "$newpfx" '
    # ① 就地更新:遍历整棵树,把 light hook 命令里旧的 env 前缀(VARNAME=..)gsub 成本次的值。
    #    只动 .command 是字符串且含 host/light.sh 的节点;别的 hook 一律不碰。
    def relight:
      walk(
        if (type == "object") and (has("command"))
           and ((.command | type) == "string")
           and (.command | test("host/light\\.sh"))
        then .command |= gsub($var_re; $newpfx)
        else . end
      );
    # ② 幂等:事件数组里已含 $needle 子串就不再追加。简单事件用 host/light.sh 判断;
    # Pre/PostToolUse 同一事件要放两条(AskUserQuestion 与 PING),各用自己的特征串区分。
    def add($ev; $obj; $needle):
      .hooks[$ev] = ((.hooks[$ev] // []) as $a
        | if ($a | tostring | contains($needle)) then $a else $a + [$obj] end);
    relight |
    add("UserPromptSubmit"; {hooks:[{type:"command",command:$r}]}; "host/light.sh") |
    add("Notification";     {hooks:[{type:"command",command:$y}]}; "host/light.sh") |
    add("Stop";             {hooks:[{type:"command",command:$g}]}; "host/light.sh") |
    add("PreToolUse";       {matcher:"AskUserQuestion",hooks:[{type:"command",command:$y}]}; "AskUserQuestion") |
    add("PostToolUse";      {matcher:"AskUserQuestion",hooks:[{type:"command",command:$r}]}; "AskUserQuestion") |
    add("PreToolUse";       {matcher:"",hooks:[{type:"command",command:$p}]}; "PING || true") |
    add("PostToolUse";      {matcher:"",hooks:[{type:"command",command:$p}]}; "PING || true")
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "✓ hooks 已合并到 $SETTINGS(逐事件幂等、旧 IP/串口就地更新;含 AskUserQuestion→黄、所有工具→PING 心跳;原文件已备份)"
}

# 客户端自测:发一个带临时 session_id 的 START 到目标 agent,再查 /health 确认它出现,最后发 END 清理。
# 一次跑通能同时排除:IP 错 / 端口错 / 没连同一 tailnet / agent 没在跑 / agent 只绑了 127 够不着。
# 返回 0=通(状态能到灯),非 0=不通。注意:它绕过 hooks 直连 agent,抓不到「hooks 装错用户」——那个靠下面的用户提示兜。
selftest_client() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "⚠ 没装 curl,跳过自测(light.sh 也要靠 curl 发状态,请先装 curl 再用)"
    return 0
  fi
  local base="http://$AGENT_HOST:$PORT"
  local sid="clt-selftest-$$-$(date +%s)"
  local pre="${sid:0:8}"   # agent 的 /health 把 session_id 截前 8 位当 key
  echo "自测:发一个临时会话到 $base/event,确认状态真能到达那台 agent…"

  local code
  code=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' \
    -X POST "$base/event" -H "Content-Type: application/json" \
    -d "{\"state\":\"START\",\"hook\":{\"session_id\":\"$sid\"}}" 2>/dev/null) || code=000
  if [ "$code" != "200" ]; then
    echo "✗ 自测失败:连不上 $base/event(HTTP=$code)。状态会静默发不出去,逐项查:"
    echo "    • 插灯那台 agent 在跑吗?     上面执行 curl -s localhost:$PORT/health"
    echo "    • IP / 端口对吗?             这台 ping $AGENT_HOST;现在 AGENT_HOST=$AGENT_HOST PORT=$PORT"
    echo "    • 两台在同一 tailnet 吗?     tailscale status | grep $AGENT_HOST"
    echo "    • agent 绑到 0.0.0.0 了吗?   只绑 127 时 tailnet 够不着 → 插灯那台用"
    echo "                                 CLAUDE_LIGHT_BIND=0.0.0.0 bash agent/install.sh 重装"
    return 1
  fi

  local health found="false"
  health=$(curl -sS -m 5 "$base/health" 2>/dev/null || true)
  if command -v jq >/dev/null 2>&1; then
    found=$(printf '%s' "$health" | jq -r --arg p "$pre" '(.sessions // {}) | has($p)' 2>/dev/null || echo false)
  else
    case "$health" in *"\"$pre\""*) found=true ;; esac
  fi
  # 清理:把临时会话发 END,别让它在聚合里多占一盏绿
  curl -sS -m 5 -o /dev/null \
    -X POST "$base/event" -H "Content-Type: application/json" \
    -d "{\"state\":\"END\",\"hook\":{\"session_id\":\"$sid\"}}" 2>/dev/null || true

  if [ "$found" = "true" ]; then
    echo "✓ 自测通过:临时会话已出现在 $AGENT_HOST 的 /health,状态链路打通了。"
    return 0
  fi
  echo "⚠ START 收到 200 但 /health 里没看到它(多半连到了别的 agent,或会话被立即剔除)。"
  echo "    手动核对:curl -s $base/health"
  return 0
}

# ===== 客户端模式 =====
if [ -n "$AGENT_HOST" ]; then
  echo "模式:客户端 → 状态上报到 $AGENT_HOST:$PORT(本机不起 agent)"
  merge_hooks "CLAUDE_LIGHT_AGENT_HOST='$AGENT_HOST'"
  echo ""
  st_ok=1; selftest_client || st_ok=0
  echo ""
  echo "hooks 写入:$SETTINGS(当前用户 $(id -un))"
  echo "⚠ 若你的 Claude Code 实际跑在别的用户下(远程机常见 root),请用那个用户重跑本脚本——"
  echo "  否则 hooks 进了错的 settings.json,状态会静默发不出去且全程不报错。"
  if [ "$st_ok" = "1" ]; then
    echo ""
    echo "完成!本机的 Claude 会话状态会同步到 $AGENT_HOST 的灯。"
    exit 0
  fi
  echo ""
  echo "⚠ hooks 已写好,但自测没通过——现在状态发不到灯。按上面的提示修好后重跑本脚本再自测。"
  exit 1
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
