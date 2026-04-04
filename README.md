# Kimi Code 节点化编排平台 (KimiSwarm4Manus)

**KimiSwarm4Manus** 是一个专为 [Manus](https://manus.im)（作为主 Planner）调度的多智能体（Multi-Agent）协作系统。本项目基于 **"Thin Agent / Fat Platform"** 架构，将 [Claude Code CLI 版本 (CCswarm4Manus)](https://github.com/2019wakeup/CCswarm4Manus) 的核心思路移植到 **[Kimi Code CLI](https://www.kimi.com/code/docs/)** 平台。

## 核心特性

- **零阻塞异步调度**：基于 tmux 守护进程，Manus 下发任务后立即释放
- **轻量级状态探针**：极简 JSON 探针，含死循环检测
- **Kimi Print 模式**：利用 kimi --print --output-format stream-json 实现非交互式自动化
- **优雅中断**：SIGINT 优先，15s 后强制终止

## 与 Claude Code 版本的主要差异

| 特性 | CCswarm4Manus (Claude) | KimiSwarm4Manus (Kimi) |
| :-- | :-- | :-- |
| CLI 命令 | claude --headless | kimi --print |
| Hooks 配置格式 | .claude/settings.json (JSON) | .kimi/config.toml (TOML) |
| 工具权限控制 | --allowedTools | --yolo |
| 输出格式 | --output-format json | --output-format stream-json |
| tmux 会话前缀 | cc_<task_id> | kc_<task_id> |

## 快速开始

```shell
bash setup.sh
bash scripts/kc_dispatch.sh root@server "task_001" "实现用户登录功能" ~/project
bash scripts/kc_probe.sh root@server task_001 ~/project
```

## 参考资料

- [Kimi Code CLI 官方文档](https://www.kimi.com/code/docs/)
- [原始项目 CCswarm4Manus](https://github.com/2019wakeup/CCswarm4Manus)
