# R1 常规档 (Mode Standard)

R1 用一个可恢复的 `docs/contract-<topic>.md` 卷宗承载单一子系统内的常规改动。只在业务结果分叉时请示；其他选择沿已冻结契约推进。

## P1-P3：基线与初始契约

记录控制面的 I/D/C/R 事实、渐进基线、`preexisting_changes`、精确 `source_targets` 和唯一卷宗路径。风险达到 `risk_r2_min`、命中高危或关键事实未知时转 R2。

没有待决业务选择后，以 schema 2.2 创建卷宗。头部与两个 Initial Snapshot 是不可变初始快照；运行变化只在同一 Event Log 追加：

```yaml
---
janus_dossier_schema: "2.2"
topic: "<topic>"
mode: "R1"
run_id: "<run-id>"
resume_supported: true
phase: "P3_CONTRACT_FROZEN"
workspace_identity: "sha256:<canonical root + VCS identity>"
baseline_uri: "<persistent path or embedded section>"
baseline_digest: "sha256:<scoped baseline>"
source_targets: ["<relative-path>"]
interface_applicability: "IN_SCOPE"
interface_contract_status: "FROZEN"
behavior_contract_status: "FROZEN"
contract_assertion_digest: "sha256:<initial contract+acceptance digest>"
---

```

## Initial Contract Snapshot
```json
{"contract_text":"<完整初始契约字符串，JSON 转义>"}
```

## Initial Acceptance Snapshot
```json
{"acceptance_text":"<完整初始验收字符串，JSON 转义>"}
```

## Event Log (append-only)
```yaml
- revision: 1
  event_id: "evt-r1-0001"
  type: RUN_STARTED
  base_revision: 0
  actual_write_set: []
  issue_events: []
```

两个初始值只取各 JSON 字段解码后的完整字符串，不靠标题或 Markdown 边界猜测；保存精确 JSON 载荷字节及摘要。无跨接缝时 `interface_applicability: NOT_APPLICABLE`、`interface_contract_status: NOT_APPLICABLE` 并说明理由；所有任务都须冻结行为验收。只有卷宗已落盘、当前契约合法有效、业务选择清空和写集冻结后才解锁源码。

## 契约修订模型

当前契约由连续 Event Log 重放：无修订时取两个 Initial Snapshot；有修订时取最后一个合法 `CONTRACT_ACTIVATED`。头部摘要只记录初始快照，不随追加事件改写。

1. `CONTRACT_PROPOSED` 保存一个 JSON 对象：`contract_text`、`acceptance_text` 两个完整字符串，精确 `source_targets`、原因和授权依据。字符串按 JSON 转义，不按 Markdown 标题解析。保存候选的精确 UTF-8 JSON 载荷字节、物理位置和载荷 SHA-256；排版变化就是新候选。新路径须先记录增量基线。
2. `CONTRACT_ACTIVATED` 绑定候选 event ID、完整候选载荷摘要、`contract_assertion_digest`、当时唯一有效父激活 event ID、冻结依据和 `decision_ref`。初始版本以 `RUN_STARTED` 为父锚点。改变写集、行为/验收或受限副作用时，decision_ref 必须明确覆盖增量；充分的既有授权可复用。候选不自动生效，父版本竞争、业务未决或授权不足均不生效。
3. 沿用 `revision` / `base_revision`，不新增执行状态。每个事件 revision 连续；卷宗由主 Agent 单写。
4. 当前有效 `source_targets` 来自选中契约。`actual_write_set` 只追加并保留已撤销项状态。缩写集激活前，移出路径的任务改动须按回滚守卫撤销，或被新契约明确列为保留改动并纳入验收；处置未定不得激活。保留但关闭写入的文件要返修时先重新纳入有效写集。所有未撤销改动都须被最终验收或明确例外覆盖。
5. 当前契约摘要变化使旧断言绑定证据 `STALE`；普通源码/WAL 日志增长不改变摘要。旧事件保留追溯，不能重标有效。

摘要算法只覆盖所选 `contract_text` 和 `acceptance_text`。分别将 CRLF/CR 转 LF，保留其余空白和末尾 LF，以严格 UTF-8 无 BOM 得 C、A。输入为：

```text
UTF8("janus-contract-v1\n")
+ ASCII(decimal-byte-length(C)) + ASCII(":") + C
+ ASCII(decimal-byte-length(A)) + ASCII(":") + A
```

长度是无前导零的非负十进制；禁止附加分隔符或尾换行。`contract_assertion_digest` 与验证 `assertion_digest` 使用该 SHA-256。标题、冒号和代码围栏若在字符串内即属于摘要；事件排版和摘要字段自身不属于摘要。

实算向量：C 为 `"返回 201\r\n## Event Log\r\n"`，A 为 `"字段 id 非空\r\n\r\n"` 时，CRLF/LF 均为 `d7bb1264e97e09ebffafb559ed18ed6fd39f22368faed49d82236762ae4c1270`；A 少一个末尾换行时为 `bd59d8071f9e05b9947a33bbbe04ac738b54072b3c9ecdce09fe64db64b5b66f`。

## schema 2.1 迁移

旧 2.1 只按旧规则读取。首次修订前暂停全部写者，确认单写者并核对旧文件摘要、revision 和初始契约位置；保留旧头部原文、文件摘要、末 revision 和历史事件。在同一次完整文件替换中明确写入 2.2 头部、迁移事件及两个初始字符串快照。发布前再次核对原文件身份，发布后验证新文件。

不能可靠替换或发现不一致时保全现场并进入 `RECOVERY_UNCERTAIN`。旧执行者必须重读版本并拒绝不支持的 schema；L0 无法约束缓存或无视指令的外部写者，所以迁移前单写者确认不可省略。这是提示词协议迁移，不声称存在任务解析器。

## P4-P6：实施与交付

按最小垂直切片实施，WAL、issue、恢复与升档只按控制面追加；升级 R2 时先记录触发事实和完整 `actual_write_set`，冻结源码后迁移索引。

按 `references/verification.md` 实测并完成 Drift Detection、Final Sweep 和对抗自审。R1 无 Gate 5；全部必验项满足时 `FULL_DELIVERY`，只有用户明确接受相同例外摘要时才可部分交付，否则保持阻断。使用完整交付模板。
