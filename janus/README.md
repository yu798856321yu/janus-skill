# Janus 自适应全栈研发工作流

Janus 是专为存量复杂工程、跨端全栈协同与可审计交付设计的自适应研发流程技能。它依据任务的实际风险自动定档，规范从意图分析、契约落盘、最小改动到真实物理验证的全流程。

## 核心特点

1. **风险驱动与自适应定档**：基于接口影响（I）、数据影响（D）、契约影响（C）和回滚难度（R）四轴事实评分，在 Spike（快速探针）、R0（快速单测验证）、R1（标准紧凑卷宗）和 R2（严格门禁与事件溯源）之间动态选档，只升不降。
2. **证据闭环拒绝假绿**：所有测试与验收结果必须绑定最终源码哈希、真实运行环境与被测产物，杜绝无断言绿灯和事后粉饰。
3. **显式控制面与安全防线**：写操作前锁定目标写集（Action Manifest），禁止越界修改；提供明确的未归因漂移拦截、熔断保护与现场保全机制。
4. **低上下文消耗**：采用严格渐进披露加载机制，仅在定档和触发对应环节时按需加载规则，保证执行效率。

## 快速使用

### 1. 触发技能
技能配置了显式触发策略（`allow_implicit_invocation: false`）。在对话中通过 `$janus` 明确调用，例如：
- `$janus 帮我排查设备运行记录报表加载超时的问题`
- `$janus 重构工单同步接口，并确保前后端字段兼容`

### 2. 执行节奏与交互
- **意图与工程扫描**：Agent 首先分析改动范围并探测项目的真实构建/测试入口。
- **定档卡展示**：在首次动笔修改前，Agent 会明确输出结构化定档卡，说明匹配档位（R0/R1/R2）、各轴事实证据及后续确认要求。
- **分步实施与直接验证**：依据选定模式推进改动，并以当次真实运行的测试、探针或构建输出作为交付依据。

## 项目配置说明 (可选)

如需为特定项目声明专属构建命令、测试探针或禁止改动的敏感目录：
1. 将技能包中的 `references/profile-tech-stack.md` 复制为目标项目根目录下的 `docs/tech-stack.md`。
2. 按表填入具体技术事实与命令，不涉及的填 `NONE`；保留原有的 `AGENTS.md`。
3. 项目本地配置无需重新安装技能，下次对话读取时立即生效。

## 目录结构

- `SKILL.md`：主入口、执行路由与共同研发约束。
- `references/control-plane.md`：权限、路径、风险、故障状态机与恢复唯一事实源。
- `references/discovery.md`：事实扫描、能力判断与定档卡唯一规范。
- `references/verification.md`：验证表、物理证据绑定与交付模板规范。
- `references/mode-fast.md` / `mode-standard.md` / `mode-strict.md`：R0/R1/R2 档位工作细则。
- `references/profile-tech-stack.md`：项目技术栈配置参考模板。
- `references/methods.md` / `subagents.md`：复杂排查方法与子代理调度规则。
- `scripts/validate-fullstack-skills.ps1`：发行校验与全量自测套件。

## 维护与发行校验

维护者修改技能文档或脚本后，需在 Windows 本机 NTFS 环境下的 PowerShell 5.1 或 PowerShell 7 中运行校验套件：

```powershell
# 1. 源码模式静态校验
& .\scripts\validate-fullstack-skills.ps1 -Mode Source

# 2. 运行内置全量自测试 (全量安全检查与故障注入断言)
& .\scripts\validate-fullstack-skills.ps1 -SelfTest

# 3. 发行模式完整闭包校验 (对比 manifest 哈希)
& .\scripts\validate-fullstack-skills.ps1 -Mode Release

# 4. 自动刷新发行清单哈希 (显式维护命令)
& .\scripts\validate-fullstack-skills.ps1 -RefreshManifest
```

> 说明：文档与配置文件使用无 BOM 的严格 UTF-8 编码；包含中文字符的 PowerShell 脚本需保留 UTF-8 BOM 以兼容 Windows PowerShell 5.1。
