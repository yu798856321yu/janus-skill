# 验证协议单一事实源 (Verification Protocol SSOT)

本文档是 Janus 的验收、证据、有效性和交付裁决唯一事实源。其他文档只引用这些模型。

## 1. 三表与绑定

### 1.1 Acceptance Ledger

先从当前有效契约、需求和用户决定列全验收项；不得用空表、删除失败项或改成不适用制造绿灯。

| 验收项 ID | 断言 | 来源 | 预期标准 | 适用性 |
|---|---|---|---|---|
| A1 | 正常提交符合契约 | 当前有效契约 | HTTP 201 且 JSON 含 id | Mandatory |
| A2 | 删除不存在项幂等 | 当前有效契约 | HTTP 204、无异常栈 | Mandatory |
| A3 | 缺测试配置时可诊断 | 架构约束 | 明确提示且无未捕获异常 | Conditional |

R1 的当前契约按 `references/mode-standard.md` 重放选择：没有合法激活修订时取 Initial Snapshots；否则取最新合法 `CONTRACT_ACTIVATED` 的两个完整字符串。`assertion_digest` 与其 `contract_assertion_digest` 使用相同算法。R2 使用 Gate 3 当前有效契约与验收候选。契约摘要变化使旧断言绑定证据 `STALE`。

### 1.2 Subject-Scoped Digest

`subject_scope` 完整列出决定被验行为的源码、配置、可执行契约和测试文件；使用工作区相对路径、`/`、去重后 Ordinal 排序。每项记录 SHA-256，不存在时用 `<missing>`。按项拼接：

```text
UTF8(path) + NUL + UTF8(lowercase_sha256_or_<missing>) + LF
```

整体 SHA-256 为 `subject_scoped_digest`。可变 state、issue、审批和证据日志不进入主体域；断言单独绑定 assertion digest。若 OpenAPI 等契约参与运行，它也作为普通文件进入主体域。

主体域内变化使对应证据 STALE；域外已归因变化不自动误杀证据，未归因漂移仍独立阻断。Final Sweep 发现实际写集、契约或测试依赖未被覆盖时，补齐范围并重跑受影响验证。

### 1.3 Freshness Binding

每个 V 记录：

- `environment_fingerprint`：OS/架构、工具链/运行时版本、规范化工作根、测试配置/过滤器、锁文件和夹具摘要；不含时间、PID 或随机临时目录。
- `pre_verify_subject_digest` 与命令退出后立即采集的 `post_verify_subject_digest`；二者须相等并等于声明主体摘要。
- `tested_build_identity`：编译产物哈希；服务另记命中进程、启动命令和所加载产物；解释型入口记入口文件、锁摘要和命令。不能证明请求命中当前候选时不得 PASS。

Secret 只保留脱敏后的最小证据。同一稳定批次可复用完整主体清单和 V ID，但开始/结束仍采样；mtime 或“刚测过”不能证明稳定。

### 1.4 Evidence Ledger 与 Trace Matrix

| V ID | run/时间 | cwd、argv/操作、退出码 | 原始输出摘要 | subject/assertion digest | freshness binding |
|---|---|---|---|---|---|
| V1 | run-x / time | repo / command / 0 | HTTP 201 与字段 | sha256:... / sha256:... | pre=post；env/build=sha256:... |

| A ID | V ID | 判定理由 | Outcome | Validity |
|---|---|---|---|---|
| A1 | V1 | 状态与字段均匹配 | PASS | FINAL_VALID |
| A2 | V2 | 边界实测满足 | PASS | FINAL_VALID |

最终报告引用 V ID 复用命令、输出和绑定，不重复复制同一证据正文。

## 2. 状态与交付裁决

Outcome 恰为六种：

1. `PASS`：新鲜物理证据满足断言。
2. `FAIL`：已执行且结果不满足。
3. `PARTIAL_UNVERIFIED`：已针对性排查，但缺生产条件或偶发时序，无法稳定复现；记录尝试和影响。
4. `BLOCKED`：外部前置条件阻止执行。
5. `NOT_RUN`：尚未到达。
6. `NOT_APPLICABLE`：有可审计理由证明不涉及。

Validity 为 `VALID`（当前绑定仍匹配，未完成终态协调）、`FINAL_VALID`（最终组合代码满足断言、稳定绑定和能力相称回归）、`STALE`（主体/断言/依赖/环境不再可比）或 `SUPERSEDED`（被新 V 替代）。

交付必须声明：

- `traceability_complete`：每个 A 均有有效 V，或有真实未验证原因和影响。
- `verification_satisfied`：所有 Mandatory 且适用项均满足控制面 `final_required_outcome` 与 `final_required_validity`。
- `delivery_disposition`：`FULL_DELIVERY | PARTIAL_DELIVERY_WITH_EXCEPTIONS | BLOCKED`。

| traceability_complete | verification_satisfied | 例外 | disposition |
|---|---|---|---|
| true | true | 无需 | FULL_DELIVERY |
| true | false | 用户明确接受同一缺口摘要；R2 Gate 5 批准同一摘要 | PARTIAL_DELIVERY_WITH_EXCEPTIONS |
| false | 任意 | 任意 | BLOCKED |
| true | false | 无、含糊或摘要已变 | BLOCKED |

`ACCEPT_PARTIAL_EXCEPTION` 只解除列明验收缺口的交付阻断。它不把 issue 标成 RESOLVED，不清失败历史，也不授权继续修复。权限、现场归属、恢复、未知漂移和上游 Gate 血缘阻断不是验收例外；FAIL、NOT_RUN 等原因必须如实保留。

## 3. 直接证据

断言由当前契约驱动，可合法要求 200/201/204/4xx、空列表或结构化错误；不得放宽断言来通过测试。Bug 修复优先保存修改前红灯和修改后绿灯；不能复现时按 methods 记录 `PARTIAL_UNVERIFIED`。

前端验证记录真实页面操作、Console 中本次引入错误和 Network 响应；有能力时保存本地高清截图。证据持久化前遮盖 Authorization、Cookie、连接串、令牌和个人数据。

## 4. Final Sweep

Final Sweep 位于 P5 末尾、P6 前；R2 中先于 Gate 5 Freeze。

1. **漂移准入**：按控制面 Drift Detection 归因 Delta。`UNATTRIBUTED_DRIFT`、不完整基线或写集冲突时停止。
2. **覆盖协调**：用当前有效契约、最终 `source_targets`、完整历史 `actual_write_set`、保留改动和测试依赖核对每个 A/V。缩写集不能隐藏未撤销改动；所有未撤销改动须被验收或明确例外覆盖。
3. **失效重验**：对 STALE、新增或依赖变化项运行最直接验证，追加新 V，将旧 V 标 SUPERSEDED。
4. **能力相称回归**：Tier A 跑影响域相关自动化；Tier B 跑冻结接口/CLI/脚本探针；Tier C 跑已有构建、特征、差分与可用界面/网络/日志。不存在的入口记录为能力事实，不可观察的必验行为仍阻断或形成例外。
5. **终态刷新**：核对验证前后主体、当前断言、稳定环境和被测构建，再把满足项刷新为 FINAL_VALID，聚合 Evidence Set。
6. **改后回退**：Final Sweep 后主体变化使相关 V STALE 并退回 P5；R2 同时 INVALIDATED Gate 5。

最后一次验证若已覆盖全部适用必验项和能力回归，且最终主体、断言、环境与构建完全匹配，可引用原 V ID 刷新为 FINAL_VALID，无需重复同一命令；记录复用依据。重新申请 Gate 5 本身不使仍有效证据失效。

## 5. 交付模板

### R1/R2

```markdown
## 结果
<实现与 delivery_disposition>

## 任务卷宗与状态
<路径、phase、Gate/执行状态>

## 关键文件
| 文件 | 变更 | 写集归属 |
|---|---|---|

## 当前契约
<选择的版本/激活事件、契约变化或不适用理由、assertion_digest>

## 验收、证据与追踪
<三表；traceability_complete>

## Final Sweep 与漂移
<能力、复用 V ID/补跑、退出码、freshness、evidence_set_fingerprint；verification_satisfied>

## 未验证项与例外
<真实状态、原因、影响、例外摘要及接受/批准引用；无则写无>

## 现场与问题
<preexisting_changes、actual_write_set、漂移、issue lifetime/状态、pending/recovery；无故障则写未触发>

## Ponytail、风险与交接
<债务原因/ceiling/upgrade、残余风险；生产操作如适用明确未执行>
```

### R0

```markdown
## 结果
<结果与 delivery_disposition>
<traceability_complete；verification_satisfied>

## 关键文件
| 文件 | 变更 |
|---|---|

## 验证矩阵
| 对象 | Tier 与命令/操作 | V ID、直接证据/退出码/freshness | 结论 |
|---|---|---|---|

## 未验证项与现场
<原因、影响、接受引用；契约、现场、issue、Ponytail 有异常则逐项列出，否则写无>
```

