# R2 严格档 (Mode Strict)

R2 用物理卷宗、追加式事件和五道人工 Gate 处理跨团队、高风险或难以可靠回滚的任务。Agent 不代替用户批准。

## 1. 卷宗与引导

缺省目录为 `docs/fullstack/<topic>/`，索引固定为 `state.md`。产物依次包括需求、子 PRD/架构及其审查、详设/契约及审查、实施计划、代码审查和验证报告。

Gate 1 前完成只读 Baseline Manifest、评分、精确产物目标和独立审查能力探测。若能力不可用，在需求候选写明原因、替代检查和 `review_exception: PENDING_GATE_1`。只开放 state 与需求候选，分别标 `PENDING_GATE_1`、`DRAFT_UNAPPROVED`；源码仍锁定。候选必须先落盘并登记物理摘要，不能批准会话草稿，也不能把 state 自身放入其摘要。

最小索引模型：

```yaml
# Janus R2 Dossier Index
schema_version: "4.0.0"
topic: <name>
run_id: <run-id>
mode: R2
resume_supported: true
revision: 2
workspace_identity: "sha256:..."
baseline_uri: "<path>"
baseline_digest: "sha256:..."
phase: P1_DISCOVERY | P2_TRIAGE | P3_DESIGN | P4_IMPLEMENT | P5_VERIFY | P6_DELIVERY
deployment_status: NOT_REQUESTED | BLOCKED_IN_L0 | MANUAL_HANDOFF_PREPARED
execution_status: ACTIVE | UPGRADE_PENDING_R2 | RECOVERY_UNCERTAIN | BLOCKED | COMPLETED | ABORTED
source_targets: []
actual_write_set: []
review_capability: AVAILABLE | NOT_AVAILABLE
review_exception: NONE | PENDING_GATE_1 | APPROVED_AT_GATE_1
issue_registry: {}
pending_attempt: null
artifacts:
  requirements:
    path: docs/fullstack/<topic>/00-requirements.md
    gate: 1
    record_status: APPROVED
    subject_scope: [docs/fullstack/<topic>/00-requirements.md]
    subject_scoped_digest: "sha256:..."
gate_approval_records:
  gate_1:
    events:
      - event_id: "evt-g1-01"
        type: REQUESTED
        base_revision: 0
        parent_event_ids: []
        subject_paths: [docs/fullstack/<topic>/00-requirements.md]
        subject_scoped_digest: "sha256:..."
      - event_id: "evt-g1-02"
        type: APPROVED
        base_revision: 1
        parent_event_ids: [evt-g1-01]
        subject_paths: [docs/fullstack/<topic>/00-requirements.md]
        subject_scoped_digest: "sha256:..."
        scope_fingerprint: "sha256:targets_hash"
        decision_ref: "msg-user-confirm-01"
    effective_status: VALID
    eligibility: ELIGIBLE
  gate_2:
    events: []
    effective_status: NOT_REACHED
    eligibility: ELIGIBLE
  gate_3:
    events: []
    effective_status: NOT_REACHED
    eligibility: BLOCKED_BY_UPSTREAM
  gate_4:
    events: []
    effective_status: NOT_REACHED
    eligibility: BLOCKED_BY_UPSTREAM
  gate_5:
    events: []
    effective_status: NOT_REACHED
    eligibility: BLOCKED_BY_UPSTREAM
```

`effective_status` 是由事件推导的缓存：`NOT_REACHED | PENDING | VALID | INVALIDATED | REJECTED`。主 Agent 单写 state，每次追加带连续 revision、当前 `base_revision` 与 `parent_event_ids`；其他 Agent 只交 proposed events。

## 2. Gate 血缘、拒绝与失效

Gate 1 无父门；Gate N 只有在 Gate N-1 当前有效批准且父事件匹配时可请求。`REQUESTED` 绑定上游批准和物理候选，`APPROVED` 绑定该请求。越级、父链竞争或仅凭 eligibility 缓存均不解锁。上游重新批准不会复活旧下游批准。

`REJECTED` 绑定被拒的 REQUESTED、decision_ref 和原因，历史保留。只有上游有效且有新事实或明确修订方向时才能准备新候选并再次申请。返工若影响某 Gate，先使该 Gate 与下游失效并回锁其所保护的写入，只修改已解锁候选。Gate 5 仅因实现问题被拒而 Gate 4 仍有效时，可在原名单内返修，再更新证据和申请。用户拒绝不计入代码失败熔断；无新事实时停止重复提审。

产物与审查映射固定：需求→Gate 1；子 PRD、架构及架构审查→Gate 2；详设及详设审查→Gate 3；实施计划→Gate 4；代码审查和验证→Gate 5。报告在请求前登记摘要和处置，确认缺陷进入 issue registry；普通讨论不制造 repair attempt。

范围、计划或契约变化退回最早受影响 Gate。Gate 5 冻结后的变化按控制面漂移规则处理。未归因变化始终阻断交付，不能用验收例外放行。

## 3. 五道确认门

### Gate 1：需求与边界

批准落盘需求路径、摘要及可选审查能力例外。例外未明确批准时保持 `BLOCKED`。批准后才开放后续精确产物目标。

### Gate 2：增量架构

候选包含能力拆分、数据流、深模块和只读依赖，并附独立架构审查。只有 Gate 1 已批准能力例外时才可改用对抗自审。

### Gate 3：详设与契约

候选包含适用的 HTTP/事件/函数/CLI/批处理/UI/行为契约、错误语义、边界和验证规划。只批准索引所指的磁盘主体。

### Gate 4：实施计划与不可变提审快照

计划候选保存无重叠 `source_targets`、步骤、回滚预案、`plan_write_set_digest` 和 `pre_gate4_write_snapshot`。快照是按 Ordinal 路径排序的不可变 JSON 条目，每项含路径、preimage、提审时 postimage、来源和 attempt ID；保存精确 UTF-8 载荷字节并计算摘要。

Gate 4 的 REQUESTED 与 APPROVED 都绑定快照摘要、候选物理位置、计划写集摘要和父事件。后续 `actual_write_set` / WAL 只追加，绝不改写该快照。原 R0/R1 已发生改动也在快照中按可信 pre/postimage 登记；新纳入路径必须先补增量基线。

批准后才解锁源码。白名单内且契约/计划不变的正常修改和 postimage 更新不会使 Gate 4 自我失效；范围、计划、契约变化或发现未批准路径时停写，退回相应 Gate。每次写前仍核对授权与现场，快照分离不豁免漂移。

### Gate 5：验收包与交付

1. 完成稳定测试证据、代码审查和缺陷处置。代码审查绑定源码、契约和已有 V ID；源码修改后重验并更新适用审查。
2. 冻结审查文件。审查报告不嵌入包含自身摘要的聚合指纹，也不审查外层自哈希包。
3. 执行 Drift Detection 和 Final Sweep；需求覆盖不能为空或删掉必验项。仅审查报告更新不自动使原测试证据 STALE，但必须重新聚合、重新批准。
4. 在 state 中保存六个指纹；state 不哈希自身，不新增第七指纹：

   - `scope_fingerprint`
   - `candidate_subject_scoped_digest`
   - `verification_matrix_digest`
   - `environment_fingerprint`
   - `evidence_set_fingerprint`（聚合终态 V 记录与冻结审查文件摘要）
   - `exception_digest`（完全交付为 none；部分交付绑定具体缺口与条件）

5. REQUESTED 绑定物理路径、六指纹和父事件；APPROVED 必须批准完全相同的对象。
6. P6 前按控制面复检。合法追加审批事件和索引缓存不使候选自失效。Gate 5 仍为 `VALID` 且交付决策允许时才进入 P6。

R2 可在请求 Gate 5 时携带待批准例外：此时只要求 Gate 1–4 有效及其他守卫满足；进入 P6 时，Gate 5 必须批准同一 `exception_digest`。权限、归属、恢复和上游血缘阻断不属于验收例外。

## 4. 出口

`FULL_DELIVERY` 要求所有适用必验项 `PASS/FINAL_VALID` 且无权限、现场、恢复或 Gate 阻断。`PARTIAL_DELIVERY_WITH_EXCEPTIONS` 只释放已批准验收缺口；不解决 issue，不清失败历史，也不允许继续修复。ABORT 和回滚服从控制面。交付使用 `references/verification.md` 的完整模板。

