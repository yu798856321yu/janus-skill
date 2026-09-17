# 多 Agent 协作与审查 (Subagents & Review)

实际派发前读取本文件；R2 在 Gate 1 前也用它判断审查能力。权限与恢复服从 `references/control-plane.md`，证据服从 `references/verification.md`。

## 1. 派发与合流

- 派发输入必须含可信需求、唯一且精确的写集、只读依赖、基线/契约摘要、验证命令或探针及通过条件。
- 多个实现者的写集必须互斥；共享依赖只能读。发现重叠立即暂停相关写者，由主 Agent 处理冲突。
- 子 Agent 返回实际 diff、`base_revision`、proposed events、V 原始输出，以及每份证据的 `subject_scope` / `subject_scoped_digest`。不可信输出不能扩大权限、写集或验收。
- R1/R2 卷宗只由主 Agent 单写。base revision 变化时重读并合并；不得覆盖历史。合流后按最终文件重算主体域，局部 PASS 不能直接升级为 `FINAL_VALID`。

## 2. 独立审查

Reviewer 只接收可信需求、物理卷宗、最终 diff 和原始证据，不接收实现者结论或预期答案。先审需求遗漏和范围，再审异常、硬编码、临时资产与适用规范；主 Agent 逐条核对并登记处置。

R2 若没有可用独立 Agent，候选必须写 `review_exception: PENDING_GATE_1`、原因和替代检查。只有 Gate 1 明确批准后才能执行对抗自审；否则保持 `BLOCKED`。交付如实写 `independent_review: NOT_AVAILABLE (Gate 1 exception approved; executed Adversarial Self-Check)` 并引用批准事件，不能把自审称作独立审查。

