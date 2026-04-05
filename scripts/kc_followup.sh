#!/bin/bash
# kc_followup.sh: 向已完成的 Kimi Code 任务追加上下文，以新任务方式继续迭代
#
# 设计理念：
#   当 Manus 发现 Kimi 的任务因缺少信息（如正确路径、API Key、错误原因）而失败时，
#   不应直接 SSH 上去手动修复，而应通过此脚本将补充信息作为新任务下发给 Kimi，
#   让 Kimi 自行修正。这保持了"Manus 只做高维度编排"的原则。
#
# 用法:
#   bash kc_followup.sh <ssh_target> <new_task_id> <prev_task_id> <followup_info> [work_dir]
#
# 参数:
#   ssh_target      - SSH 连接目标
#   new_task_id     - 新任务 ID（如 task_20260326_002）
#   prev_task_id    - 上一个任务的 ID（用于读取上下文）
#   followup_info   - 补充信息或修复指令（如 "正确路径是 /root/rag_store_wiki，请重试"）
#   work_dir        - (可选) 远程工作目录, 默认 ~/project

set -euo pipefail

SSH_TARGET="${1:?必须提供 ssh_target}"
NEW_TASK_ID="${2:?必须提供 new_task_id}"
PREV_TASK_ID="${3:?必须提供 prev_task_id}"
FOLLOWUP_INFO="${4:?必须提供 followup_info}"
WORK_DIR="${5:-~/project}"

MANUS_DIR="${WORK_DIR}/.manus"
PREV_LOG="${MANUS_DIR}/logs/${PREV_TASK_ID}.log"
PREV_PROMPT="${MANUS_DIR}/prompts/${PREV_TASK_ID}.txt"
NEW_PROMPT="${MANUS_DIR}/prompts/${NEW_TASK_ID}.txt"
SESSION_NAME="kc_${NEW_TASK_ID}"
LOG_FILE="${MANUS_DIR}/logs/${NEW_TASK_ID}.log"
EXIT_FILE="${MANUS_DIR}/logs/${NEW_TASK_ID}.exit"
LOCK_FILE="${MANUS_DIR}/orchestration.lock"

REMOTE_CMD=$(cat <<REMOTE
set -e
mkdir -p "${MANUS_DIR}/logs" "${MANUS_DIR}/prompts"

# 构建追加任务的 prompt：包含原始目标 + 上次失败摘要 + 补充信息
PREV_TAIL=\$(tail -30 "${PREV_LOG}" 2>/dev/null | python3 -c "
import sys, json
lines = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        t = obj.get('type','')
        if t == 'assistant':
            for blk in obj.get('message',{}).get('content',[]):
                if blk.get('type') == 'text':
                    lines.append(blk['text'][:200])
        elif t == 'result':
            lines.append('[RESULT] ' + str(obj.get('result',''))[:200])
    except:
        lines.append(line[:200])
print('\n'.join(lines[-10:]))
" 2>/dev/null || tail -10 "${PREV_LOG}" 2>/dev/null | cut -c1-200)

ORIG_GOAL=\$(cat "${PREV_PROMPT}" 2>/dev/null | head -20 || echo "(原始目标不可用)")

cat > "${NEW_PROMPT}" <<EOF
## 继续上一个任务

### 原始目标
\$ORIG_GOAL

### 上次执行的最后输出（摘要）
\$PREV_TAIL

### 补充信息 / 修复指令
${FOLLOWUP_INFO}

### 要求
请根据以上补充信息，继续完成原始目标。遇到问题请自主迭代解决，只有在完全无法继续时，在日志末尾写入 [BLOCKED: 原因]。
EOF

# 检查锁文件
if [ -f "${LOCK_FILE}" ]; then
  LOCKED_PID=\$(jq -r '.pid' "${LOCK_FILE}" 2>/dev/null || echo "")
  if [ -n "\$LOCKED_PID" ] && kill -0 "\$LOCKED_PID" 2>/dev/null; then
    echo '{"status":"locked","message":"有任务正在运行，请先中断"}'
    exit 1
  fi
fi

KIMI_BIN=\$(which kimi 2>/dev/null || echo "/root/.local/share/uv/tools/kimi-cli/bin/kimi")
tmux new-session -d -s "${SESSION_NAME}" -c "${WORK_DIR}" \
  "timeout 7200s bash -c 'cat \"${NEW_PROMPT}\" | \$KIMI_BIN --print --yolo --output-format stream-json > \"${LOG_FILE}\" 2>&1'; echo \$? > \"${EXIT_FILE}\""

TMUX_PID=\$(tmux list-panes -t "${SESSION_NAME}" -F '#{pane_pid}' 2>/dev/null | head -1)
echo "{\"task_id\":\"${LOCK_FILE}\",\"session\":\"${SESSION_NAME}\",\"pid\":\"\$TMUX_PID\",\"started_at\":\"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"work_dir\":\"${WORK_DIR}\"}" > "${LOCK_FILE}"

echo '{"status":"dispatched","task_id":"${NEW_TASK_ID}","session":"${SESSION_NAME}","log":"${LOG_FILE}"}'
REMOTE
)

RESULT=$(ssh $SSH_TARGET "$REMOTE_CMD" 2>&1)
echo "$RESULT"
