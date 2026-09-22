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
