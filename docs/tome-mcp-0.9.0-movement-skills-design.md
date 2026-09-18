# Auto-combat movement / repositioning design (0.9.0, revised)

Status: investigation proposal only. Revision baseline:
`main@cfbba62ba99f24d54846531cefe075822fe44e1a` (ToME 1.7.6). This
document does not implement behavior, authorize execution, change
`allow_auto_combat_execution`, or approve a merge.

Source citations under `game/...` are relative to `/workspace/t-engine4`; all
other paths are relative to this addon's repository root.

## 1. Binding principle and recommendation

The plugin is a **faithful executor of a data policy, an information provider,
and a control arbiter**. It is not a tactician. Movement, retreat, kiting,
teleportation, and `change_level` are ordinary policy actions. Whether they are
wise, or enabled in a particular play style, belongs to a policy/preset/mode.

The recommended implementation has four parts:

1. Add `move` and re-admit `change_level` to the policy action catalog.
2. Keep `use_talent` for movement talents, but add a destination request and an
   ordered target plan for actor/grid multi-prompt talents.
3. Report reachability, landing certainty, visibility, known passability, and
   known hazards as player-known **information**. A policy's explicit acceptance
   fields decide which reported states it permits.
4. Keep execution-integrity checks outside policy discretion: resolvable inputs,
   the game's **live** native entrypoint (no identity/digest gate), current
   control/revision/lease, bounded attempts, one live native action, and native
   final authority.

This reverses the previous proposal's strategy gates. In particular:

- an out-of-vision coordinate is not rejected merely for being out of vision;
- a random teleport is reported as random rather than refused;
- `away`/increased distance does not require `emergency:true` or a privileged
  `purpose` value;
- `change_level` is supported when the policy selects it, followed by the
  existing scene pause/reset and an explicit restart.

The **P1a `strict` preset** may still choose visible-fight-only behavior, contain
no retreat/change-level rules, and require deterministic visible landings. Those
are preset defaults, not plugin-wide capability or safety boundaries.

Policies remain JSON-only; planner ordering uses no RNG. Native game mechanics
may use RNG after the policy has deterministically chosen the action. That is an
uncertain effect of the chosen action, not a random policy decision. The frozen
data-only and deterministic-decision principles are in
`docs/tome-mcp-auto-combat-plugin-design.md:38-44,55-66`.

## 2. Verified current facts

The implementation does not yet expose this design:

- `PolicySchema.ACTIONS` currently contains `use_talent`, `attack`, `wait`,
  `rest`, and `auto_explore`; its selectors are self/hostile actor selectors and
  it has no destination selector
  (`overload/mod/auto_combat/PolicySchema.lua:9-31`).
- `EffectManifest` likewise has no `move` or `change_level` action
  (`overload/mod/auto_combat/EffectManifest.lua:333-365`).
- the Berserker preset uses a low-priority `wait` for a non-adjacent visible
  hostile because it cannot express closing movement
  (`overload/mod/auto_combat/PolicyPresets.lua:160-190`).
- the auto-combat production mapper lowers actor-bound attack/use-talent,
  sustain, and wait, but not raw movement, grid targets, or `change_level`
  (`overload/mod/mcp_bridge/Runtime.lua:1148-1177`).

The general bridge already has the necessary native seams for several cases:

- raw move validates a direction 1..9 other than 5 and calls
  `player:moveDir(direction)`; unchanged position and energy is reported as
  `blocked` (`overload/mod/mcp_bridge/Actions.lua:84-93,271-293`);
- `use_talent` accepts either one actor `target_id` or one grid `x/y`, then
  invokes native `useTalent` while prefilling the first `getTarget`
  (`overload/mod/mcp_bridge/Actions.lua:102-114,204-269`);
- `change_level` invokes the live native key handler and distinguishes
  `level_changed`, `change_level_pending`, native rejection, and uncertain error
  (`overload/mod/mcp_bridge/Actions.lua:128-161`).

Only the first target request is prefilled. An actor-then-grid talent therefore
needs an ordered target-plan extension; otherwise a later prompt becomes native
interaction (`overload/mod/mcp_bridge/Actions.lua:216-260`). This is a genuine
current capability limit, not a strategic prohibition.

The runtime already has the relevant non-tactical invariants: it revokes control
on manual input (`overload/mod/mcp_bridge/Runtime.lua:558-565`), invalidates the
old scene and level identity across change-level boundaries
(`overload/mod/mcp_bridge/Runtime.lua:396-446,644-658,832-843`), and the controller
does not resubmit while `native_pending` is live
(`overload/mod/auto_combat/AutoCombat.lua:352-405`).

Native movement can have mechanics-dependent results. A normal step may be
changed by confusion or Probability Travel, player movement may slide after a
failed step, and move callbacks run after relocation
(`game/modules/tome/class/Actor.lua:1388-1423,1490-1523`;
`game/modules/tome/class/Player.lua:312-332`). These facts must be described by
source-reviewed manifests and postconditions; they are not grounds for imposing a
global tactical rule.

## 3. Policy data model

### 3.1 Normalized rule shape

Retain the existing `when`/`then` model and same-target binding. Add a distinct
`destination` because the hostile used by a condition is not necessarily the
place where the player will land.

```json
{
  "id": "kite",
  "priority": 50,
  "when": {"nearest_enemy_distance": {"lt": 3}},
  "then": {
    "action": "move",
    "target": "nearest_hostile",
    "destination": {
      "selector": "away",
      "anchor": "bound_target",
      "accept": {
        "visibility": "any",
        "passability": "native",
        "hazard": "avoid_known",
        "landing": "allow_random"
      }
    }
  }
}
```

`emergency:true` remains an optional scheduling label for modes that want an
emergency-only phase. It does not make retreat legal, and its absence does not
make retreat illegal. `purpose` may be retained as descriptive log metadata
(`engage`, `reposition`, `retreat`, `travel`) but MUST NOT impose distance
monotonicity or grant capability.

Every normalized movement rule contains an explicit `accept` object. Source JSON
may either provide it or name a preset/mode whose expansion injects every field;
there is no hidden plugin default. Proposed fields are:

| Field | Values | Policy meaning |
| --- | --- | --- |
| `visibility` | `visible`, `known`, `any` | require current visibility; permit visible or remembered knowledge; or do not filter by knowledge state |
| `passability` | `known_passable`, `native` | require known terrain passability; or accept unknown/hidden collision and let native execution decide |
| `hazard` | `known_safe`, `avoid_known`, `any` | require an affirmative known-safe result; reject only known hazards; or do not filter by hazard knowledge |
| `landing` | `deterministic`, `allow_random` | require a single source-proven landing; or permit bounded/unbounded native randomness reported by the adapter |

These fields govern policy acceptance, not what the observer may reveal. The
observer still uses only player-known state. `any` never authorizes reading a
hidden actor, trap, terrain fact, or landing candidate.

### 3.2 Destination selectors

```json
{
  "selector": "toward | away | preferred_distance | position | relative | native_landing | native_random",
  "anchor": "bound_target | self",
  "distance": 4,
  "x": 17,
  "y": 9,
  "dx": -1,
  "dy": 0,
  "accept": {"visibility": "any", "passability": "native", "hazard": "any", "landing": "allow_random"}
}
```

| Selector | Meaning |
| --- | --- |
| `toward` | deterministically minimize distance to the anchor |
| `away` | deterministically maximize distance from the anchor; ordinary kiting/escape, with no special gate |
| `preferred_distance` | minimize `abs(distance(candidate,anchor)-distance)` |
| `position` | request the explicit current-level coordinate `(x,y)`, whether visible, remembered, or unknown |
| `relative` | request `(self.x+dx,self.y+dy)` |
| `native_landing` | use the source-described landing derived from the actor/grid request |
| `native_random` | make no claim of an exact endpoint; native code chooses the landing |

`target` continues to bind the actor used by target-relative predicates and an
actor-target action. It is required only when the chosen action/selector needs an
actor. `position`, `relative`, and a no-target self teleport need no hostile.
Thus a mode with `on_no_visible_enemy="evaluate_rules"` can legitimately execute
a movement or change-level rule when no hostile is visible.

Validation is allowlist-based as it is today
(`overload/mod/auto_combat/PolicySchema.lua:76-79`): reject unknown keys,
non-integer coordinates/distances, unsupported selector/action combinations, and
unbounded planner scan requests. Do not reject `away`, out-of-vision coordinates,
or `native_random` merely because of their strategy.

### 3.3 Ordered target plans

Represent every native prompt explicitly rather than inferring it from a talent
name:

```json
{
  "action": "use_talent",
  "talent": "T_PHASE_DOOR",
  "target_plan": [
    {"request": "actor", "selector": "self"},
    {"request": "grid", "destination": {
      "selector": "away", "anchor": "bound_target", "accept": {
        "visibility": "any", "passability": "native",
        "hazard": "avoid_known", "landing": "allow_random"
      }
    }}
  ]
}
```

The manifest declares the exact request sequence. Runtime validates each response
against the game's **current live** target builder before supplying it; a builder
that errors, is missing, or returns `nil`/an invalid value makes the request
unresolvable. A mismatch or extra prompt is execution non-determinability and
pauses without guessing (recorded source drift is telemetry only). Until
`Actions` supports more than one prefill, such a rule returns
`needs_input`/`unexpected_target_request`; it is not rejected because teleport is
random or tactically undesirable.

### 3.4 Plain movement, talents, and change level

Examples of ordinary policy actions:

```json
{"action":"move","target":"nearest_hostile",
 "destination":{"selector":"toward","anchor":"bound_target",
 "accept":{"visibility":"visible","passability":"known_passable",
 "hazard":"known_safe","landing":"deterministic"}}}
```

```json
{"action":"use_talent","talent":"T_PHASE_DOOR","target":"self",
 "destination":{"selector":"native_random","anchor":"self",
 "accept":{"visibility":"any","passability":"native",
 "hazard":"any","landing":"allow_random"}}}
```

```json
{"action":"change_level"}
```

`change_level` is explicit because a policy rule must select it; it needs no
special global permission bit. After the native transition starts, scene
invalidation pauses the executor, clears old target/destination references and
lease state, and requires an explicit start on the new scene. That pause/reset is
control integrity, not a policy judgment that changing level is unsafe.

## 4. Deterministic planning and uncertain native outcomes

The planner is deterministic even when the selected action is stochastic:

1. Freeze the player-known snapshot, `level_instance_id`, revision, owner epoch,
   origin, and any bound target.
2. Generate only the bounded candidates required by the selector. For a plain
   step use fixed keypad order `[7,8,9,4,6,1,2,3]`; for a grid talent scan the
   live target domain in `y,x` order; `position` and `relative` yield one
   requested coordinate. `native_random` generates no fictitious landing cell.
3. Attach player-known annotations to each request. A fact that cannot be known
   without hidden-state access is `unknown`, not queried indirectly.
4. Apply the rule's explicit `accept` filters. `known_safe` can filter an unknown
   hazard; `any` can retain it. No plugin-wide tactical filter is added.
5. Rank survivors by selector score, distance from origin, `y`, `x`, then stable
   native id. Table iteration order and RNG never participate.
6. Recheck control, revision, target identity, target-plan shape, and native
   readiness immediately before commit.

For a native-random talent, step 5 chooses the **action and any requested center**
deterministically. Native code may then consume RNG to choose the actual landing.
The decision record says `landing.kind="random"`; it does not sample, predict, or
rank secret landing cells.

Current map projection already distinguishes visible/remembered terrain and known
traps (`overload/mod/mcp_bridge/LevelMap.lua:33-57,131-166`), while
`Observer.terrainVisible` is a current-FOV predicate
(`overload/mod/mcp_bridge/Observer.lua:33-44`). Those inputs are information for
the policy. Checking actual occupancy with engine-wide entity queries solely to
rank an unseen destination would leak hidden information and remains forbidden.
Native collision is final authority.

## 5. Manifest, reports, and execution mapping

### 5.1 Movement manifest

Extend the canonical effect manifest rather than creating a second talent-name
whitelist. The catalog is already derived from that manifest
(`overload/mod/auto_combat/AutoCombatCatalog.lua:1-33`), and recorded source/drift
data is consumed as advisory re-review telemetry, not as a runtime gate
(`overload/mod/auto_combat/AutoCombatGuard.lua:177-215`).

```lua
movement = {
  target_requests = {"none" | "actor" | "grid", ...},
  delivery = "step" | "line_move" | "leap" | "teleport" | "scene_change",
  landing = "exact" | "bounded_alternatives" | "random" | "source_defined",
  center = "self" | "actor" | "requested_grid" | nil,
  radius = integer_or_dynamic,
  min_radius = integer_or_dynamic,
  traverses = true | false,
  relocates_other = true | false,
  source = {path=..., definition_line=..., action_digest=..., target_digest=...},  -- advisory metadata
}
```

A `landing="random"` native talent is supported even when not all landings are
knowable. The manifest records known bounds; missing bounds appear as `unknown`.
Fail closed only when the native entry/target sequence cannot be resolved (a
missing/erroring/`nil`/invalid return)—not because a live native entry
intentionally uses RNG, and not because a recorded source digest changed.

**随机端点 vs 未知包络（v1.6 澄清，来自 movement-adapter-factory 调研 §11）：** 当策展的、经 source review 的
adapter 已确立 **mover、请求序列、落点类别与一个有限保守落点包络**时，随机端点**不是**执行完整性失败——
可见性/占用/通行性/危险/包络内具体落点可保持 `unknown` 并报告给策略。若 adapter **无法**确立 mover、
请求顺序或任何"验证最终后置条件所需的有限保守包络"，则该动作以 **typed** movement 能力/推导原因标为
不可用。这不是策略拒绝，也不影响其它完整动作。

**Phase Door 变体矩阵（v1.6）：** 仅按有效等级门控**不充分**——当 `phase_door_force_precise` 属性存在时，
grid 提示在 **TL4 以下**就会出现。adapter 必须解析 **有效等级 × `phase_door_force_precise`** 的二维矩阵；
任一输入为 unknown 时返回 `movement_variant_unknown` 并 **fail closed**（不得提交无提示形态）。

### 5.2 Information report

Every dry-run and committed decision includes a movement report such as:

```json
{
  "requested": {"kind":"grid", "x":17, "y":9},
  "landing": {"kind":"random", "center":{"x":17,"y":9},
              "radius":5, "min_radius":0},
  "visible": false,
  "remembered": false,
  "known_passable": "unknown",
  "known_hazard": "unknown",
  "native_reachability": "accepted_by_builder",
  "confidence": "source_reviewed_random",
  "reasons": ["native_random_landing", "hidden_occupancy_not_inspected"]
}
```

Use three-valued fields (`true`, `false`, `unknown`) where relevant; do not label
unknown as safe or unsafe. After execution, append actual `from`, `to`, level id,
energy, native result, and whether the result matches the declared landing kind.
An actual random endpoint is normal for a random manifest.

The effect report remains separate and is composed conjunctively with movement:
the action is selected only if both its `destination.accept` and its policy risk
tolerance accept the available information. Known self/friendly-fire risk is a
policy value, not a plugin veto. If the effect footprint/risk cannot be determined
at all, that action fails closed because the executor cannot evaluate the policy.
The precise risk metric and default tolerance remain an open maintainer decision
(§12).

### 5.3 Execution mapping

| Case | Lowering / native entry | Current general `Actions` support | Integrity check; policy information |
| --- | --- | --- | --- |
| Plain step | chosen adjacent delta → `{type="move",direction}` → `player:moveDir` | yes | live move seam and postcondition; visibility/passability/hazard are reported and filtered only by `accept` |
| Actor-target movement (Rush) | `use_talent,target_id` → native `useTalent` | yes, first prompt | resolved actor, manifest/request match, effect + landing reports |
| Grid-target movement (Tumble/Blink) | `use_talent,x,y` → native `useTalent` | yes, but auto-combat mapper lacks it | live target builder, reported exact/alternate/random landing |
| No-target/random teleport | `use_talent` with no fabricated endpoint | yes when the native talent needs no prompt | live no-prompt entry; `landing=random`, knowledge fields may be unknown |
| Actor then grid | ordered `target_plan` responses | **no**, only first prompt today | pause/`needs_input` until target-plan support exists; never resubmit |
| Change level | `{type="change_level"}` → live native key handler | yes; auto-combat mapper lacks it | control/scene transition tracked; then pause/reset and explicit restart |

Auto-combat must call these `Actions` entries (the live native entrypoints); it must not call
`move`, `teleportRandom`, or scene APIs directly. Native range, projection,
collision, talent pre-use, and rejection remain final authority.

## 6. Invariants: integrity versus strategy

### 6.1 Mandatory execution-model invariants

These cannot be relaxed by a policy:

- policy is data only; no arbitrary Lua, field path, callback, or function name;
- every required actor/grid/input resolves to a typed value, and every native
  prompt is represented by a curated target plan;
- native entry, target builder, movement/effect source, and relevant helper seams
  are consumed as **live** calls; a missing/throwing/`nil`/invalid return makes
  that value unavailable and disables that action (recorded identity/digest is
  telemetry only);
- player-known observation never exposes hidden entities or unidentified facts;
- owner epoch, lease, revision, player/scene identity, and readiness still match
  at commit;
- one action is committed at a time; per-opportunity attempts and instant actions
  remain bounded;
- `native_pending` is tracked and never resubmitted;
- manual input revokes the lease; owner arbitration remains exclusive;
- dry-run is read-only and never reaches a commit entry;
- planner candidate generation and tie-breaks use no RNG;
- native resolution/rejection is final, and postconditions are logged;
- a scene change invalidates old references, pauses/resets execution, and needs an
  explicit restart.

“Non-determinability” here means the plugin cannot map the chosen data action to
one live native command/target sequence or cannot determine whether that
command finished. It does **not** mean that the selected game action has a random
or partially unknown gameplay outcome.

### 6.2 Policy-owned strategy choices

These are information plus explicit policy choices, never hard plugin gates:

- visible-only versus remembered/out-of-vision destinations;
- require known passability versus rely on native collision;
- require known-safe, avoid only known hazards, or permit unknown hazards;
- deterministic versus native-random landing;
- moving toward, away, or to a preferred distance;
- retreat, kiting, travel, teleportation, or changing level;
- whether rules run with no visible enemy or below an HP threshold;
- known self/friendly-fire tolerance.

A `strict` preset can select the conservative member of every row. Another preset
can select different values against the same report. The plugin must produce the
same underlying player-known facts for both.

### 6.3 Effect risk composition

For a mixed move+attack talent:

1. build one movement information report and one effect information report;
2. fail that action if either report itself cannot be computed because of a
   missing/erroring/`nil`/invalid getter/builder return or unresolved input;
   a replaced-but-working getter is not a failure;
3. otherwise evaluate movement acceptance and effect-risk tolerance from the
   policy; and
4. commit only when both policy evaluations accept.

Thus a known `max_selffire_risk` exceedance is a policy rejection, not a plugin
integrity veto. An indeterminable self/friendly-fire footprint remains fail-closed
for that action. It need not stop unrelated actions whose reports are complete.

## 7. Exact amendments to the canonical contract

The canonical document currently freezes strategy choices as product-wide gates.
This revision requires a normative amendment; it is not merely an implementation
clarification. The following replacement text is exact proposed wording.

### 7.1 Replace §0.1 in full

**Before** (`docs/tome-mcp-auto-combat-plugin-design.md:18-27`):

```text
### 0.1 产品契约（v1.1 冻结，先于一切实现）
**按下启动后，它只负责“处理当前可见战斗”**：
启动 → 校验策略/技能支持 → 自动处理当前可见战斗
     → 出现明确风险时暂停并解释 → 无可见敌人时结束 → 控制权交还玩家
- **无可见敌人即结束**；不探索、不追击进未知区域、不自动换层。
- **没有可用动作时不空等**：不因规则失败就隐式等待冷却/巡逻，而是**停止并说明原因**。
- 自动等待/巡逻只作为**独立的显式模式**，不从规则失败中隐式产生。
- “接管到什么程度”是产品承诺，必须先冻结；复杂能力（rest/auto_explore/换层/复杂撤退）后移。
```

**After (proposed normative text)**:

```text
### 0.1 产品契约（v1.6：策略忠实执行）
插件是**数据策略的忠实执行器 + 玩家已知信息提供者 + 控制仲裁器**，不是战术制定者：
启动 → 校验策略、能力与控制边界 → 按策略逐机会选择并提交一个原生动作
     → 记录原生结果/不确定性 → 在完整性边界或策略指定的停止条件暂停 → 控制权交还玩家
- `move`、撤退、拉开距离、传送、`rest`、`auto_explore` 与 `change_level` 均为普通策略动作；是否使用、何时使用以及接受何种可见度/危险/随机落点，由策略或命名 preset/mode 明示，插件不得另加战术门槛。
- P1a `strict` preset 默认只处理当前可见战斗：无可见敌人即结束，不探索、不追击未知区域，不含自动撤退、随机传送或换层规则；这些是该 preset 的默认值，不是插件全局能力边界。
- 插件仅在无法忠实执行时 fail closed：目标/目标请求无法解析，必需值因 getter/builder/执行入口缺失、报错或返回 `nil`/类型无效而无法取得，控制/lease/revision/场景边界失效，预算耗尽，原生拒绝，或无法判定原生动作是否完成。（source drift 仅为重审提示/遥测，本身不构成失败。）
- 随机落点、视野外坐标、未知通行性或未知危险属于策略信息，不等同于执行不可判定；dry-run/decision/log 必须如实标注，由策略的显式容忍度决定是否提交。不得为改善决策而读取玩家未知信息。
- 没有匹配动作时按策略的 `on_unavailable`/mode 处理；不得从规则失败中隐式生成等待、巡逻、探索、撤退或换层动作。
```

### 7.2 Replace the action/field gate in §5.3

**Before** (`docs/tome-mcp-auto-combat-plugin-design.md:228-236`):

```text
动作白名单：`use_talent`（带 `target` selector 或 `x/y`）、`attack`、`move`（`direction` 或 `retreat` 一步/多步）、
`wait`、`use_item`、`rest`（P1b）、`auto_explore`（P1b）、`change_level`（默认禁用，需显式 opt-in）。

目标 selector：`nearest_hostile`、`lowest_hp_hostile`、`highest_rank_hostile`、
`most_dangerous`（按 `computed`）、`cluster_center`（AoE：`min_targets`、`max_selffire`）、`self`、`position`。

**规则字段（冻结）**：`id`、`priority`（越大越先）、`when`、`then`、可选 `emergency:true`、可选 `enabled`。
**危急自保必须由 `emergency:true` 显式标记**，执行器再用能力目录验证该动作确实满足自保要求；
**不得靠规则名为 `heal` 或优先级高低推断**。
```

**After (proposed normative text)**:

```text
动作白名单由已实现 schema 与生成 catalog 共同给出：`use_talent`、`attack`、`move`、`wait`、`use_item`、`rest`、`auto_explore`、`change_level`。未实现阶段必须按 capability 报告，不得把路线图动作伪报为可执行。

`target` 绑定 actor；`destination` 以纯数据 selector 表达移动请求，并携带显式的 visibility/passability/hazard/landing 接受条件。多次原生选目标用与版本固定 manifest 一致的有序 `target_plan`。计划器的候选与 tie-break 必须确定；原生动作自身的随机结果允许执行，并在 dry-run/decision/log 标注。

`change_level` 是普通显式动作。原生换层后执行器按场景边界暂停、清除旧 level/target/destination/lease 状态，并要求在新场景显式重新启动；此生命周期不等于禁止策略选择换层。

**规则字段**：`id`、`priority`、`when`、`then`、可选 `emergency:true`、可选 `enabled`。`emergency` 仅供 preset/mode 调度规则组，不赋予或撤销动作能力；撤退、拉开距离、随机传送和换层均不要求该标记。不得靠规则名或优先级推断语义。
```

Keep the existing same-target binding algorithm at §5.3 lines 238-245, extended
so each grid request is bound/rechecked in target-plan order.

### 7.3 Replace §5.4 in full

**Before** (`docs/tome-mcp-auto-combat-plugin-design.md:259-275`):

```text
### 5.4 危急状态与自保语义（v1.2 冻结）
执行器按固定三层，策略只能**收紧**不能放宽：
1. **执行边界异常**（owner/场景/原生错误/unsafe unknown）→ 停止或暂停。
2. **危急状态**（`hp_pct < flee_below_hp_pct` 或卫生守卫触发）→ **只**尝试预设中明确允许的紧急自保
   （治疗/护盾/解控/一步撤离）；**无可用方案则暂停并交还玩家，不继续普通输出**。
3. **其余状态** → 执行普通规则（按 priority）。
- `min_hp_pct`：**启动/继续门槛**——低于它不开始/不继续普通规则（进入第 2 层）。
- `flee_below_hp_pct`：第 2 层紧急自保触发阈值；必须 `<= min_hp_pct`。
- **首版默认不出自动撤退**；`move{retreat}` 仅在预设显式启用且通过目的地判定测试后可用。
- 自保动作同样要过 adapter/`canProject`/原生返回；`unknown` 按 §8.1 处理。
- **阈值边界（冻结用例）**：`hp_pct < min_hp_pct` 即禁止普通输出（进入第 2 层）；例如 `min_hp_pct=35` 时，
  生命 30% 不得放普通输出，与是否低于 `flee_below_hp_pct` 无关。
- **Wave 1（D6）阈值诚实化**：`flee_below_hp_pct` 是**独立的暂停原因**（`flee_below_hp_pct`），
  只把控制权交还玩家，不做自动撤退；`sustain.min_resource_pct` 真正门控常驻激活（资源未知则不激活）。
- **Wave 1（D1/D2）自保与自伤**：`emergency:true` 可声明任意 `use_talent`/`attack`，安全性由执行前的
  版本固定 adapter guard 在实际绑定目标上判定（射程/`canProject`/几何/自伤/友伤 + `max_selffire_risk`）；
  `max_selffire_risk==0` 为硬拒绝，`>0` 为暂停阈值。
```

**After (proposed normative text)**:

```text
### 5.4 策略模式、危急状态与风险信息（v1.6）
执行器不内置固定战术层。命名 preset/mode 必须把下列行为规范化为显式数据：无可见敌人时 `stop|evaluate_rules`；低于 `min_hp_pct`/`flee_below_hp_pct` 时 `pause|emergency_only|evaluate_rules`；以及移动可见度、已知通行性、已知危险与随机落点的接受条件。

- P1a `strict` preset 保留旧行为：无可见敌人停止；低生命进入 `emergency_only` 或暂停；无撤退、随机传送、探索或换层规则；目的地要求由该 preset 明示。其它 preset/mode 可选择不同值。
- `emergency:true` 只标记可被 `emergency_only` 调度的规则，不是动作能力或安全授权。普通规则可以撤退、拉开距离、传送或换层；策略对其后果负责。
- 插件报告 player-known 的 reachability/visibility/passability/hazard/landing 信息。视野外、随机或安全性未知的落点按不确定性标注，并由策略接受条件决定；不得据此读取隐藏状态。
- 移动与效果信息合取求值：两部分都必须可计算且都被策略接受。已知自伤/友伤风险由策略容忍度决定；风险 footprint 无法确定时仅禁用该动作。`max_selffire_risk` 的度量与内置 preset 默认必须单独冻结。
- owner/场景/lease/revision、必需值不可得（getter/builder 缺失/报错/`nil`/类型无效）、预算、原生拒绝或动作完成状态不明属于执行完整性边界，策略不得放宽。
- `change_level` 成功或开始场景迁移后总是暂停并重置旧场景状态，要求显式重新启动。
```

### 7.4 Consequential exact amendments

Replace §2 principle 2 (`docs/tome-mcp-auto-combat-plugin-design.md:57-60`)
with:

```text
2. **三值信息 + 分层 fail-closed**。条件与信息结果为 `true/false/unknown`。执行完整性未知（控制、目标请求、必需值不可得、预算、原生完成状态）必须 fail closed；战术结果未知（视野、通行、危险、随机落点）必须如实报告并由策略显式接受条件求值；效果 footprint 无法计算时禁用该动作。
```

Replace the relevant §8.1 table rows
(`docs/tome-mcp-auto-combat-plugin-design.md:393-402`) with:

```text
| 未知/异常 | 规范行为 |
| --- | --- |
| 控制权、当前角色、场景边界、lease/revision、原生动作是否结束不明确 | 整个执行器暂停 |
| 必需目标/目标请求无法解析，或原生入口/getter/builder 缺失/报错/返回 `nil`/类型无效 | 禁用该动作；若已提交或影响当前唯一控制边界则暂停 |
| 某范围技能的友伤/效果 footprint 无法计算 | 禁用该动作，不否定其它报告完整的动作 |
| 移动落点随机、视野外，或通行性/危险为 unknown | 保留 unknown 注解，按策略显式接受条件求值；不得读取隐藏状态来消除 unknown |
| 仅用于目标优化的属性不明确 | 跳过依赖它的规则，或使用策略规定的简单 selector |
| 玩家学了一个策略未使用的未适配技能 | 显示“未支持”，不阻止启动 |
```

Replace §1.2's “自动换层” non-goal and §15.1's baseline wording
(`docs/tome-mcp-auto-combat-plugin-design.md:46-50,580-593`) with the following
clarification:

```text
- P1a `strict` preset 不提供队友指挥、自动换装/工匠或召唤管理；其内置规则不包含 rest/auto_explore/change_level。`change_level` 动作能力可被其它显式策略使用，但不改变换层后的 pause+reset+explicit restart 生命周期。

### 15.1 首版基线（P1a strict preset）
（技能白名单保持不变。）
- **preset**：`strict`（`pause_on_new_enemy=true`）；风险容忍度待按 §5.4 的度量冻结；内置规则无自动撤退、随机传送、rest/auto_explore/change_level。
- P1a 试点 UI 可以不生成上述规则，但 schema/catalog/capability 必须诚实地区分“执行器已支持”与“该 preset 未使用”；preset 缺省不得被解释为插件全局禁用。
```

Finally append this normative supersession note to the Wave 1 decisions. It
explicitly replaces D5/D6, whose current text removed `change_level` and made the
flee threshold pause-only
(`docs/tome-mcp-0.9.0-wave1-execution-safety.md:50-64`):

```text
### D5/D6 supersession — policy-owned movement behavior (v1.6)
D5's removal of `change_level` from auto-combat and D6's unconditional pause-only flee behavior are superseded. Re-admit `change_level` as a capability-backed policy action; after native scene transition, pause/reset and require explicit restart. `flee_below_hp_pct` behavior is selected by the normalized preset/mode (`pause|emergency_only|evaluate_rules`). P1a `strict` expands to the former pause/no-change-level behavior, but the executor imposes neither restriction globally.
```

No amendment to `allow_auto_combat_execution=false` is proposed.

## 8. Failure, stall, and scene semantics

| Situation | Required result |
| --- | --- |
| policy acceptance removes all candidates | rule unavailable; follow explicit `on_unavailable`/mode, with no invented wait/retreat/explore action |
| actor or required grid cannot be resolved | fail closed for that action; another independent rule may still be evaluated |
| unknown visibility/passability/hazard with a policy that permits it | submit the live native request with unknown annotations |
| random landing with `landing=allow_random` | submit once; log declared randomness and actual result; do not predict or retry for a better endpoint |
| target-plan mismatch or an unresolvable (missing/erroring/`nil`/invalid) entry/getter | disable the action and pause when current control cannot safely continue |
| native rejection before energy spend | record rejection; do not retry the unchanged action in the same opportunity |
| `native_pending` | enter waiting state and submit nothing until a tracked safe boundary |
| manual input / lost owner epoch / lease or revision change | revoke/pause; no further commit |
| deterministic manifest produces an undeclared endpoint | postcondition/source-integrity failure; pause |
| random manifest produces a native-returned endpoint | normal uncertain outcome; record actual endpoint |
| explicit `change_level` starts or completes transition | report transition, revoke old scene state, pause/reset, require explicit restart |

Candidate enumeration is a bounded read. Real submissions and guard rejections
use the existing per-opportunity attempt budget. An exhausted budget never causes
an implicit retry. A successful no-energy talent uses the existing bounded
instant-action semantics.

## 9. Source-verified talent classification

| Talent | Native target / landing | Classification and proposed treatment |
| --- | --- | --- |
| Berserker `T_RUSH` | actor target; walks a terrain-blocked line, lands before the target, then attacks (`game/modules/tome/data/talents/techniques/combat-techniques.lua:23-85`) | actor-anchored line move + effect; support with a curated landing/effect report |
| Archmage `T_PHASE_DOOR` | low-level random self teleport; TL4 can select a creature; TL5 adds a target-area prompt; final relocation uses `teleportRandom` (`game/modules/tome/data/talents/spells/conveyance.lua:65-168`) | ordinary random teleport; low-level no-prompt form is callable and must be annotated, while TL5 automated actor+grid needs target-plan support |
| Archmage `T_TELEPORT` | TL4 actor and TL5 area selection; random teleport with minimum range (`game/modules/tome/data/talents/spells/conveyance.lua:170-284`) | ordinary long-range random teleport; support when its prompt plan/source adapter is present, not globally refused |
| Archmage `T_DISPLACEMENT_SHIELD` | actor-target shield; does not relocate the player (`game/modules/tome/data/talents/spells/conveyance.lua:286-321`) | not movement; effect adapter work only |
| Skirmisher `T_SKIRMISHER_CUNNING_ROLL` (Tumble) | one beam/grid target, native blocked/projection checks, exact forced move (`game/modules/tome/data/talents/techniques/acrobatics.lua:127-187`) | exact grid movement; support after the auto-combat grid mapper is added |
| Skirmisher `T_SKIRMISHER_VAULT` | grid landing plus visible adjacent launch actor, then exact forced move (`game/modules/tome/data/talents/techniques/acrobatics.lua:27-125`) | exact grid move with prerequisite/effect report; later adapter |
| Paradox Mage `T_DIMENSIONAL_STEP` | visible grid; TL5 may swap an actor; otherwise `teleportRandom(x,y,0)` (`game/modules/tome/data/talents/chronomancy/spacetime-weaving.lua:22-90`) | requested-grid teleport with possible swap/random fallback; report alternates rather than refuse, but moving-another-actor support is a current gap |
| Blink rune | visible grid followed by `teleportRandom(x,y,0)` (`game/modules/tome/data/talents/misc/inscriptions.lua:646-686`) | requested-grid teleport with random fallback; allow under policy `landing=allow_random` after adapter work |
| Shadowstep | actor target, teleport near target, then attack (`game/modules/tome/data/talents/cunning/shadow-magic.lua:109-159`) | actor-anchored random teleport + effect; compose both reports |
| Movement Infusion | schedules a movement-speed effect, no displacement (`game/modules/tome/data/talents/misc/inscriptions.lua:203-225`) | self buff, not a move |
| Giant Leap | grid target; occupied destination may use `findFreeGrid(radius=1)`; then move + radius effect (`game/modules/tome/data/talents/uber/str.lua:20-79`) | requested-grid movement with alternate landing + effect; later adapter |

`teleportRandom(...,0)` is not necessarily exact: it first uses a radius-5
`findFreeGrid` fallback (`game/modules/tome/class/Actor.lua:1631-1647`), whose
candidate tie-break contains RNG (`game/engines/default/engine/utils.lua:2943-2981`).
Ordinary random teleport also chooses a candidate using RNG
(`game/modules/tome/class/Actor.lua:1652-1687`). Under this design those facts
produce `landing.kind="random"`, bounds/confidence annotations, and policy
evaluation—not a plugin refusal.

## 10. Test and verification plan

### 10.1 Pure fixtures

1. Schema accepts `toward`, `away`, `preferred_distance`, explicit out-of-vision
   `position`, `relative`, `native_landing`, `native_random`, and `change_level`;
   it rejects arbitrary fields/Lua and malformed typed inputs.
2. Normalization requires every acceptance field or expands a named preset to the
   same explicit object. Assert no implicit plugin default remains.
3. Symmetric candidates always choose by score/distance/`y`/`x`/stable id,
   independent of insertion order; planner RNG is never called.
4. Feed identical player-known map information to `strict` and permissive
   policies. Assert the report is identical while strict filters an unknown or
   out-of-vision landing and permissive submits it.
5. Phase Door dry-run reports `landing=random` and unknown safety facts. With
   `allow_random`/`any`, it selects the native action; with `deterministic`, it is
   a policy rejection. Neither result is hard-coded by talent name.
6. A ranged policy's ordinary `away` rule increases distance without
   `emergency:true`; the same selector is legal in a normal-priority rule.
7. A no-visible-enemy mode set to `evaluate_rules` can choose explicit movement
   or `change_level`; `strict` stops because of its mode data.
8. Known self/friendly-fire risk below/above two policy tolerances yields different
   policy results over the same effect report. An uncomputable footprint fails
   that action closed; unrelated complete actions remain eligible.
9. A missing/throwing/`nil`/invalid getter return, an unresolved actor,
   target-plan prompt mismatch, lost lease, stale revision, and budget exhaustion
   all prevent commit. A replaced-but-working getter does not, and recorded source
   drift is telemetry only.
10. `native_pending` never resubmits; manual input revokes; dry-run never reaches
    `Actions.execute`.
11. A successful `change_level` invalidates old level/target/destination state and
    remains paused until explicit restart.
12. Hidden occupants/traps never enter candidate ranking. Unknown annotations may
    change policy acceptance but never trigger a hidden-state query.

### 10.2 Native source/dist probes for the implementation phase

- **Plain step:** compare chosen delta and real `moveDir` outcome in all eight
  directions, including a hidden blocker. Prove that the planner did not expose
  the blocker and native collision remained authoritative.
- **Rush/Tumble:** compare manifest request/landing/effect reports to native open,
  blocked, range-edge, and modifier cases. Verify production lowering uses the
  live actor/grid entry.
- **Random teleport:** run Phase Door/Blink from a live build. Assert the
  decision is made without RNG, the native call occurs once when policy permits,
  dry-run never commits, and the actual random landing is logged rather than
  treated as an adapter failure. Sampling outcomes is not a safety proof.
- **Out-of-vision request:** verify a policy may pass the coordinate to the live
  native builder without hidden map reads; native acceptance/rejection is logged.
- **Change level:** verify action outcome, scene-id invalidation, lease release,
  cleared references, paused status, and required explicit restart.
- **Effect composition:** verify a mixed movement/effect talent against multiple
  known risk tolerances and an indeterminable-footprint negative case.
- Run probes against source and packaged `dist`, pin the package SHA-256, and
  compare source/dist manifest digests as **advisory build provenance** under the repository's runtime evidence
  rules.

### 10.3 Per-talent source-review checklist

Record talent id, game version, definition/action/target/helper paths and lines
(advisory metadata; recorded digests are telemetry, not gates); exact
prompt sequence; live range/shape/LOS/projection; every move/teleport/swap and
alternate/random outcome; traversed cells; affected actors; effect footprints;
active modifiers/hooks; which facts are player-known; current `Actions` lowering;
native pending/rejection/energy behavior; postconditions; and a missing/erroring
negative test. Record unknown landing bounds as unknown—do not invent proof or
silently turn uncertainty into refusal.

## 11. Genuine unsupported/capability limits

The following remain unsupported until their execution capability exists:

- **Actor-then-grid and longer prompt sequences:** current `Actions` pre-fills one
  target request only. The ordered target-plan extension is required.
- **Auto-combat lowering for plain move, grid talent, and change level:** general
  `Actions` supports their basic native seams, but the current production mapper
  does not emit them.
- **Unaudited/modded movement:** unknown/unsupported talents stay unavailable
  until a curated adapter exists; once curated, the adapter calls the actual live
  entry, and a later replacement by another addon is that addon's concern.
- **Policy conditions requiring hidden actors, traps, or unknown terrain facts:**
  player-known-only observation makes those facts unavailable. They stay
  `unknown`; no omniscient selector may be added.
- **Canonical hazard classification:** the repository exposes known map/trap
  information but has no complete movement-hazard manifest. Reports must say
  `unknown` outside reviewed families; policies may choose whether to accept it.
- **Moving/swapping another actor:** this needs typed multi-actor destination and
  effect semantics; current adapters do not provide them.
- **Arbitrary Lua, unbounded pathfinding expressions, or direct native function
  names in policy data:** incompatible with the data-only/native-entry contract.

Random landing, out-of-vision movement, retreat/kiting, and `change_level` are
**not** on the unsupported list merely because of their strategy. A particular
talent may still wait for its adapter/target-plan implementation.

## 12. Residual uncertainty for maintainer decision

1. **Self/friendly-fire metric and defaults:** freeze the exact reported unit and
   comparison semantics, then choose named-preset tolerances. The maintainer has
   explicitly left the default open; this document does not select one.
2. **Hazard vocabulary:** define the first curated terrain/ground-effect
   families and whether `known_safe` can ever be affirmative without a canonical
   manifest. Until then, `unknown` is honest and policy-controlled.
3. **Target-plan wire shape:** decide whether ordered responses extend
   `Actions.use_talent` directly or use a typed runtime interaction adapter. It
   must preserve one-action tracking and `native_pending` non-resubmission.
4. **Epistemic passability:** visible terrain can be known passable while a hidden
   entity blocks it. The report must preserve `known_passable` versus actual
   native reachability and never claim omniscience.
5. **Random landing envelope quality:** some curated talents expose center/radius;
   others may only support `kind=random, bounds=unknown`. The policy can accept
   either, but confidence/reason fields and postcondition logging need a stable
   schema.
