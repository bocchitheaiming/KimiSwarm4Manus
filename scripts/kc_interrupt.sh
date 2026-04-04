#!/bin/bash
# kc_interrupt.sh: 优雅中断远程 Kimi Code 任务，释放锁，保留日志
# 使用 SIGINT 而非 SIGKILL，确保 Kimi Code 有机会保存 checkpoint
#
# 用法:
#   bash kc_interrupt.sh <ssh_target> <task_id> [work_dir] [reason]
#
# 参数:
#   ssh_target - SSH 连接目标
#   task_id    - 要中断的任务 ID（或 "current" 表示中断当前锁定的任务）
#   work_dir   - (可选) 远程工作目录, 默认 ~/project
#   reason     - (可选) 中断原因，写入日志，默认 "manual_interrupt"
#
# 输出 JSON:
#   status           - interrupted | not_running | already_stopped
#   task_id          - 实际被中断的任务 ID
#   reason           - 中断原因
#   state_updated    - true | false，表示 claude-progress.json 是否成功更新
#   state_update_err - 仅在 state_updated=false 时出现，包含错误信息

set -euo pipefail

SSH_TARGET="${1:?必须提供 ssh_target}"
TASK_ID="${2:?必须提供 task_id}"
WORK_DIR="${3:-~/project}"
REASON="${4:-manual_interrupt}"

MANUS_DIR="${WORK_DIR}/.manus"
LOCK_FILE="${MANUS_DIR}/orchestration.lock"

REMOTE_CMD=$(cat <<'REMOTE'
set -e
TASK_ID="__TASK_ID__"
LOCK_FILE="__LOCK_FILE__"
MANUS_DIR="__MANUS_DIR__"
REASON="__REASON__"
WORK_DIR="__WORK_DIR__"

# 若 task_id 为 "current"，从锁文件读取实际 task_id
if [ "$TASK_ID" = "current" ]; then
  if [ ! -f "$LOCK_FILE" ]; then
    echo '{"status":"not_running","message":"no lock file found"}'
    exit 0
  fi
  TASK_ID=$(jq -r '.task_id' "$LOCK_FILE" 2>/dev/null || echo "")
fi

SESSION_NAME="kc_${TASK_ID}"
EXIT_FILE="${MANUS_DIR}/logs/${TASK_ID}.exit"

# 检查 tmux 会话是否存在
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "{\"status\":\"already_stopped\",\"task_id\":\"${TASK_ID}\"}"
  exit 0
fi

# 从锁文件获取 PID
LOCKED_PID=$(jq -r '.pid // empty' "$LOCK_FILE" 2>/dev/null || echo "")

# 发送 SIGINT（优雅中断，允许 Kimi Code 保存 checkpoint）
if [ -n "$LOCKED_PID" ] && kill -0 "$LOCKED_PID" 2>/dev/null; then
  kill -SIGINT "$LOCKED_PID" 2>/dev/null || true
fi

# 等待最多 15 秒让进程自行退出
WAIT=0
while tmux has-session -t "$SESSION_NAME" 2>/dev/null && [ $WAIT -lt 15 ]; do
  sleep 1
  WAIT=$((WAIT + 1))
done

# 若仍未退出，强制 kill tmux 会话
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
fi

# 写入退出码文件（标记为中断退出 130）
echo "130" > "$EXIT_FILE"

# 追加中断记录到日志
echo "[MANUS_INTERRUPT] reason=${REASON} at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${MANUS_DIR}/logs/${TASK_ID}.log" 2>/dev/null || true

# 删除锁文件
rm -f "$LOCK_FILE"

# ── 节点端状态更新 ─────────────────────────────────────────────────────────────
# 利用 state_manager.js 将 claude-progress.json 中对应任务标记为 interrupted。
# 要求远程 WORK_DIR 下存在 src/state_manager.js（即项目已部署到远程节点）。
STATE_MANAGER="${WORK_DIR}/src/state_manager.js"
STATE_UPDATED="false"
STATE_UPDATE_ERR=""

if command -v node >/dev/null 2>&1 && [ -f "$STATE_MANAGER" ]; then
  # 计算 manusDir：state_manager 默认以 ./manus 为相对路径，此处传入绝对路径
  UPDATE_RESULT=$(node -e "
    const sm = require('${STATE_MANAGER}');
    try {
      sm.updateTaskStatus('${TASK_ID}', 'interrupted', 'Interrupted by Manus: ${REASON}', '${MANUS_DIR}');
      console.log(JSON.stringify({ok: true}));
    } catch(e) {
      console.log(JSON.stringify({ok: false, err: e.message}));
    }
  " 2>/dev/null || echo '{"ok":false,"err":"node execution failed"}')

  if echo "$UPDATE_RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
    STATE_UPDATED="true"
  else
    STATE_UPDATE_ERR=$(echo "$UPDATE_RESULT" | jq -r '.err // "unknown error"' 2>/dev/null || echo "parse error")
  fi
else
  # node 或 state_manager.js 不可用，记录原因供平台端兜底处理
  if ! command -v node >/dev/null 2>&1; then
    STATE_UPDATE_ERR="node not found on remote host"
  else
    STATE_UPDATE_ERR="state_manager.js not found at ${STATE_MANAGER}"
  fi
fi
# ── 节点端状态更新结束 ─────────────────────────────────────────────────────────

# 输出最终 JSON（包含 state_updated 字段，供平台端判断是否需要兜底更新）
if [ "$STATE_UPDATED" = "true" ]; then
  echo "{\"status\":\"interrupted\",\"task_id\":\"${TASK_ID}\",\"reason\":\"${REASON}\",\"state_updated\":true}"
else
  # 对 STATE_UPDATE_ERR 做简单转义，防止破坏 JSON 结构
  SAFE_ERR=$(echo "$STATE_UPDATE_ERR" | sed 's/"/\\"/g')
  echo "{\"status\":\"interrupted\",\"task_id\":\"${TASK_ID}\",\"reason\":\"${REASON}\",\"state_updated\":false,\"state_update_err\":\"${SAFE_ERR}\"}"
fi
REMOTE
)

# 替换占位符
REMOTE_CMD="${REMOTE_CMD//__TASK_ID__/$TASK_ID}"
REMOTE_CMD="${REMOTE_CMD//__LOCK_FILE__/$LOCK_FILE}"
REMOTE_CMD="${REMOTE_CMD//__MANUS_DIR__/$MANUS_DIR}"
REMOTE_CMD="${REMOTE_CMD//__REASON__/$REASON}"
REMOTE_CMD="${REMOTE_CMD//__WORK_DIR__/$WORK_DIR}"

# 执行远程命令，捕获输出
RESULT=$(ssh "$SSH_TARGET" "$REMOTE_CMD" 2>&1)

# ── 平台端（Manus）兜底状态更新 ────────────────────────────────────────────────
# 当节点端因 node/state_manager.js 不可用而未能更新状态时，
# 平台端（本机）尝试通过 SSH 直接写入状态文件作为兜底。
# 这体现了 "Fat Platform" 架构：最终一致性由主 Planner 保障。
STATE_UPDATED=$(echo "$RESULT" | jq -r '.state_updated // "false"' 2>/dev/null || echo "false")
RESULT_STATUS=$(echo "$RESULT" | jq -r '.status // ""' 2>/dev/null || echo "")

if [ "$RESULT_STATUS" = "interrupted" ] && [ "$STATE_UPDATED" = "false" ]; then
  # 节点端更新失败，平台端通过 SSH 直接执行 Node.js 兜底更新
  FALLBACK_RESULT=$(ssh "$SSH_TARGET" "
    node -e \"
      const sm = require('${WORK_DIR}/src/state_manager.js');
      try {
        sm.updateTaskStatus('${TASK_ID}', 'interrupted', 'Interrupted by Manus (platform fallback): ${REASON}', '${MANUS_DIR}');
        console.log('ok');
      } catch(e) {
        console.error('fallback_err: ' + e.message);
      }
    \" 2>/dev/null
  " 2>/dev/null || echo "ssh_fallback_failed")

  if [ "$FALLBACK_RESULT" = "ok" ]; then
    # 兜底成功，更新输出 JSON 中的 state_updated 字段
    RESULT=$(echo "$RESULT" | jq '. + {"state_updated": true, "state_update_source": "platform_fallback"}' 2>/dev/null || echo "$RESULT")
  fi
fi
# ── 平台端兜底结束 ─────────────────────────────────────────────────────────────

echo "$RESULT"
