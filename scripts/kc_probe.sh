#!/bin/bash
# kc_probe.sh: 轻量探针，查询远程 Kimi Code 任务状态，返回极简 JSON
# 设计原则：每次调用 Token 消耗极低（< 100 字节响应），绝不读取完整日志
#
# 用法:
#   bash kc_probe.sh <ssh_target> <task_id> [work_dir]
#
# 输出 JSON 字段:
#   status       - running | completed | failed | timeout | loop_detected | not_found
#   task_id      - 任务 ID
#   exit_code    - 进程退出码 (仅 completed/failed 时有值)
#   last_line    - 日志最后一行摘要 (截断至 120 字符)
#   loop_warning - true/false, 检测到重复模式时为 true
#   elapsed_sec  - 任务已运行秒数

set -euo pipefail

SSH_TARGET="${1:?必须提供 ssh_target}"
TASK_ID="${2:?必须提供 task_id}"
WORK_DIR="${3:-~/project}"

MANUS_DIR="${WORK_DIR}/.manus"
LOG_FILE="${MANUS_DIR}/logs/${TASK_ID}.log"
EXIT_FILE="${MANUS_DIR}/logs/${TASK_ID}.exit"
LOCK_FILE="${MANUS_DIR}/orchestration.lock"

REMOTE_CMD=$(cat <<'REMOTE'
set -e
TASK_ID="__TASK_ID__"
LOG_FILE="__LOG_FILE__"
EXIT_FILE="__EXIT_FILE__"
LOCK_FILE="__LOCK_FILE__"
SESSION_NAME="kc_${TASK_ID}"

# 检查日志文件是否存在
if [ ! -f "$LOG_FILE" ]; then
  echo "{\"status\":\"not_found\",\"task_id\":\"${TASK_ID}\"}"
  exit 0
fi

# 读取退出码文件（若存在则任务已结束）
if [ -f "$EXIT_FILE" ]; then
  EXIT_CODE=$(cat "$EXIT_FILE" | tr -d '[:space:]')
  LAST_LINE=$(tail -1 "$LOG_FILE" 2>/dev/null | cut -c1-120 | sed 's/"/\\"/g')
  if [ "$EXIT_CODE" = "0" ]; then
    STATUS="completed"
  elif [ "$EXIT_CODE" = "124" ]; then
    STATUS="timeout"
  else
    STATUS="failed"
  fi
  echo "{\"status\":\"${STATUS}\",\"task_id\":\"${TASK_ID}\",\"exit_code\":${EXIT_CODE},\"last_line\":\"${LAST_LINE}\",\"loop_warning\":false}"
  exit 0
fi

# 任务仍在运行：检查 tmux 会话
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  # tmux 会话消失但无 exit 文件，说明异常崩溃
  LAST_LINE=$(tail -1 "$LOG_FILE" 2>/dev/null | cut -c1-120 | sed 's/"/\\"/g')
  echo "{\"status\":\"failed\",\"task_id\":\"${TASK_ID}\",\"exit_code\":-1,\"last_line\":\"${LAST_LINE}\",\"loop_warning\":false}"
  exit 0
fi

# 计算运行时长
STARTED_AT=$(jq -r '.started_at // empty' "$LOCK_FILE" 2>/dev/null || echo "")
ELAPSED=0
if [ -n "$STARTED_AT" ]; then
  START_TS=$(date -d "$STARTED_AT" +%s 2>/dev/null || echo 0)
  NOW_TS=$(date +%s)
  ELAPSED=$((NOW_TS - START_TS))
fi

# 死循环检测：检查最近 60 行是否有高度重复（同一行出现 3 次以上）
LOOP_WARNING="false"
REPEAT_COUNT=$(tail -60 "$LOG_FILE" 2>/dev/null | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
if [ "${REPEAT_COUNT:-0}" -ge 3 ]; then
  LOOP_WARNING="true"
fi

LAST_LINE=$(tail -1 "$LOG_FILE" 2>/dev/null | cut -c1-120 | sed 's/"/\\"/g')
echo "{\"status\":\"running\",\"task_id\":\"${TASK_ID}\",\"elapsed_sec\":${ELAPSED},\"last_line\":\"${LAST_LINE}\",\"loop_warning\":${LOOP_WARNING}}"
REMOTE
)

# 替换占位符
REMOTE_CMD="${REMOTE_CMD//__TASK_ID__/$TASK_ID}"
REMOTE_CMD="${REMOTE_CMD//__LOG_FILE__/$LOG_FILE}"
REMOTE_CMD="${REMOTE_CMD//__EXIT_FILE__/$EXIT_FILE}"
REMOTE_CMD="${REMOTE_CMD//__LOCK_FILE__/$LOCK_FILE}"

ssh "$SSH_TARGET" "$REMOTE_CMD" 2>&1
