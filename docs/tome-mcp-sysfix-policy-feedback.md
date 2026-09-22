# SYSFIX-20260922 策略预算与调度修复

状态：Dev 实现/回归证据，**ready for review；尚未独立验收**。基线 `366b32b4b53f28c3ef6575290f5b290d358ebfb8`；绑定 `POLICY-01@1.1 / POLICY-02@1 / POLICY-03@1 / SETTLEMENT-01@1`。本批由独立 Dev `/root/fix_policy` 单写 `auto_combat` 及对应测试，Runtime 最终结算桥接由 `/root/fix_core` 单写；协调者 `/root` 负责集成、打包、source/dist 原生运行与全新 Review。

## SYS-01 / SYS-03：统一有效动作、提交与 run 计数

`AutoCombat.submit` 记录每次实际 host.request；同步结果统一在 `countOutcome` 计数，pending 只保留关联，不提前计有效动作。Runtime 的真实最终结果通过 `AutoCombatService.nativeSettled` 回传，使用稳定 run_id/submission_id/原提交 generation 匹配；重复、旧 run 迟到结果不重计。暂停/恢复调度不会遗忘已提交的原生调用。

| 计数 | 范围 | 消费条件 | 上限 |
| --- | --- | --- | --- |
| native_submissions | 真实 action opportunity | 每次 host.request，包括拒绝、错误和首次 pending；guard/planner 不计 | 内部 32 |
| effective_actions，兼容 attempts | 真实 action opportunity | settled status=ok 或 energy_spent=true；合计一次 | max_actions_per_tick，缺省 1 |
| instant_actions | 真实 action opportunity | 有效动作且 instant=true | max_instant_per_tick，缺省 3 |
| run_actions，兼容 actions | 一次 start run | 与有效动作相同，普通/sustain/移动/原生活动共用 | max_consecutive_actions，缺省 200 |

前三种计数只在 host 的真实 opportunity identity 变化时重置，显示帧、重复 pump、快照、pause/resume、显式 stop/start 均不能刷新。Service 保留内存中的前次 opportunity controller，即使 manualInput/deactivate 移除活动 controller，预算与未完成调用仍可结算。新 start 重置 run_id/run_actions，旧 pending 未收束时拒绝新 start。

`native_submission_limit` / `max_consecutive_actions` 到顶即停止后续提交；pending 先跟踪至终态。最终 stop 释放 lease，generation 增加一次。若同次结算出现 sequence/postcondition deviation，已知有效动作仍计数，但由更精确的 deviation handoff 一次终止，不叠加 cap stop。保留每步 8 次 rule-loop 界及 limit-1 无耗能拒绝后仍可执行一个有效动作的历史修复。

## SYS-02：显式 emergency fallback 与可见迁移

新增 `mode.on_emergency_unavailable=release_control|evaluate_rules`，缺省 release_control。`emergency_only` 首次及重评估均只选 emergency；只有显式 evaluate_rules 且已有 settled 原生拒绝，才允许普通 fallback。guard/planner 拒绝、unknown、pending 不扩大集合。release_control 下 `action_denied` 直接 stop/release；无 emergency 匹配时保留既有精确 no_emergency/flee handoff。

内置 pilot presets 显式声明历史 evaluate_rules 选择；strict 设计示例显式声明 release_control。该模式不禁止移动、撤退、传送、换层、rest 或 auto_explore。

旧缺字段的 emergency 策略通过 schema/validate/import/set_draft 时显示 `emergency_fallback_migration`；无阈值且未显式使用 emergency_only，以及明确 on_low_hp=evaluate_rules/pause 的策略不作迁移。导入先验证原 envelope hash，再规范化显式字段并返回 original_hash/new hash，不能以迁移掩盖篡改。

加载旧 approved 时移为规范化 draft，清除该旧 approval/running，必须重新 approve/activate。原 approved 和被替换的另一份 draft 保留在迁移记录；`get/status.migration` 可审阅。save format 3 仅增加策略迁移数据，不保存运行计数、关联 id、socket/token/lease。历史 format 2 的合法策略仍可加载。

## 验证层与待完成门禁

新增 `tests/test_auto_combat_sysfix.lua` 经过 Schema→Service→Store/Arbiter→Controller 生产边界，host outcomes 为明确的离线 doubles：覆盖 cap=1/default200、普通/sustain/移动/活动、有效与提交双计数、pause/resume/stop/start、32 次跨 pump 拒绝/错误、pending 第 32 次、重复/迟到结算、manual detach、sync/async deviation 精确 generation、只读 dry_run、日志字段、旧策略批准迁移/保留/重载。原有 controller/service/evaluator/hash 测试同步显式 fallback 新语义；旧 hash 投影另留断言，生成的显式模式策略 hash 变化属于可见数据变化。

原生代码提供 `tests/native/auto_combat_run.py --policy-only`，通过生产 Runtime host/Actions/NativeActivity 执行 wait cap、真实 Healing Light 冷却拒绝的两种模式、同机会真实 32 次拒绝/重启、真实 Chant 瞬发 sustain、真实 rest pending 自然推进至终态。请求记录包装器只旁观真实返回，不伪造 outcome。旧 aggregate 中原 synthetic native_pending 场景撤出，不能继续作为原生结算证明。

**本 Dev 未打包、未启动游戏；source/dist native 均 NOT_OBSERVED。** 新 probe 仅做 Lua 语法编译，尚需协调者在固定候选源与固定 `.teaa` 上执行并处理实测反馈；编译和模块测试不等于原生 PASS。最终集成还需 core 的 Runtime/activity 桥接、tooling 的 tests/run 接线/边界检查、API 文档，以及独立 Test/Review。

原始命令/日志/hash 索引：`/workspace/t-engine4/tmp/mcp-system-fixes-20260922/policy/`；不将临时大文件提交到仓库。最终精确测试结果和 commit/PR 位于该目录 report.md。

## U-01：max_candidates 已复现、未实现消费

当前 `rg max_candidates overload server docs/tome-mcp-auto-combat-plugin-design.md` 的产品命中只有 `PolicySchema.HARD` 与 limits 允许列表，没有运行消费：

- `PolicySnapshot.select`（27–60）排序并遍历全量可见 hostile；`build`（97–114）用全量集合计数/绑定。
- `MovementPlanner`（319–368）按实时 range ∩ SCAN_RADIUS 枚举格点，未使用 policy.max_candidates。
- `AutoCombatGuard.expandComplete`（973–1051）以及组件调用（1185–1240）要求完整 candidate×component union；任一失败丢弃部分 union。
- 有界生产反例 `u01.lua`：schema-valid max_candidates=1，输入两个 hostiles，最低 HP 在第二个，实际输出 `enemy_count=2 selected=second`，见 `u01.log`。

协调者裁决：本批保留为独立未修项，不增加候选截断/运行门禁，不把 Phase Door 包络硬绑到 32。后续应分拆 selector 工作集合与完整 footprint 展开的计量对象和超界语义；不能把较小的部分 union 当完整风险集合。Owner=/root，触发条件=独立候选上限语义决策后另派 Dev。状态 **复现 PASS；消费修复未实现；native NOT_OBSERVED**，不得标 fixed。
