# ToME MCP 0.9.0 — anor-reg-01 修复第二轮（R-1 P1 limit-1 活锁 + R-2 P3 replay 窗口）

日期：2026-09-18。Branch `fix/emergency-deny-livelock`，off `2348556b2fb820f532b74397fba82cb636bad27d`。
Role `[Dev]`（model B, rotation）。merge=no。

来源评审：`tmp/mcp-play-support/review-anor-reg-01-fixes.md`（verdict **do_not_merge**，
P0 0 / **P1 1** / P2 0 / P3 1）。本文记录该轮两个 finding 的解决，并**显式声明解析后的契约**。

## R-1（P1，merge blocker）— 解析后的预算契约

### 问题

`max_actions_per_tick=1`（schema 合法，且 `import_assistant` 在源配置省略该设置时默认为 1）下，
emergency 动作被原生**settled reject**（如冷却拒绝，未花费能量、未产生原生动作）时：旧实现在提交前
就消耗了唯一的 attempt，下一次求值先命中 evaluator 的预算检查，返回 `paused budget_exhausted`；
`budget_exhausted` 不在 Option-A 交接集合里，auto lease 继续持有、世界停摆、冷却永不衰减，
`resume` 只会重演同一次被拒治疗 —— 同一活锁换了 reason。这也证伪了“无可执行动作时 typed reason
是 `action_denied`”。

### 三方张力的解析（显式契约，非策略限制）

评审指出的张力：*“同机会 fall-through” vs “每次原生提交消耗预算” vs max=1*。本轮按简报候选 (a)+(b)
解析为：

1. **`max_actions_per_tick` 计量“产生原生动作的提交”（charged）**：结算为 `ok`、或
   `energy_spent==true` 的提交消耗预算（`attempts`）；**未产生原生动作的 settled 拒绝**
   （`status='rejected'` 且 `energy_spent~=true`，含执行前 guard 拒绝——它根本未触达原生执行器）
   **不消耗预算**，因此同机会 fall-through 在 limit=1 下照常运行（评审复现场景：被拒 heal →
   同机会提交 fallback → 世界 tick → 冷却衰减 → 冷却恢复后 heal 再次可用）。
2. **预算耗尽 reason 诚实化**：`budget_exhausted` 现在只会表示“本机会已完成 max 次有效原生动作”
   （重复 opportunity id 的边界），**绝不**表示“原因是拒绝”。
3. **refusal 不再受预算约束，但受到等价且显式的界**：每条被拒规则在本机会被 `deny`（不重试）；
   movement retry 由排除落点集界定；规则循环硬上限 8 次迭代。因此每机会的原生调用次数有界，
   有效动作次数 ≤ `max_actions_per_tick`。
4. **settled reject 永不留下“持有 lease 的冻结暂停”**：
   - **refusal 终点**（emergency 层被拒且本机会确实无任何可用规则，evaluator `action_denied`
     `fallback=true`）：控制器**stop**（Option-A 同款完整性交接）并带 typed reason
     `action_denied`；service 释放 lease、run 停止。`resume` 拒绝（`not_running`），
     `start` 显式重新获取；玩家可立即行动让世界推进、冷却恢复。
   - **规则循环耗尽且本机会没有任何有效动作**（`attempts==0`，世界必然冻结）：控制器
     stop（reason `rule_loop_limit`）而非冻结暂停。若循环内已有有效动作（世界会自行推进），
     保留原有 pause 语义。
   - `SAFETY_PAUSES`（Option-A 集合）保持恰好 `{flee_below_hp_pct, no_emergency_action}` 不变；
     上述两个新交接由控制器以 `stopped` 结束、由 service 既有 `stopped` 分支释放 lease。
   - **有意保留（非本轮范围）**：`unknown_safety` / `action_uncertain` / `player_interaction`
     / 策略声明 pause 的暂停语义不变（不可判定/交互/策略作者选择，属 fail-closed 或非冻结路径）。

**非策略性**：以上只是插件完整性边界（时间无法推进 ⇒ 冷却无法恢复 ⇒ 插件无法正确执行），不是
任何策略性限制；是否撤退/传送/换层仍完全由策略声明决定。

**dry-run 镜像**：`dry_run` 不执行任何动作，预算永不消耗；guard 拒绝改为 deny 而非计数；候选
8 次迭代不收敛时镜像控制器的 typed `rule_loop_limit` 边界，不再虚构“将要提交的动作”。

## R-2（P3）— replay 窗口 extent 反转

`PolicyLog.window` 原按最新优先 tail 的顺序取 `entries[#entries]`/`entries[1]`，而 `replay`
传入旧→新 slice，导致 `window.first_seq > last_seq`。现改为**顺序无关**：按返回 entries 的
min/max seq 计算 `first_seq`（最旧返回）/`last_seq`（最新返回），`log`/`status`（最新优先 tail）
与 `replay`（旧→新）报出一致的窗口。同时修正 `semantics` 文案：`total` 是**累计写入事件数**
（ring 淘汰后可大于保留 `count`），不再误述为“描述保留 ring”。`docs/tome-mcp-api-fields.md` §6.1
已同步。

## 单测与回归覆盖（limit-1 边界）

| 层 | 位置 | 覆盖 |
| --- | --- | --- |
| controller | `tests/test_auto_combat_controller.lua` | limit-1：settled no-energy 拒绝不消耗预算、同机会 fall-through 完成一次动作；guard 拒绝不消耗预算、下一候选提交；**limit-1 emergency 活锁回归**（fallback 持续行动、冷却恢复、heal 复用、零 pause）；refusal 终点 stop+`action_denied`+`rule=heal`；charged 预算仍在（重复 oid → `budget_exhausted` pause，仅完成动作后触发） |
| service | `tests/test_auto_combat_service.lua` | limit-1 端到端：fallback 行动、零 pause、heal 复用、lease 保持；仅-heal 无 fallback → `stopped action_denied` + lease 释放 + `resume`→`not_running` + `start` 可重启；诚实 `budget_exhausted`（charged 后触发、lease 保留） |
| dry-run 镜像 | `tests/test_auto_combat_service.lua` | guard 拒绝不计数；候选不收敛时报 `rule_loop_limit` |
| movement | `tests/test_auto_combat_movement.lua` | 被拒重试不消耗预算（`attempts` 只计完成动作）；反复被拒落点受规则循环界定并 stop 交接（不冻结暂停） |
| production | `tests/native/tome-auto-combat-probe`（`critical` 场景） | (a) limit-1 下被拒 heal 经**真实原生执行器** fall-through 到 wait；**(c) 经生产 `AutoCombatService`**：仅-heal 全拒 → `stopped action_denied` + arbiter 归 manual + `resume` 拒绝 |
| 2/3 不回归 | controller/service 既有测试 | max=2/3 预算语义（charged 计数、重复 oid 界定）不变 |

## 验收

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| Lua 套件 41/41 | PASS | `tmp/anor-reg-01-fix2/lua-suite.log` sha256 `e972ccf3c81f338a516fa1fbf153cbdf5c0c127e72a729e6943bd8459cb0d898` |
| Python 39 | PASS | `tmp/anor-reg-01-fix2/python-tests.log` sha256 `8ca95e31be7867668fb4ebdd33c333486aef38dc54ceff69c77299b45fe4409f` |
| 三个 `--check` | exit 0 | `tmp/anor-reg-01-fix2/generator-checks.log` sha256 `29218d2d9431908f929dbe241e643c881afa79d95937f65fb4e4e29d6367a4ac` |
| auto-combat 探针 source / dist | 127/127 | `tmp/tome-mcp-validation/sessions/anor-live-fix2-src-01`（game.log `a27f1bbd365167a029e996964678d9738f18eaeb8ead058f2fed9c8615edbbbd`）/ `anor-live-fix2-dist-01`（`5cf62c7eb78543397fa043573b22f22bcc23eaba3b7bd8205025292e974bae28`） |
| 原生验收 source / dist | 101/101 | `anor-live-fix2-accept-src-01` / `anor-live-fix2-accept-dist-01` |
| `tools/package.py` + parity | 68/68 | dist `tome-mcp-bridge.teaa` sha256 `536d5e14602c51f69df5f1db4a35a3487c4d80de8c3eaf73d562d31be8812e35` |
| before/after 复现 | 见上 | `repro-before.out`（head `2348556`：冻结暂停）/ `repro-fix2.out`（fall-through + typed stop 交接） |

运行态不变量维持：不进存档、单写者、非阻塞 TCP、协议 v4 字段不变。
