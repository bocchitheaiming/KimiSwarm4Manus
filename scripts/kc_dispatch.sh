#!/bin/bash
# kc_dispatch.sh: 在远程服务器上以 tmux 守护方式异步启动 Kimi Code 任务
#
# 用法:
#   bash kc_dispatch.sh <ssh_target> <task_id> <prompt_or_file> [work_dir] [yolo]
#
# 参数:
#   ssh_target        - SSH 连接目标, 如 "-p 44365 user@host"
#   task_id           - 唯一任务 ID, 如 task_20260326_001
#   prompt_or_file    - 任务 Prompt 内容 或 本地 Prompt 文件路径（以 @/ 或 @~ 开头）
#                       推荐使用文件方式（@/path/to/prompt.txt）避免 shell 转义问题
#   work_dir          - (可选) 远程工作目录, 默认 ~/project
#   yolo              - (可选) 是否自动同意所有操作, 默认 true
#
# 输出:
#   成功: {"status":"dispatched","task_id":"...","session":"...","log":"..."}
#   锁定: {"status":"locked","task_id":"...","pid":"..."}
#   错误: {"status":"error","message":"..."}
#
# 最佳实践:
#   1. 给出宏大且明确的目标，包含上下文、预期结果、验收标准
#   2. 明确告知 Kimi：遇到问题应自主迭代，只有真正无法解决时才在日志中写 [BLOCKED]
#   3. 下发后设置 15 分钟探针，让 Kimi 有充足时间自行试错和修复

set -euo pipefail

SSH_TARGET="${1:?必须提供 ssh_target}"
TASK_ID="${2:?必须提供 task_id}"
PROMPT_ARG="${3:?必须提供 prompt 内容或文件路径}"
WORK_DIR="${4:-~/project}"
YOLO="${5:-true}"

SESSION_NAME="kc_${TASK_ID}"
MANUS_DIR="${WORK_DIR}/.manus"
LOG_FILE="${MANUS_DIR}/logs/${TASK_ID}.log"
EXIT_FILE="${MANUS_DIR}/logs/${TASK_ID}.exit"
LOCK_FILE="${MANUS_DIR}/orchestration.lock"
REMOTE_PROMPT_FILE="${MANUS_DIR}/prompts/${TASK_ID}.txt"

YOLO_ARG=""
if [ "$YOLO" = "true" ]; then
  YOLO_ARG="--yolo"
fi

# 处理 prompt：若以 @ 开头则视为本地文件路径，上传到远程；否则直接写入远程文件
if [[ "$PROMPT_ARG" == @* ]]; then
  LOCAL_FILE="${PROMPT_ARG:1}"
  if [ ! -f "$LOCAL_FILE" ]; then
    echo "{\"status\":\"error\",\"message\":\"本地 prompt 文件不存在: $LOCAL_FILE\"}"
    exit 1
  fi
  # 先确保远程目录存在，再上传文件
  ssh $SSH_TARGET "mkdir -p '${MANUS_DIR}/prompts'" 2>/dev/null
  scp $LOCAL_FILE "$SSH_TARGET:${REMOTE_PROMPT_FILE}" 2>/dev/null
else
  # 直接写入远程文件
  ssh $SSH_TARGET "mkdir -p '${MANUS_DIR}/prompts' && cat > '${REMOTE_PROMPT_FILE}'" <<< "$PROMPT_ARG"
fi

# 在远程执行的完整命令
REMOTE_CMD=$(cat <<REMOTE
set -e
mkdir -p "${MANUS_DIR}/logs"

# 检查锁文件，防止并发冲突
if [ -f "${LOCK_FILE}" ]; then
  LOCKED_PID=\$(jq -r '.pid' "${LOCK_FILE}" 2>/dev/null || echo "")
  LOCKED_TASK=\$(jq -r '.task_id' "${LOCK_FILE}" 2>/dev/null || echo "")
  if [ -n "\$LOCKED_PID" ] && kill -0 "\$LOCKED_PID" 2>/dev/null; then
    echo '{"status":"locked","task_id":"'"\$LOCKED_TASK"'","pid":"'"\$LOCKED_PID"'"}'
    exit 1
  fi
fi

# 检查同名 tmux 会话是否已存在（幂等性保护）
if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
  echo '{"status":"already_running","task_id":"${TASK_ID}","session":"${SESSION_NAME}"}'
  exit 0
fi

# 启动 tmux 守护会话，通过 stdin 方式传入 prompt（避免 shell 转义问题）
KIMI_BIN=\$(which kimi 2>/dev/null || echo "/root/.local/share/uv/tools/kimi-cli/bin/kimi")
tmux new-session -d -s "${SESSION_NAME}" -c "${WORK_DIR}" \
  "timeout 7200s bash -c 'cat \"${REMOTE_PROMPT_FILE}\" | \$KIMI_BIN --print ${YOLO_ARG} --output-format stream-json > \"${LOG_FILE}\" 2>&1'; echo \$? > \"${EXIT_FILE}\""

# 写入锁文件
TMUX_PID=\$(tmux list-panes -t "${SESSION_NAME}" -F '#{pane_pid}' 2>/dev/null | head -1)
echo "{\"task_id\":\"${TASK_ID}\",\"session\":\"${SESSION_NAME}\",\"pid\":\"\$TMUX_PID\",\"started_at\":\"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"work_dir\":\"${WORK_DIR}\",\"prompt_file\":\"${REMOTE_PROMPT_FILE}\"}" > "${LOCK_FILE}"

echo '{"status":"dispatched","task_id":"${TASK_ID}","session":"${SESSION_NAME}","log":"${LOG_FILE}","prompt_file":"${REMOTE_PROMPT_FILE}"}'
REMOTE
)

RESULT=$(ssh $SSH_TARGET "$REMOTE_CMD" 2>&1)
echo "$RESULT"
