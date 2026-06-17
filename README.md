# 🛑 Hermes Tool Interrupt Injection

> 为 Hermes Agent 工具自动添加 `is_interrupted()` 检查点，确保用户发消息能立即中断工具执行。

## 为什么需要这个？

当 Hermes Agent 在执行一个耗时工具（如网络请求、LLM 调用、图片生成）时，如果用户发消息，系统会发送中断信号。但**工具必须主动检查这个信号**才能响应中断。

没有中断检查的工具会：
- 无视用户的新消息，继续执行到完成
- 让用户感觉"卡住了"或"不理我"
- 在 gateway 多会话场景下阻塞其他会话

## 工作原理

```
用户发消息 → gateway → agent.interrupt()
  └─ 设置 _interrupt_requested = True
  └─ 标记当前线程为"已中断"

工具内 is_interrupted() 检查
  └─ 返回 True → 工具提前返回 "Interrupted" 错误
  └─ 返回 False → 继续正常执行
```

中断系统是**线程级别**的——每个 agent 会话的线程互不影响，gateway 多会话并发时安全。

## 哪些工具需要加？

### ✅ 需要加（可能阻塞）

| 特征 | 示例 |
|------|------|
| 网络请求 | `requests.`、`httpx`、`aiohttp`、`websocket` |
| API 调用 | `.get(`、`.post(`、`.put(`、`.delete(` |
| LLM 调用 | `completions`、`chat`、`generate` |
| 异步函数 | `async def` |
| 循环操作 | `for`、`while` 循环 |
| 延时等待 | `time.sleep`、`asyncio.sleep` |
| 子进程 | `subprocess`、`Popen` |

### ❌ 不需要加（毫秒级完成）

纯文件 I/O、纯内存操作、本地数据库查询、纯 schema/注册逻辑、纯 UI 交互。

## 注入模式

### 1️⃣ 入口检查（所有工具都需要）

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

### 2️⃣ 循环内检查 + finally 清理

```python
def my_tool_with_loop(args, **kw):
    from tools.interrupt import is_interrupted
    resources = []

    try:
        for item in items:
            if is_interrupted():
                return tool_error("Interrupted", success=False)
            resource = acquire_resource(item)
            resources.append(resource)
            process(resource)
        return json.dumps({"status": "success"})
    finally:
        for r in resources:
            try:
                release_resource(r)
            except Exception:
                pass
```

### 3️⃣ 多阶段检查

```python
async def multi_stage_tool(args, **kw):
    from tools.interrupt import is_interrupted

    # Stage 1
    if is_interrupted():
        return json.dumps({"error": "Interrupted"})
    stage1_result = await stage1()

    # Stage 2
    if is_interrupted():
        return json.dumps({"partial": stage1_result, "error": "Interrupted"})
    stage2_result = await stage2(stage1_result)

    return json.dumps({"result": stage2_result})
```

## 快速审计脚本

```bash
cd /usr/local/lib/hermes-agent/tools
for f in *.py; do
    if grep -q "registry.register(" "$f" 2>/dev/null; then
        has_int=$(grep -c "is_interrupted" "$f")
        echo "$f: $has_int interrupt check(s)"
    fi
done
```

## 安装

### 方式一：通过 Hermes CLI 安装（推荐）

```bash
hermes skills install tool-interrupt-injection
```

### 方式二：手动安装

```bash
# 克隆仓库
git clone https://github.com/oodop37/hermes-tool-interrupt-injection.git
# 复制到 Hermes skills 目录
cp -r hermes-tool-interrupt-injection ~/.hermes/skills/hermes/tool-interrupt-injection
```

### 方式三：从 ClawHub 安装

```bash
hermes skills install --from clawhub tool-interrupt-injection
```

## 使用

### 场景 1：新安装工具后自动审计

安装新工具后，加载本 skill 按流程操作：

```bash
# 加载 skill 获取完整指南
hermes skills run tool-interrupt-injection

# 或者手动查看
hermes skill view tool-interrupt-injection
```

### 场景 2：一键审计所有工具

```bash
# 使用内置审计脚本
bash ~/.hermes/skills/hermes/tool-interrupt-injection/scripts/audit.sh

# 或直接运行仓库中的脚本
bash scripts/audit.sh
```

### 场景 3：手动注入中断检查

按以下步骤操作：

1. **评估** — 用审计脚本找出缺少中断的工具
2. **定位** — 找到工具 handler 函数的入口
3. **注入** — 在参数验证后、耗时操作前加入口检查
4. **循环** — 有循环的加循环内检查 + `try/finally` 清理
5. **验证** — `python3 -c "import py_compile; py_compile.compile('tool.py', doraise=True)"`

详细注入模式和代码示例见 [SKILL.md](./SKILL.md)。

## 已注入的工具清单

| 工具 | 文件 | 检查点 |
|------|------|--------|
| `x_search` | `x_search_tool.py` | 入口 + 重试循环 |
| `image_generate` | `image_generation_tool.py` | 入口 |
| `video_generate` | `video_generation_tool.py` | 入口 |
| `text_to_speech` | `tts_tool.py` | 入口 |
| `ha_list_entities` | `homeassistant_tool.py` | 入口 |
| `ha_get_state` | `homeassistant_tool.py` | 入口 |
| `ha_call_service` | `homeassistant_tool.py` | 入口 |
| `ha_list_services` | `homeassistant_tool.py` | 入口 |
| `delegate_task` | `delegate_tool.py` | 入口 |
| `discord` / `discord_admin` | `discord_tool.py` | 公共函数入口 |
| `feishu_doc_read` | `feishu_doc_tool.py` | 入口 |
| `feishu_drive_*` (×4) | `feishu_drive_tool.py` | 每个 handler 入口 |
| `mixture_of_agents` | `mixture_of_agents_tool.py` | 入口 + 层间 |
| `yb_*` (×5) | `yuanbao_tools.py` | 每个 handler 入口 |
| `browser_cdp` | `browser_cdp_tool.py` | WebSocket 调用前 |
| `computer_use` | `computer_use/tool.py` | 入口 |
| `cronjob` | `cronjob_tools.py` | 入口 |

## 相关资源

- [Hermes Agent 文档 - 中断系统](https://hermes-agent.nousresearch.com/docs)
- `tools/interrupt.py` — 中断系统的核心实现
- `tools/registry.py` — 工具注册表，`tool_error` 和 `tool_result` 辅助函数
- `agent/tool_executor.py` — 工具执行器，并发执行和中断传播

## 许可证

MIT
