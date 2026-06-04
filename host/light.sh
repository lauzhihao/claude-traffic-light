#!/usr/bin/env bash
# Claude 红绿灯 hook 分发器
#
# 行为：
#   1. 优先 POST 到 localhost agent（带上 hook 的完整 stdin JSON）
#   2. agent 不在时 fallback：直推中继 + 写串口
#
# 用法：
#   light.sh R    UserPromptSubmit
#   light.sh Y    Notification
#   light.sh G    Stop
#   light.sh PRE  PreToolUse  ← 不改状态，只把工具信息送给 agent 暂存
#   light.sh PING Pre/PostToolUse(所有工具) ← 心跳:刷新会话时间戳保住 R,不改颜色

set -u

STATE="${1:-}"
case "$STATE" in R|Y|G|PRE|PING) ;; *) exit 0 ;; esac

# 读 hook 的 stdin JSON（Claude Code 会传 session_id / tool_name / tool_input 等）
HOOK_JSON="{}"
if [ ! -t 0 ]; then
  HOOK_JSON=$(cat)
fi

# smart-Stop:回合结束(G)时,若结束语是"等你授权/Go",改判为 Y(黄=等你决策)。
# 标记可用 CLAUDE_LIGHT_WAIT_PATTERN 覆盖;取不到 transcript/没装 jq/不匹配 → 维持 G(安全退化)。
WAIT_PATTERN="${CLAUDE_LIGHT_WAIT_PATTERN:-AWAITING AUTHORIZATION|Type .?Go.? to execute}"
if [ "$STATE" = "G" ] && command -v jq >/dev/null 2>&1; then
  _TRANSCRIPT=$(printf '%s' "$HOOK_JSON" | jq -r '.transcript_path // empty' 2>/dev/null)
  if [ -n "${_TRANSCRIPT:-}" ] && [ -f "$_TRANSCRIPT" ]; then
    _LAST=$(tail -n 400 "$_TRANSCRIPT" | jq -rs '[.[]|select(.type=="assistant").message.content[]?|select(.type=="text").text]|last // empty' 2>/dev/null || true)
    # 只匹配「最后一非空行」:协议把"等授权"标记放在结尾那行;正文里提到该词(比如讨论本功能)不算,避免误判
    _LASTLINE=$(printf '%s' "${_LAST:-}" | grep -v '^[[:space:]]*$' | tail -n 1)
    if printf '%s' "${_LASTLINE:-}" | grep -qiE "$WAIT_PATTERN"; then
      STATE=Y
    fi
  fi
fi

PAYLOAD=$(printf '{"state":"%s","hook":%s}' "$STATE" "$HOOK_JSON")

AGENT_PORT="${CLAUDE_LIGHT_AGENT_PORT:-7321}"
AGENT_HOST="${CLAUDE_LIGHT_AGENT_HOST:-127.0.0.1}"   # 多机同步:设成「插灯那台」的 tailscale IP
if curl -sS -m 2 --noproxy '*' -X POST "http://$AGENT_HOST:$AGENT_PORT/event" \
     -H "Content-Type: application/json" \
     -d "$PAYLOAD" >/dev/null 2>&1; then
  exit 0
fi

# Agent 不在 → fallback。PRE/PING 只对 agent 有意义(暂存/心跳),直接退出,不写串口
case "$STATE" in PRE|PING) exit 0 ;; esac

# 直推中继（后台）
if [ -n "${CLAUDE_LIGHT_RELAY_URL:-}" ] && [ -n "${CLAUDE_LIGHT_UPDATE_SECRET:-}" ]; then
  (curl -sS -m 2 -X POST "$CLAUDE_LIGHT_RELAY_URL/update" \
     -H "Content-Type: application/json" \
     -d "{\"state\":\"$STATE\",\"secret\":\"$CLAUDE_LIGHT_UPDATE_SECRET\"}" \
     >/dev/null 2>&1) &
fi

# 写串口
SERIAL_GLOB="${CLAUDE_LIGHT_SERIAL:-/dev/tty.usbmodem*}"
for dev in $SERIAL_GLOB; do
  if [ -e "$dev" ]; then
    printf '%s' "$STATE" > "$dev" 2>/dev/null || true
    break
  fi
done

exit 0
