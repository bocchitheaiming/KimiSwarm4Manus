# KimiSwarm4Manus

基于 [CCswarm4Manus](https://github.com/2019wakeup/CCswarm4Manus) 的 Kimi Code CLI 编排平台。将 Kimi Code CLI 作为**自主迭代的员工**，Manus 作为**高维度编排层**，通过 SSH 在远程服务器上异步执行复杂任务。

---

## 核心理念：自主员工 (Agentic Delegation)

> **Kimi Code CLI 是员工，不是工具。**

| 角色 | 职责 |
| :-- | :-- |
| **Manus（老板）** | 下发宏大目标、设定验收标准、15 分钟探针、仅在卡死时介入 |
| **Kimi Code CLI（员工）** | 自主迭代、查日志、修 Bug、只有真正无法解决时才上报 `[BLOCKED]` |

**Manus 绝不应该做的事：**
- 在 Kimi 还在运行时频繁探针（< 10 分钟/次）
- 发现小错误就直接 SSH 上去手动修复（应通过 `kc_followup.sh` 告知 Kimi 修复）
- 将 Kimi 当成简单命令执行器，而不是给它完整的任务目标

---

## 快速开始

```bash
# 1. 将 prompt 写入文件（推荐，避免 shell 转义问题）
cat > /tmp/my_task.txt << 'EOF'
你的任务目标是：...
上下文：...
验收标准：...
遇到问题请自主迭代解决，只有在完全无法继续时，在日志末尾写入 [BLOCKED: 原因]。
EOF

# 2. 下发任务（@ 前缀表示本地文件路径）
bash scripts/kc_dispatch.sh \
  "-p 44365 root@your-host" \
  "task_20260326_001" \
  "@/tmp/my_task.txt" \
  "/root/your-project"

# 3. 15 分钟后探针（不要频繁查询）
bash scripts/kc_probe.sh \
  "-p 44365 root@your-host" \
  "task_20260326_001" \
  "/root/your-project"

# 4. 如果 Kimi 因缺少信息失败，追加上下文让它继续（不要自己动手修）
bash scripts/kc_followup.sh \
  "-p 44365 root@your-host" \
  "task_20260326_002" \
  "task_20260326_001" \
  "正确的路径是 /root/rag_store_wiki，请重试" \
  "/root/your-project"
```

---

## 脚本说明

| 脚本 | 用途 |
| :-- | :-- |
| `kc_dispatch.sh` | 下发新任务（支持 `@文件路径` 方式传入 prompt，避免转义问题） |
| `kc_probe.sh` | 轻量探针，返回极简 JSON 状态（< 100 字节） |
| `kc_interrupt.sh` | 优雅中断当前任务（SIGINT → 15s → SIGKILL） |
| `kc_followup.sh` | 追加上下文，以新任务方式让 Kimi 继续迭代（**推荐替代直接 SSH 修复**） |
| `autostart_mihomo.sh` | AutoDL 环境开机自启 mihomo 代理 |

---

## 探针状态说明

| status | 含义 | Manus 应对措施 |
| :-- | :-- | :-- |
| `running` | 正常运行中 | 继续等待，不要介入 |
| `completed` (exit 0) | 成功完成 | 读取结果文件，验收 |
| `failed` (exit != 0) | 崩溃退出 | 分析 `last_line`，用 `kc_followup.sh` 追加修复信息 |
| `loop_detected` | 死循环 | 中断任务，重新下发更具体的 prompt |
| `timeout` | 超过 2 小时 | 拆分任务，分阶段下发 |

---

## Kimi Code CLI vs Claude Code CLI

| 特性 | Kimi Code | Claude Code |
| :-- | :-- | :-- |
| 非交互模式 | `--print --output-format stream-json` | `--headless` |
| 自动批准 | `--yolo` | `--allowedTools "Edit,Write,..."` |
| Prompt 输入 | `cat prompt.txt \| kimi --print` | `claude -p 'prompt'` |
| Hooks 配置 | `.kimi/config.toml` (TOML) | `.claude/settings.json` (JSON) |
| 工具权限粒度 | 统一 `--yolo` | 细粒度 `--allowedTools` |

---

## 参考资料

- [Kimi Code CLI 官方文档](https://www.kimi.com/code/docs/)
- [原始项目 CCswarm4Manus](https://github.com/2019wakeup/CCswarm4Manus)
