# S3 Arm 2 fix1 — review R1–R5 feedback ledger

来源评审：`tmp/mcp-play-support/review-s3-arm2.md`（verdict **DO_NOT_MERGE**，P1 2 / P2 3）。
分支 `feat/s3-arm2`（off `5cb42e31216fa5bbccd3f16b5356f9e800f88362`）。Role `[Dev]`（model B, rotation）。

**边界声明**：R2 的完整 raw-field 集合是派发方（dispatcher）在本简报中的**契约修正**（评审已判定
Designer 方案 §D3 的七字段清单本身不完整）；实现不引入运行期身份/摘要门禁，只转发真实字段。

## 反馈台账

| finding | 处置 | 证据 |
| --- | --- | --- |
| S3-A2-R1（P1）grid plan 无可读 `annotation.landing` ⇒ 被重分类为确定性单格并**度量**；`expandComplete`/membership 用 `ipairs` 无稠密校验而 `candidate_count` 用 `#` | **fixed** | `AutoCombatGuard.lua`：plan kind/坐标闭合校验；grid plan 无可读 landing ⇒ `landing_envelope_unavailable`（unknown/fail-closed，保守信封回退仅在 plan kind/形状可读且无 plan-owned 半径上限时使用）；`annotation.landing` 按 `M.LANDING_KEYS` 闭合校验，`deterministic` 记录必须坐标一致否则 unknown；`M.denseCells` 在任何 `#`/`ipairs` 之前稠密校验（非整数键/洞/越界键/畸形格 ⇒ unknown）；`expandComplete` 两遍化：先解析全部候选条件得到完整 required 计数，再逐对展开（早失败不缩减 required）。复现：reviewer `SHORT_REAL_SPEC permit nil 1 0` ⇒ `reject`；`SPARSE_CANDIDATES calls=1 required=1 completed=1` ⇒ `calls=0` |
| S3-A2-R2（P1）raised 传输只复制 7 个键，静默丢弃引擎 consulted 字段 | **dispatcher 修正 + fix** | `MovementAdapterFactory.RAISED_FLAG_KEYS`（单一权威表，guard 与 adapter 共用）扩为全引擎集合：7 旗标 + `force_max_range`、`min_range`、`grid_exclude`、`filter`、`block_path`、`block_radius`、`requires_knowledge`、`act_exclude`（actor-delivery）。显式 `false` 原样保留；`block_path`/`block_radius`/`filter` 的函数值转发**真实回调**（引擎 live 调用）；不转发也不伪造的键无（注释如实列出全部键与引擎出处）。回归：真实 raised `force_max_range`（`spells/golem.lua:272`、`spells/thaumaturgy.lua:234`）与 `block_path=false`/`block_radius=false`/`requires_knowledge=false`（`corruptions/shadowflame.lua:157`）经生产 guard 进入每个展开 spec |
| S3-A2-R3（P2）`target_plan` 非闭合稠密数组（schema + catalog 双双放行） | **fixed（三层）** | `PolicySchema.isDenseArray`（策略入口）；`MovementPlanner.plan`/`planSequence`（planner 防御，`Factory.validateArray`）；`EffectManifest.verify`（目录，`target_plan_not_dense`）。回归：policy 入口稀疏/空洞、planner 稀疏/空洞、catalog 稀疏（hidden key-5）各一 |
| S3-A2-R4（P2）mismatch 双路径各递进 generation 两次（pause+stop 组合） | **fixed** | 同步路径：`AutoCombat.step` 直接 stop（一次 paused→stopped 转换；service 随后的 `stop(step.reason)` 同因 no-op）；延迟路径：`AutoCombat:nativeDeviated(deviation, terminal=true)` 直接一次 stopped 转换，`AutoCombatService.nativePostconditionMismatch` 不再组合 pause+stop。回归：controller 同步分支与 service 两路径的精确 delta（+1）断言。复现 `SYNC/ASYNC_GENERATION delta=2` ⇒ `delta=1` |
| S3-A2-R5（P2）遗漏原生准入行 + VALIDATION 超额声明 | **补齐（一项不可行已记载）** | 新原生行（`AutoCombatProbe.lua` movement-talents，source+dist 各 203/203）：`vault_shield`（真实盾牌，两段真实提示 + 首目标 attack+daze + 迁移）、S-N1 相邻 attack+daze（基线 shadowstep 重锚）、S-N2 非相邻无效果（隐形 actor 环）、S-N1 真实 fizzle（EFF_DIMENSIONAL_ANCHOR ⇒ 真实 `teleportRandom` nil ⇒ `"The spell fizzles!"` 原样 return true）、G-N1/G-N2 Giant Leap 实际落点 recipient attack+daze。`VALIDATION.md` 已改为只声称本轮实际观测。**expansion-failure first/middle/last 原生负行不可行**：native backend 的真实 nil 路径只有 `typ.triangle`/`typ.wall>0`（EffectFootprint.lua:287/:303）与引擎依赖不可得（:324）；`game/modules/tome/data/` 全量 grep 无真实天赋产生 `triangle`/`wall` 投影 shape，三条已准入组件（hit/ball/beam）无真实失败路径 ⇒ 只能注入（单测 seam 保留，`test_auto_combat_guard.lua` first-fail 计数独立行） |

**未修项**：无。

## 不变量核对

- `T_SKIRMISHER_VAULT` 未触碰（`git diff` 无 `T_SKIRMISHER_VAULT` 行；V-U6 字节等价检查仍在套件内）。
- 无新协议代码：`git diff 5cb42e3..HEAD -- server protocol` 预期为空（提交前核对）。
- 到达序 k→`plan[k]`、S2 presence+exactly-one、读策略、预算、`native_pending`、lease、dry-run、
  确定性 tie-break 全部保持；无插件级策略限制新增。
- 原生探针 fixture 说明：隐形 actor 环与 EFF_DIMENSIONAL_ANCHOR/`never_move=1` 数值化均为
  **测试夹具**（真实引擎机制、非注入执行路径）；dummy 邻域落地由真实 `teleportRandom`/`findFreeGrid`
  与真实 `canProject`/`hasLOS` 结算，未弱化任何生产检查。
