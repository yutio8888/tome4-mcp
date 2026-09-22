# NATIVE-PENDING-01：已结算运行的终态丢失

状态：policy 分支 ready for review；修复后的 source/dist 原生验收待协调者执行。本文不把离线回归称为原生通过。

## 真实失败与原因

`sysfix-policy-source-02` 是整体 FAIL（8 PASS / 1 FAIL）。原始 `game.log:2474` 记录一次 rest 提交返回 `native_pending`、`energy_spent=true`；`:2475` 明确记录 `Rested for 2 turns (stop reason: max_turns).`；`:3079` 为 probe 的 `settlement_timeout`。世界回合继续推进，故不能把失败归因于没有推进原生休息，也不能靠延长等待时间修复。

集成基线 `f5d1626178c9171d90349772995ba48b48e01410` 的 `Runtime.onFrame` 先执行 `settleAutoActivity`，通过 `Service.nativeSettled` 对最终结果计数；到达 `max_consecutive_actions=1` 后 controller 停止并归还 lease。随后同帧的自动调度条件仍只检查 host factory 等条件，没有排除已停止的 controller。再次调用 `Service.step` 时，原有控制权检查把正常停止后的 manual owner 解释为 `control_lost`，改写原因并清空 `svc.controller`。

原 probe 等待 `svc.controller` 存在且 pending 已清除，因此把**结算后终态丢失**误报为结算超时。Service 层回归在未修实现上复现了 controller 变为 nil；core 组负责的实际 tick/display 调度回归覆盖同帧重复调度入口。

## 修改与边界

- `AutoCombatService.step` 对已停止的运行返回既有 `not_running`，发生在 lease 检查之前；保留 controller、最终原因、计数、generation 和日志。仍在执行的运行失去控制权时，沿既有 `control_lost` 清理路径处理。
- core 组独立修改 `Runtime.onFrame`，只调度存在且未停止的 controller；本提交不编辑 Runtime。
- 原生 probe 保留提交时的 controller 与真实休息句柄，状态丢失时立即报告 `terminal_state_lost`。超时与终态证据包含原/当前运行、pending、回合、phase、休息计数、能量和日志。成功条件仍要求一提交、精确一次有效计数、cap 停止、generation 只加一、归还 lease，并增加真实休息计数等于 2 且句柄不再活动的断言。

未修改原生 outcome、调度期限、策略默认值或游戏生命周期。执行默认 false、v4、原生执行入口和存档边界不变。

## 已执行证据

证据目录：`/workspace/t-engine4/tmp/mcp-system-fixes-20260922/policy/pending-native/`。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 新回归运行于未修 Service | FAIL，controller 被置 nil | `service-before.log` |
| 系统修复 Service/controller 回归 | PASS，620 checks | `service-after.log` |
| 既有 Service 回归（含 active control_lost） | PASS，192 checks | `service-suite.log` |
| 分支既有 Lua 全套 | PASS | `lua-suite.log` |
| 新 probe Lua 编译、git diff --check | PASS | 报告及 manifest |
| 修复后 source/dist 原生场景 | NOT_OBSERVED | 协调者下一阶段 |

离线 host outcome 是明确的 unit double；证明的是 Service 状态保留与计数不变量。真实引擎完成休息的证据来自上述失败场景，修复后完整结果必须由新 source/dist 会话补齐。原始失败不覆盖、不改标 PASS。

## EVIDENCE-REV-02：15 个必需字段的转发证据缺口

独立审核发现：在 `copyFootprintFlags` 正常转发循环末尾添加 `spec.no_restrict=nil`，原有 guard 192 checks 仍通过。真实产品 forwarder 没有这一丢弃缺陷；此项只补测试，不修改产品 Guard。

`tests/test_auto_combat_guard.lua` 新增独立按 AGENTS checklist B 声明的 15 字段表，不引用产品内部 allowlist。每字段分别通过实际 `copyFootprintFlags` 及 `footprintSpec` 调用检查精确值，覆盖显式 false、布尔 true、数值概率/最小距离、排除表和真实 callback。另检查所有字段同时转发、未注册字段不外泄、callback 身份和实际调用结果。原有 malformed callback 的 typed unknown/fail-closed 检查保留。

本次执行：正常 guard **426 checks PASS**、既有 Lua 全套 PASS。隔离副本中，同一 `no_restrict` 清空 mutation 对旧 192 checks 为 rc0，对新回归为 rc1；对全部 15 字段逐一追加 `spec.<field>=nil`，均在对应字段 roundtrip 断言失败（rc1）。证据见 `pending-native/guard-oracle/mutation-results.json` 及逐项原始日志。初次副本遗漏 `s3_real_specs.lua` 的搭建错误另存 `fixture-incomplete.log`，不作为产品失败或 mutation 成功证据。

该 oracle 证明列明的生产转发行为与 mutation 敏感性，不声称证明任意 Lua 程序语义。结构 checker 与其负例由 tooling Dev 独立负责；本 test-only 增量按简报不要求新原生会话。状态仍为 ready for review。

## RUNTIME-REV-03：双 legacy 文档的原始草稿丢失

format 2 同时包含需要迁移的 draft 和 approved 时，旧实现先迁移 draft，再迁移 approved；后一步重建 migration 记录，把已规范化的 draft 放入 `previous_draft`，覆盖先前的 `original_draft`。因此原始草稿缺失的字段被静默补上，不能完整恢复作者输入。

`PolicyStore` 现在在私有 vault 中把当前 draft 的迁移前 canonical snapshot 与迁移后的 draft 一起保存。每次 set/restore 更新该来源，clear 同时清除。迁移 approved 时，`previous_draft` 取当前草稿的原始 snapshot，`original_approved` 仍保存原始批准文档；不会借用可能属于旧草稿的描述性 migration 字段。此来源只在 vault 中使用，没有新增存档控制态或公共字段。

回归分别覆盖“draft 与 approved 都为 legacy”和“draft 已为当前格式”，比较含名称、规则、limits、safety、updated 元数据的**完整 canonical bytes**；经过首次 load 和两次实际 plain-data save/reload 后，两份原始文档仍精确相等。迁移后的 approved 仍只成为当前 draft，不能 activate，必须重新 approve。另覆盖覆盖草稿、清空草稿和返回数据隔离，防止错取陈旧来源。

本次执行：未修 Store 上新回归 FAIL（`migration-before.log`），修复后系统回归 **680 checks PASS**、policy bytes **209 PASS**、Service **192 PASS**。原始失败和结果均在同一 evidence root；原生 source/dist 由协调者后续执行，未在此标 PASS。状态为 ready for review。
