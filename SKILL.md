---
name: tool-interrupt-injection
title: Hermes Tool Interrupt Injection
description: 为新安装的 Hermes 工具自动添加中断检查（is_interrupted），在安全边界处插入检查点，确保用户发消息能立即中断工具执行。
tags: [hermes, tools, interrupt, safety, audit]
---

# Hermes Tool Interrupt Injection

为新安装或已有的 Hermes 工具添加 `is_interrupted()` 检查点，使用户在 agent 忙碌时发消息能立刻中断工具执行并响应。

## 触发条件

- 新安装了一个工具/插件后
- 定期审计所有已注册工具的中断覆盖情况
- 用户反馈"发消息后你很久没反应"
- 工具可能阻塞（网络 I/O、LLM 调用、大文件处理、循环操作）

## 评估流程

### 1. 列出所有已注册工具

```bash
# 查看所有注册的工具及其文件
cd /usr/local/lib/hermes-agent/tools
grep -l "registry.register(" *.py | sort
```

### 2. 检查哪些已有中断

```bash
cd /usr/local/lib/hermes-agent/tools
for f in *.py; do
    if grep -q "registry.register(" "$f" 2>/dev/null; then
        has_int=$(grep -c "is_interrupted" "$f")
        echo "$f: $has_int interrupt check(s)"
    fi
done
```

### 3. 评估工具是否需要中断

**需要加的** — 包含以下特征之一：
- 网络请求（`requests.`、`httpx`、`aiohttp`、`urllib`、`websocket`）
- API 调用（`.get(`、`.post(`、`.put(`、`.delete(`）
- LLM 调用（`completions`、`chat`、`generate`）
- 异步函数（`async def`）
- 循环操作（`for`、`while`）
- `time.sleep` / `asyncio.sleep`
- `subprocess` / `Popen`

**不需要加的** — 纯本地操作，毫秒级完成：
- 纯文件 I/O（`read_file`、`write_file`、`patch`、`search_files`）
- 纯内存操作（`memory`、`todo`、`kanban_*`）
- 本地数据库查询（`session_search`）
- 纯 schema/注册逻辑（`registry`、`skills_list`、`skill_view`）
- 纯 UI 交互（`clarify`、`read_terminal`）

## 注入标准模式

### 入口检查（所有工具都需要）

在参数验证之后、实际耗时操作之前插入：

```python
def my_tool_handler(args, **kw):
    # 参数验证
    if not args.get("param"):
        return tool_error("param is required")

    # ── Interrupt check ──
    from tools.interrupt import is_interrupted
    if is_interrupted():
        return tool_error("Interrupted", success=False)

    # 实际耗时操作...
    result = expensive_api_call()
    return json.dumps({"result": result})
```

### 循环内检查（有循环的工具）

在循环体开头加检查点，利用 `finally` 做好收尾清理：

```python
def my_tool_with_loop(args, **kw):
    from tools.interrupt import is_interrupted

    resources = []  # 跟踪需要清理的资源
    try:
        for item in items:
            # ── Interrupt check in loop ──
            if is_interrupted():
                return tool_error("Interrupted", success=False)

            resource = acquire_resource(item)
            resources.append(resource)
            process(resource)

        return json.dumps({"status": "success"})
    finally:
        # ── Cleanup: 确保中断后资源被释放 ──
        for r in resources:
            try:
                release_resource(r)
            except Exception:
                pass
```

### 多阶段检查（有多个耗时阶段的工具）

在每个耗时阶段前加检查点：

```python
async def multi_stage_tool(args, **kw):
    from tools.interrupt import is_interrupted

    try:
        # ── Interrupt check before stage 1 ──
        if is_interrupted():
            return json.dumps({"error": "Interrupted"})

        stage1_result = await stage1()

        # ── Interrupt check before stage 2 ──
        if is_interrupted():
            # 可以返回阶段1的部分结果
            return json.dumps({"partial": stage1_result, "error": "Interrupted"})

        stage2_result = await stage2(stage1_result)
        return json.dumps({"result": stage2_result})
    finally:
        await cleanup()
```

### 异步工具

`is_interrupted()` 在异步函数中同样有效：

```python
async def async_handler(args, **kw):
    from tools.interrupt import is_interrupted
    if is_interrupted():
        return tool_error("Interrupted")
    result = await async_api_call()
    return tool_result(result)
```

## 返回值约定

中断后返回的格式要与工具原有返回值风格一致：

| 工具导入的辅助函数 | 中断返回值 |
|---|---|
| `from tools.registry import tool_error` | `tool_error("Interrupted", success=False)` |
| `from tools.registry import tool_result` | `tool_result(error="Interrupted")` |
| 直接用 `json.dumps` | `json.dumps({"error": "Interrupted"})` |
| `json.dumps` + 自定义字段 | `json.dumps({"error": "Interrupted", "status": "cancelled"})` |

## 验证方法

### 1. 语法检查

```bash
python3 -c "import py_compile; py_compile.compile('path/to/tool.py', doraise=True); print('✅ OK')"
```

### 2. 批量验证所有修改过的文件

```bash
cd /usr/local/lib/hermes-agent/tools
for f in *.py; do
    python3 -c "import py_compile; py_compile.compile('$f', doraise=True)" 2>/dev/null && echo "✅ $f" || echo "❌ $f"
done
```

### 3. 确认 import 不报错

```bash
python3 -c "from tools.interrupt import is_interrupted; print('import OK')"
```

### 4. 验证中断实际生效

```bash
export HERMES_DEBUG_INTERRUPT=1
```

然后启动 Hermes，执行一个会阻塞的工具，在另一个窗口发消息——日志中会显示 `[interrupt-debug]` 跟踪。

## 常见陷阱

### 只在入口检查不够

如果工具有多个耗时阶段（如抓取 + LLM 处理），只在入口检查意味着"中断信号在阶段1期间到达，但阶段2仍然会执行"。应该在每个耗时阶段前都加检查。

### 不要忘记 finally 清理

中断后资源可能处于"已分配但未使用"状态。如果有临时文件、网络连接、锁等资源，用 `try/finally` 确保清理。

### 不要修改原有逻辑

中断检查只是提前返回的退出点，不改任何原有逻辑。确保：
- 原有 try/except 结构不变
- 原有返回值格式不变（只是提前返回）
- 原有 debug 日志路径不变

### 惰性导入

`from tools.interrupt import is_interrupted` 放在函数内部而不是文件顶部，避免在工具发现阶段就加载中断模块。这不会影响性能——Python 会缓存已导入的模块。

## 相关文件

- `tools/interrupt.py` — 中断系统的核心实现（`set_interrupt`、`is_interrupted`）
- `tools/registry.py` — 工具注册表，`tool_error` 和 `tool_result` 辅助函数
- `agent/tool_executor.py` — 工具执行器，并发执行和中断传播
- `run_agent.py` — `AIAgent.interrupt()` 方法
