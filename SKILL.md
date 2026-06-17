# SKILL.md — Tool Interrupt Injection

将此 skill 安装到 Hermes Agent 后，每次安装新工具时自动触发中断检查注入流程。

## 安装

```bash
hermes skills install tool-interrupt-injection
```

## 使用

安装后，该 skill 会在以下场景自动加载：

1. **新工具安装后** — 自动审计新注册的工具，评估是否需要加中断检查
2. **手动触发** — 运行 `hermes skills run tool-interrupt-injection` 审计所有工具
3. **定期维护** — 建议每季度运行一次，检查新版本 Hermes 是否有新增工具

## 文件结构

```
~/.hermes/skills/hermes/tool-interrupt-injection/
├── SKILL.md          # 本文件 — skill 定义和注入指南
└── scripts/
    └── audit.sh      # 审计脚本 — 列出所有工具的中断覆盖情况
```
