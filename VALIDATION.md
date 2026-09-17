# MCP Bridge 验收记录

## 0.9.0：移动/重新定位第一段 rev 2（MFT-REV-01 … 09，待评审）

日期：2026-09-17。分支 `feat/movement-first-tranche`（PR #15），rev 2 在 rev 1 `2e5dae2` 基础上修复独立评审 `4ba89dc2` 的 **0 P0 / 6 P1 / 3 P2**。`allow_auto_combat_execution` 保持 `false`。状态：**ready for review**。原始证据见 `tmp/movement-first-tranche/rev2/`。

| 反馈 | 结果 | 修复与回归证据 |
| --- | --- | --- |
| MFT-REV-01 策略模式 | **PASS**：`policy.mode={on_no_enemy='stop'\|'evaluate_rules',on_low_hp='pause'\|'emergency_only'\|'evaluate_rules'}` 为显式数据；内置 preset 显式展开旧的保守行为；`evaluate_rules` 在低 HP 执行任意声明动作；`emergency` 仅为调度标签（schema 不再有动作白名单）；删除全局 flee 暂停 | `test_auto_combat_policy.lua`（新增 mode + emergency move/rest 用例）、`test_auto_combat_movement.lua`（低 HP kite 执行）、`test_auto_combat_controller.lua` |
| MFT-REV-02 Q4 阈值 | **PASS**：`EffectRisk.measure` 冻结数值风险聚合（self=min(SF,FF)、friendly=FF，unknown 主导）；guard 与 `max_selffire_risk` 数值比较，**在容忍度内 permit 并携带 measurement/threshold/provenance**，超过或不可计算则 reject；dry-run/决策/日志均上报 | `test_effect_risk.lua`、`test_auto_combat_guard.lua`（permit/above/unknown）、`test_runtime.lua`、`test_auto_combat_service.lua`（dry-run risk） |
| MFT-REV-03 target_plan | **PASS**：schema 校验每步 request 专属字段；`EffectManifest.verify` 与源固定 `movement.target_requests` **逐项比较**；planner 消费首个 request；多提示或 adapter 缺失以 typed reason（`unsupported_target_plan`）**暂停**，不静默忽略 | `test_auto_combat_policy.lua`、`test_auto_combat_movement.lua`、`test_effect_manifest.lua` |
| MFT-REV-04 目的地语义 | **PASS**：`landing='deterministic'` 拒绝所有非单一落点（`bounded`+`random`）；hazard 极性统一为 `true`=已知危险、`false`=确认安全、`unknown`=未知；provider/filters/文档/测试/序列化一致 | `test_auto_combat_movement.lua`、`test_runtime.lua`（known trap） |
| MFT-REV-05 dry-run 行为 | **PASS**：dry-run 运行与执行器相同的**有界 deny/fall-through 循环**（不提交、不调用执行器），报告被拒规则+原因，并返回 live 会提交的下一个动作 | `test_auto_combat_service.lua`（fall-through + risk） |
| MFT-REV-06 不确定场景切换 | **PASS**：`mapAutoCombatOutcome` 独立于 status 保留 `level_changed`；控制器对任何已开始/完成的场景迁移停止/重置并拒绝 resume；dry-run 保留不确定性 | `test_auto_combat_execution.lua`、`test_auto_combat_movement.lua` |
| MFT-REV-07 日志完整性 | **PASS**：移动标注与 guard measurement/threshold/provenance/unknown 经有界 `boundedDetail` 进入 step 结果、`PolicyLog` 与 replay | `test_auto_combat_movement.lua`（step.risk + rejection detail）、`AutoCombatService` 日志字段 |
| MFT-REV-08 能力上报 | **PASS**：结构化 `EffectManifest.UNSUPPORTED`（talent/scope/missing/reason，含 Phase Door TL≥4 actor+grid）；Phase Door 声明 `unsupported_variants`，runtime 以同一 typed reason 拒绝；`capabilities.auto_combat.unsupported` 公布 | `test_effect_manifest.lua`、`test_auto_combat_movement.lua`（variant）、`Runtime` capabilities |
| MFT-REV-09 原生适用性 | **PASS**：source+dist 原生探针新增 `movement-talents`（Rush actor 锚定、精确网格 Tumble、随机 Phase Door，经真实 `Actions.execute`）与 `scene-lifecycle`（真实原生 `CHANGE_LEVEL` → 层级变化、controller stopped、resume 拒绝）；`mcp-test` 竞技场扩为两级 | `tests/native/tome-auto-combat-probe/...`、`probe-source-result.json`/`probe-dist-result.json` |

命令与原始证据（`tmp/movement-first-tranche/rev2/`）：

| 命令 | 结果 | 文件 / sha256 |
| --- | --- | --- |
| `bash tests/run.sh` | 40 套全绿 | `lua-suite.log` `f0b2a15be907e0695961b324a3570a0e229f48945e2a4499775090dacd0f43bb` |
| `PYTHONPATH=server/src <venv>/python -m unittest discover -s server/tests` | 39 OK | `python-tests.log` `3d84718e933f1e7c0dde65fc1882c911e65d7d27e3f7aa041031699156e4717e` |
| 三个 `--check` | 3/3 exit 0 | `generator-checks.log` `2503208f26358c11c18060261b70491e476054b8e2281485592a8142d60e4ab4` |
| auto-combat 探针 source `rev2-src-11` | **105/105** | `probe-source-result.json` `73ea4364492cf3c2885e71ae42245d4c9b3557237d0e0a7b1f7ebdc625d0f620` |
| auto-combat 探针 dist `rev2-dist-01` | **105/105** | `probe-dist-result.json` `907b4961036810c157e4349f45f47c75415d8aa1245a6c0a78281482f5f47c0e` |
| 原生验收 source `rev2-accept-src` | **100/100** | `acceptance-source-result.json` `378635c2897c85d77463cc4c25b567022c01a84ff1e66191ed787f7f28fb1079` |
| 原生验收 dist `rev2-accept-dist` | **100/100** | `acceptance-dist-result.json` `ab94474352988416fd728c308792e49e597fb6abb666513b4b38055ac1f54d2c` |

不变量核对（保持）：单次机会一个原生动作；尝试/瞬发预算；`native_pending` 不重复提交；手动输入收回租约；owner 仲裁；只读 `dry_run`；确定性 tie-break（无 RNG）；原生裁决最终；场景切换 pause/reset 且需显式重启。R-1…R-6 “found correct” 项经全套 Lua/Python/两套原生复跑保持。

正式包 **67 个生产文件**，SHA-256（rev 1 `d4a3affe48c6cee479f69d785533105e9c3470aae32d5b7b3e032670b233c916` → rev 2）：

```text
317213c3282547e1b93fbcf9328abadb07c950e6381a72001588add8b9b1a60a
```

未修/延期：无。独立复核由 `4ba89dc2` 执行。

## 0.9.0：移动/重新定位第一段（MOV-1 … MOV-6，rev 1，待评审）

日期：2026-09-17。分支 `feat/movement-first-tranche`（基线 `main@a3b3a9a`）。执行 v1.6 插件职责边界（`AGENTS.md` §插件职责边界、`docs/tome-mcp-auto-combat-plugin-design.md` §0.1/§1.2/§5.3/§5.4/§8.1）与 `docs/tome-mcp-0.9.0-movement-skills-design.md`。`allow_auto_combat_execution` 保持 `false`。状态：**ready for review**（未合并，未经独立评审）。原始证据见 `tmp/movement-first-tranche/`。

| ID | 结果 | 证据 |
| --- | --- | --- |
| MOV-1 schema/catalog/planner | **PASS**：新增 `move` 与纯数据 `destination`（`toward/away/preferred_distance/position/relative/native_landing/native_random`）+ 显式 `accept`（visibility/passability/hazard/landing 全必填，无隐藏默认）；`target_plan` 严格校验；`change_level` 回白名单；`T_RUSH`/`T_SKIRMISHER_CUNNING_ROLL`/`T_PHASE_DOOR` 源固定 adapter；`MovementPlanner` 纯函数、固定 `[7,8,9,4,6,1,2,3]` 顺序与确定性 tie-break、无 RNG | `tests/test_auto_combat_policy.lua`（96）、`tests/test_auto_combat_catalog.lua`（60）、`tests/test_auto_combat_movement.lua`（34）、`tests/test_effect_manifest.lua`（348）、`tools/generate_effect_manifest.py --check` |
| MOV-2 执行 | **PASS**：普通相邻步 → `{type:'move',direction}`；网格技能 → `use_talent,x,y`；`native_random` → 无伪造端点；`T_RUSH` actor-anchored landing；`change_level` 真实迁移 → 控制器 `stopped/reason=level_changed` 并释放租约，`change_level_pending` → 交还交互 | `tests/test_auto_combat_movement.lua`、`tests/test_auto_combat_execution.lua`（12）、`tests/test_runtime.lua`（179）、原生 `movement:step-executes` |
| MOV-3 不确定性标注 | **PASS**：`dry_run`/decision/log 带 `landing`/`visible`/`remembered`/`known_passable`/`known_hazard`/`confidence`；unknown 保持 unknown；只读 FOV/`remembers`/`seens`/已审计 `Details.terrain`，不读隐藏占用 | `tests/test_auto_combat_movement.lua`、`tests/test_runtime.lua`、原生 `movement:grid-annotation`/`movement:random-annotation` |
| MOV-4 自伤 Q4 | **PASS**：同一已知自伤/友伤 footprint，`max_selffire_risk=0` → reject、`>0` → pause，风险详情随 verdict 报告；无全局硬拒绝；仅不可计算 footprint fail-closed；内置 preset 保持 `0` | `tests/test_auto_combat_guard.lua`（45）、`tests/test_runtime.lua` |
| MOV-5 回退 Wave-1 移除 | **PASS**：`change_level` 回到 schema/catalog/capability/executor；Wave-1 断言更新；取代记录于 `docs/tome-mcp-0.9.0-wave1-execution-safety.md`（D5/D6 supersession） | `tests/test_auto_combat_policy.lua`、`tests/test_auto_combat_catalog.lua` |
| MOV-6 整体 | **PASS**：Lua 40 套全绿、Python 39、三个 `--check` exit 0；auto-combat 探针 source/dist 各 **94/94**；原生验收 source/dist 各 **100/100**；重新打包 | 下表 |

命令与原始证据（`tmp/movement-first-tranche/`）：

| 命令 | 结果 | 文件 / sha256 |
| --- | --- | --- |
| `bash tests/run.sh` | 40 套全绿 | `lua-suite.log` `94dd9a9ee690c2752ddc2669ff7c988005064320eaf5ac01eec5b7e1a4ed96fa` |
| `PYTHONPATH=server/src <venv>/python -m unittest discover -s server/tests` | 39 OK | `python-tests.log` `c0a6a40ed8d021f6d3f91c44c0bbb9539a4e47a0c2522f6d4a767bd94def83a9` |
| `python3 tools/{generate_native_seams,generate_protocol,generate_effect_manifest}.py --check` | 3/3 exit 0 | `generator-checks.log` `2503208f26358c11c18060261b70491e476054b8e2281485592a8142d60e4ab4` |
| `tests/native/auto_combat_run.py movement3-src` | **94/94** | `probe-source-result.json` `aa676ff33fca60460fdd96dc4403204431dc602bb60df14e41555990c93e45f9` |
| `tests/native/auto_combat_run.py movement3-dist --addon-archive dist/tome-mcp-bridge.teaa` | **94/94** | `probe-dist-result.json` `8f63519f41af74862adc00e49eaac0b362144f45a729670d07d7417f3beecc77` |
| `tests/native/run.py movement3-accept-src` | **100/100** | `acceptance-source-result.json` `63eb2f35b0321badd88ceafe3f8e01d3bc830571b155515c49270fe87f7bda3d` |
| `tests/native/run.py movement3-accept-dist --addon-archive dist/tome-mcp-bridge.teaa` | **100/100** | `acceptance-dist-result.json` `59c4de6198bb781946fdb72e57e0fa3df67d04e0e8744cd210417d2d14c1c4a8` |

不变量核对（保持）：单次行动机会一个原生动作；尝试/瞬发预算；`native_pending` 不重复提交；手动输入收回租约；owner 仲裁；只读 `dry_run`；确定性 tie-break（无 RNG）；原生裁决最终；场景切换 pause/reset 且需显式重启。

能力缺口（记录为 capability，不视为策略拒绝）：多提示 `target_plan` 执行（`Actions.use_talent` 仅预填一次）；`known_safe` 危险（无权威危险清单，fails closed）；Phase Door TL4/TL5、Blink、Displacement Shield、Vault、Dimensional Step、Shadowstep、Giant Leap 适配器未审计；移动/交换其他 actor 未实现。详见 `docs/tome-mcp-0.9.0-movement-first-tranche.md` §2。

正式包 **67 个生产文件**，SHA-256（baseline `7035d6026488df5e612d72ab4a745bcd2892af25fdfa5f0f2ee7e01282e4c09e` → 本段）：

```text
d4a3affe48c6cee479f69d785533105e9c3470aae32d5b7b3e032670b233c916
```

未处理/延期：独立评审；真实传送技能（探针角色为 Berserker，无传送技能，故仅通过生产 `plan` 路径断言随机落点标注）；多提示 `target_plan` 的原生执行。

## 0.9.0：自动战斗 v2 效果清单（V2-1 … V2-6，rev 4）

日期：2026-09-17。分支 `feat/v2-effect-manifest`（PR #13，head `6485016`）**已合并到 `main`（merge `96ce7a5`）**，执行 `docs/tome-mcp-0.9.0-selffire-investigation.md` §6–§9。执行与 `allow_auto_combat_execution` 仍为关闭。独立评审 V2-REV-01…07 最终 **7/7 PASS（verdict=merge，无新问题）**，报告 sha256 `e85f1cfa77a9cbe38bf5b06617eb4913c5c639858cd1f0f83edfc6fa95f3e170`；rev 2/3/4 逐条修复并各有回归测试。开发对话在最终 head 独立复跑：Lua 全绿（`effect_manifest` 240、`effect_footprint` 24、`effect_risk` 29、`effect_manifest_drift` 30、`auto_combat_guard` 29、`runtime` 171）、Python 39、三个 `--check` 绿、auto-combat 探针 source/dist 各 **79/79**、原生验收 source/dist 各 **100/100**、最终 `dist` sha256 `3d3c57be091c69ba1f9fe60e191495c528c3f8d5dfa74fd910ae3a2b8d3d9a29`。

| ID | 结果 | 证据 |
| --- | --- | --- |
| V2-1 组件清单 | **通过**：`EffectManifest`（`tome-auto-combat-adapters/v2`）为每个技能提供 cursor + instant/projectile/secondary/ground 独立组件、delivery/footprint/SF/FF/player-override、来源（文件+md5+定义行+builder 行）与声明式变体 | `test_effect_manifest.lua`（240）、`tools/generate_effect_manifest.py --check` |
| V2-2 守卫 | **通过**：`AutoCombatGuard` 只从规范组件推导风险；变体用已审计有效技能等级（`getTalentLevel`）；builder 抛出/非表、缺失定义、漂移均 fail-closed（且先于 self/hostile 早退）；每个 entry（含 self）要求活定义 + 声明的 builder 形状；可信 builder 按对象标识（`rawequal`）固定，同原型不同 upvalue（dump 相同、行为不同）也被拒绝且不覆盖基线；缓存成功后变更仍被捕获；D2 不变 | `test_auto_combat_guard.lua`（29）、`test_runtime.lua`（172）、原生 `guard-real-spec` |
| V2-3 footprint 对等 | **通过**：原生探针对真实 `ActorProject:project` 逐格比对 hit/bolt/beam/ball/widebeam/cone + 三返回 `block_path`（bolt/beam 停止、first-step 与 later-step corner），13/13 完全一致；断言方格地图模式；生产守卫报告 `footprint_backend=native` | `v2-rev4-src`、`v2-rev4-dist`（`effect-footprint:*`） |
| V2-4 组合风险 | **通过**：有效投射物 opt-in 为 `typ.player_selffire OR actor.allow_player_selffire`（一方 false 不否决另一方 true）；Flame sub-TL5 为 projectile；Burning Wake 为 duration-4 per-grid 地面；地面 self 需 SF∧FF、友军只需 FF | `test_effect_risk.lua`（29）、`test_auto_combat_guard.lua`（29）、`test_friendly_fire.lua`（40） |
| V2-5 源漂移 | **通过**：生成器固定 20 个技能文件 + 6 个引擎语义文件（含 `ActorTalents.lua`）的 md5、定义行与 builder 行；每个 entry 的 builder 期望显式声明；可信 builder 保留原函数对象并仅接受 `rawequal`（Bytecode 不含 upvalue 值）；只在缓存不可变文件哈希后每次守卫重跑活身份检查，仅在显式会话边界重置基线；同名替换/同原型不同 upvalue/缺失定义/缺 hash 服务均 `adapter_source_drift` | `test_effect_manifest_drift.lua`（30）、原生 `manifest-drift` + `guard-real-spec` mutation |
| V2-6 整体 | **通过**：Lua 全绿、Python 39、三个 `--check` 绿；auto-combat 探针 source/dist 各 79/79；原生验收 source/dist 各 100/100；重新打包 | 下表 |

原生证据：

| 层 | 会话 | 结果 |
| --- | --- | --- |
| Auto-combat 探针（source） | `v2-rev4-src` | **79/79**（含 13 footprint parity + 3 drift + builder mutation） |
| Auto-combat 探针（dist） | `v2-rev4-dist` | **79/79** |
| 原生验收（source） | `v2-rev4-accept-src` | **100/100** |
| 原生验收（dist） | `v2-rev4-accept-dist` | **100/100** |

正式包 **66 个生产文件**，SHA-256：

```text
3d3c57be091c69ba1f9fe60e191495c528c3f8d5dfa74fd910ae3a2b8d3d9a29
```

（rev 3 包 `fce6831aeb718c07546de628dcc230b86781c17a74f3daa6f3c5b96f008506bd`；rev 2 包 `ceb1e3799b827b6d9bc192b9bdb5c3e0407053e10f4e6514260617f793e27518`；rev 1 包 `c96faee23db2b7d218295a97ecc1f728d334483ca4e0c62a5bd7b932ee2f7cbd`；基线 `4e60984fd7d4859db2e1b0f956185348fff5070b7c8e1308b35f658d6d13bd29`。）冻结不变量保持：紧急层、预算、目标绑定、`native_pending`、手动撤销、只读 `dry_run` 不变；无协议/服务端字段变化，仅 `capabilities.adapter_version` 变为 v2。动态技能（Fireflash/Flameshock/Shadow Blast/Starfall）当时留作 TODO #55，**后续已解决，见下节**。详见 [V2 文档](docs/tome-mcp-0.9.0-v2-effect-manifest.md)。

## 0.9.0：四动态技能重新纳入（TODO #55，DYN-1 … DYN-5）

日期：2026-09-17。分支 `feat/v2-dynamic-talents`（PR #14，head `afa6335`）**已合并到 `main`（merge `f4d6c69`）**。独立评审最终 **全 PASS（verdict=merge，无新问题）**，报告 sha256 `1df802aca9718c7f06753f24c1924e40f4ee28b9adc33db276294306d18ce7c1`；开发对话在最终 head 独立复跑：Lua 全绿、Python 39、三个 `--check` 绿、auto-combat 探针 source/dist 各 **88/88**、原生验收 source/dist 各 **100/100**、最终 `dist` sha256 `7035d6026488df5e612d72ab4a745bcd2892af25fdfa5f0f2ee7e01282e4c09e`。`T_FIREFLASH`/`T_FLAMESHOCK`/`T_SHADOW_BLAST`/`T_STARFALL` 从 `EffectManifest.UNSUPPORTED` 移入 v2 组件清单。

| ID | 结果 | 证据 |
| --- | --- | --- |
| DYN-1 源审查 | **通过**：四个技能逐个审查 `target`/action；组件（cursor + instant + ground）与分支记录在 `EffectManifest`；均有 `t.target` builder → `conformance.builder=true` | `test_effect_manifest.lua`（312）、`docs/tome-mcp-0.9.0-v2-dynamic-talents.md` |
| DYN-2 动态输入 | **通过**：`spellFriendlyFire` 由新审计 provider（`guard.spellFriendlyFire`，`Combat.lua` digest+identity+declaration）解析且为**权威值**：builder 的原始 `selffire` 不得覆盖失败的 provider；不可用/被覆盖/报错 → `unknown`（fail-closed）；`radius={from='target'}` 从真实 builder 取值 | `test_auto_combat_guard.lua`（40）、`test_runtime.lua`（173）、原生 `dynamic-talents:provider` |
| DYN-3 地面诚实建模 | **通过**：Burning Wake duration-4（Fireflash 冲击球 / Flameshock `center='self', direction='target'` 的方向性 cone）；Shadow Blast 持续 radius-3 球；Starfall 无地面；地面 FF 默认 true → 持久地面保守拒绝；`map_effect` footprint 使用真实 `Map:addEffect` 几何（含 boolean-true 地形阻挡） | `test_effect_footprint.lua`（30）、`test_effect_manifest.lua`、原生 `dynamic-talents:flameshock-ground-direction` / `map-effect-terrain-parity` |
| DYN-4 注册与漂移 | **通过**：四个 entry 带 builder 行/source 引脚，并加入 `PolicySchema.TALENTS`；`Combat.lua` 纳入引擎引脚；builder 替换/变更仍 `adapter_source_drift` | `test_effect_manifest_drift.lua`（30）、`tools/generate_effect_manifest.py --check` |
| DYN-5 整体 | **通过**：Lua 全绿、Python 39、三个 `--check` 绿；auto-combat 探针 source/dist 各 88/88；原生验收 source/dist 各 100/100；重新打包 | 下表 |
| DYN-REV-01/02/03 | **通过**：动态 provider 权威（builder 不能覆盖 unknown）；range-0 cone 要求绑定目标在原生 instant footprint 内（近允许 / 远、墙阻挡拒绝）；Flameshock 地面 cone 保留瞄准方向 | 见上 |
| DYN-REV2-01 | **通过**：`nativeMapEffect` 传入引擎的 boolean `true`（与真实 `Map:addEffect` 一致，无 `pass_projectile` 豁免）；原生回归用真实 `Map:addEffect` 记录网格，并加入 `block_move=true/pass_projectile=true` 地形差异用例（新/记录 17 格 vs 旧规则 19 格） | `test_effect_footprint.lua`（30）、原生 `map-effect-terrain-parity` |

原生证据：

| 层 | 会话 | 结果 |
| --- | --- | --- |
| Auto-combat 探针（source） | `v2-dynrev3-src` | **88/88**（含 wall + ground-direction + terrain parity） |
| Auto-combat 探针（dist） | `v2-dynrev3-dist` | **88/88** |
| 原生验收（source） | `v2-dynrev3-accept-src` | **100/100** |
| 原生验收（dist） | `v2-dynrev3-accept-dist` | **100/100** |

正式包 SHA-256：

```text
7035d6026488df5e612d72ab4a745bcd2892af25fdfa5f0f2ee7e01282e4c09e
```

（rev 2 包 `1c06737021456a84a29b74aeaa5aaed50e5c467adc5b779e013195158b3413d7`；rev 1 包 `2860a9fbf7c5a54916a75446a4c94ec3751ee45f5c8d4f4379f0b9d7574131f7`；基线 `3d3c57be091c69ba1f9fe60e191495c528c3f8d5dfa74fd910ae3a2b8d3d9a29`。）保留修复：Flameshock（range=0 自中心 cone）不再被 distance/`canProject` 误拒，但绑定目标必须在原生 instant footprint 内（远/墙阻挡拒绝）；`allow_auto_combat_execution` 仍为关闭。无仍不支持的技能（`EffectManifest.UNSUPPORTED` 为空）。详见 [动态技能文档](docs/tome-mcp-0.9.0-v2-dynamic-talents.md)。

## 0.9.0：自动战斗插件 Wave 2（接口/契约）

日期：2026-09-17。修复独立评审的 INT-01 … INT-06 与 SAFE-01（桥接/协议接口层）。Wave 2 在 Wave 1 合入后串行执行；未重做执行安全。执行与 `change_level` 默认仍关闭。

| 检查层 | 结果 | 证据 |
| --- | --- | --- |
| INT-01 协议描述实际接口 | **通过**：`requests.schema.json` 列 14 个 live op + `PolicyArgs`/`PolicyLogArgs`/`detail`/`inspect.kind`/`computed`/`status.compact`；generator 从 `Runtime.dispatch`+MCP tool 推导并双向校验；每 op 代表字段或已声明 gap | `tools/generate_protocol.py --check`、`protocol/v4/requests.schema.json` |
| INT-02 错误契约 | **通过**：75 码注册表为单一来源；生成 Lua/Python envelope；`Runtime.fail`/Python `as_dict` 均补齐 category/scope/recovery；CI 对未注册 emit 码失败；逐条 envelope 过 schema | `protocol/v4/vectors/error-codes.json`、`ErrorRegistry.lua`、`error_registry.py`、`server/tests`（34） |
| INT-03 严格校验器 | **通过**：logging/tie_break/复合条件/动作形状的 union 严格校验 + 负例 | `test_auto_combat_policy.lua`（78） |
| INT-04 CAS 对象 | **通过**：approve=draft、activate=approved；§11.1 与 server 描述修正 | `test_auto_combat_service.lua`（79） |
| INT-05 能力对齐 | **通过**：`auto_explore` 纳入 actions/action_support/native_tasks | `test_runtime.lua`（163） |
| INT-06 get/clear | **通过**：`get` 返回三版本、`clear` 只清 draft；§11 名称冻结 | 同上、`test_auto_combat_service.lua` |
| SAFE-01 getter 审计 | **通过**：有限 computed getter 集经 `NativeCompatibility`（digest+identity+declaration+closure）注册并只经注册表解析；同标签异身份/改文件均 fail-closed | `test_native_compatibility.lua`（16）、`test_actor_combat.lua`（22） |
| 原生 fixture | **通过（35/35，source 与 `dist/*.teaa` 各一次）** | `tmp/tome-mcp-validation/sessions/wave2-final-src/`、`wave2-final-teaa/` |
| 既有套件 | Lua **33 套 / 102,008 checks**、Python **34 通过**、两个 `--check` 生成器绿 | `bash game/addons/tome-mcp-bridge/tests/run.sh` 等 |

正式包 **60 个生产文件**，SHA-256：

```text
c5c94255012daee3818be0f86c91e8aa04f7b02e1f43589c2dd1a179dec259c0
```

四项决定（INT-04/05/06、SAFE-01）与 D7–D12 见 [Wave 2 文档](docs/tome-mcp-0.9.0-wave2-interface-contract.md)。

## 0.9.0：自动战斗插件 Wave 1（执行安全）

日期：2026-09-17。修复独立评审确认的 AC-01 … AC-10（执行层安全），全部在**生产路径**上验证（真实 `Actions.execute` → 映射/主机），不再靠伪造 `{status=...}`。执行与 `change_level` 默认仍关闭。

| 检查层 | 结果 | 证据 |
| --- | --- | --- |
| AC-01 `native_pending` | **通过**：映射先于成功分支；真实 `Actions.execute` 挂起根 → `native_pending`；`nativePhase` 跟踪活动根；`resume` 拒绝未结算 | `test_auto_combat_execution.lua`（10）、`test_auto_combat_controller.lua`（76） |
| AC-02 资源读取 | **通过**：标量 `value`+`min_`/`max_`+解锁门控；资源日志不再变 nil | `test_runtime.lua`（156）、原生 `production-reads` |
| AC-03 安全 adapter | **通过**：版本固定 guard 在实际绑定目标上判定射程/`canProject`/几何/自伤/友伤；`max_selffire_risk==0` 硬拒绝、`>0` 暂停；emergency 任意 talent 但由 guard 把关 | `test_runtime.lua`、controller 76 |
| AC-04/05/D6 边界与阈值 | **通过**：无敌人→危急→常驻；未知 HP 暂停；`min_resource_pct` 门控；`flee_below_hp_pct` 独立暂停 | controller 76 |
| AC-06 瞬发预算 | **通过**：`no_energy` + 观测能量差分类；按行动机会计数与封顶 | `test_auto_combat_execution.lua`、controller 76 |
| AC-07 单机抑制 | **通过**：`hasControl` 含 auto-combat 租约/活动 | `test_runtime.lua`、原生 `production-reads` |
| AC-08/09 生命周期 | **通过**：替换激活作废旧代际；`start` 重新获取租约（stop/无敌人/manual 后可重启） | `test_auto_combat_service.lua`（71） |
| AC-10 `change_level` | **通过（移除）**：从 auto-combat schema/目录/能力声明移除，作为后续阶段 | `test_auto_combat_policy.lua`（68）、`test_auto_combat_catalog.lua`（34） |
| 原生 fixture | **通过（35/35，source 与 `dist/*.teaa` 各一次）** | `tmp/tome-mcp-validation/sessions/wave1-final-src/`、`wave1-final-teaa/` |
| 既有套件 | Lua **33 套 / 101,979 checks**、Python **33 通过**、两个 `--check` 生成器绿 | `bash game/addons/tome-mcp-bridge/tests/run.sh` 等 |

正式包 **59 个生产文件**，SHA-256：

```text
bc9aab70df72a5b7b2565f93b109c290adbc4f222ca23837927137a75e431688
```

四项决定与映射见 [Wave 1 文档](docs/tome-mcp-0.9.0-wave1-execution-safety.md)；未修项见 [TODO](docs/tome-mcp-0.9.0-auto-combat-todo.md)。Wave 2（协议/接口）未开始。

## 0.9.0：自动战斗插件 P2.5（tooltip-safe getters）

日期：2026-09-17。把玩家面板/悬浮可见的 getter 接入谓词层。仍为只读审计；无 RNG、无目标特定解析；执行与 `change_level` 默认关闭。

| 检查层 | 结果 | 证据 |
| --- | --- | --- |
| `computed` 有限枚举 | **通过**：`{field,cmp,value}` 数值比较；`PolicySchema.COMPUTED_FIELDS` = `ActorCombat.computed` 面板路径（含 12 种伤害类型的 resists/penetration/affinity/increase）；任意路径被拒；getter 覆盖/缺失→`unknown` | `test_auto_combat_policy.lua`（68）、`test_actor_combat.lua`（22） |
| `has_effect` | **通过**：`who ∈ {self,target}`，target 为动作绑定的同一目标；有界可见效果列表扫描；缺失/截断→`unknown` | `test_auto_combat_policy.lua`、`test_auto_combat_snapshot.lua`（25） |
| `ally_count` | **通过**：有界可见友方/中立 `allies()`；无读取→`unknown` | 同上 |
| 动态提示文本 | **通过（文档化）**：不作为谓词、不自动鉴定；信息性纯描述读取（需绊线）本片不启用 | 设计 §5.6/§8、[P2.5 文档](docs/tome-mcp-0.9.0-p2.5-tooltip-getters.md) |
| capabilities | **通过**：`capabilities.auto_combat.computed_fields` 暴露枚举 | `Runtime.lua` |
| 原生 fixture | **通过（31/31，source 与 `dist/*.teaa` 各一次）**：新增 `computed-predicate` 场景 | `tmp/tome-mcp-validation/sessions/p25-check-01/`、`p25-teaa-01/` |
| 既有套件 | Lua **32 套 / 101,928 checks**、Python **33 通过**、两个 `--check` 生成器绿 | `bash game/addons/tome-mcp-bridge/tests/run.sh` 等 |

正式包 **59 个生产文件**，SHA-256：

```text
592a1a4685f3aad99e26ffd7373035ed5f79a1881ced191179b183ea49458dd1
```

未修项（信息性纯描述读取、`most_dangerous`-by-`computed`、`cluster_center`/AoE、`map_frontier`/`turn_parity`）见 [TODO](docs/tome-mcp-0.9.0-auto-combat-todo.md)。

## 0.9.0：自动战斗插件 P3 首片（assistant 适配器）

日期：2026-09-17。**只生成、人工确认**：把固定版本的旧自动技能助手配置翻译为自动战斗策略草稿。从不执行 assistant 逻辑、从不 approve/activate/start；执行与 `change_level` 默认仍关闭。

| 检查层 | 结果 | 证据 |
| --- | --- | --- |
| 固定版本/格式 | **通过**：`tome-auto_talent_assistant` 2.3.9 / ToME 1.7.4 / 导出格式 `tome-auto-combat-assistant-export/v1`；版本、格式、addon、缺失 assistant 均明确拒绝 | `tests/test_auto_combat_assistant.lua`（44） |
| 纯翻译器 | **通过**：`AssistantAdapter.detect/translate` 无引擎访问、确定性；生成草稿通过 `PolicySchema`+`AutoCombatCatalog` | 同上、fixtures |
| 不支持项记录 | **通过**：不支持 talent/action/sustain/字段/条件以 warnings/unsupported 返回，不静默丢弃；无可用规则返回 `no_supported_rules` | fixtures `tests/fixtures/assistant/` |
| MCP 路径 | **通过**：`tome.policy policy_op=import_assistant` 只产出草稿；`store=true` 才写 draft（control-only，observe 拒绝）；从不 approve/activate/start | `test_runtime.lua`（145）、`server/tests` |
| 原生 fixture | **通过（27/27，source 与 `dist/*.teaa` 各一次）**：新增 `assistant-import` 场景 | `tmp/tome-mcp-validation/sessions/p3-check-01/`、`p3-teaa-01/` |
| 既有套件 | Lua **32 套 / 101,901 checks**、Python **33 通过**、两个 `--check` 生成器绿 | `bash game/addons/tome-mcp-bridge/tests/run.sh` 等 |

正式包 **59 个生产文件**，SHA-256：

```text
d16433cbc93b38fa20df37da8e0b6d232473c06b17e9e2e838caf0579bc66bfb
```

映射决定与排除项见 [P3 设计/状态](docs/tome-mcp-0.9.0-p3-assistant-adapter.md)。P3 为长期维护项，本片为有界首片。

## 0.9.0：自动战斗插件 P2（调优）

日期：2026-09-17。在审计过的只读字段上增加一批谓词/选择器、可回放的决策追踪、A/B 调参器与第二个职业 pilot。仍为 data-only；执行与 `change_level` 默认关闭。

| 检查层 | 结果 | 证据 |
| --- | --- | --- |
| 新谓词/选择器 | **通过**：`enemy_rank`/`enemy_level`/`enemy_type`/`enemy_is_elite`/`enemy_is_boss`/`enemy_distance` + `highest_rank_hostile`/`most_dangerous_hostile`；schema+catalogue+evaluator+snapshot 均有测试；目标相关条件按 action selector 求值 | `test_auto_combat_policy.lua`（52）、`test_auto_combat_snapshot.lua`（21）、`test_auto_combat_catalog.lua`（33） |
| 决策回放 | **通过**：新增只读 `tome.policy policy_op=replay`（`after_seq`/`limit`）按旧→新分页返回 §10 追踪 + run header；observe 仍有限，日志仍为内存运行态 | `test_auto_combat_service.lua`（61）、`test_runtime.lua`（137）、`server/tests` |
| A/B 调参 | **通过**：`tests/auto_combat_ab.lua` 固定 4 场景对比 baseline（`anorithil_p1a`）与 tuned（+boss 规则）；仅 `boss-visible` 分歧（`ray/nearest` → `boss/most_dangerous`），安全路径不变 | `validation/2026-09-17-auto-combat-p2/ab-report.json` |
| 第二职业 pilot | **通过**：半身人/太阳圣骑士 `sun_paladin_p2`（`T_SUN_BEAM`/`T_WEAPON_OF_LIGHT` 新 adapter）；原生 probe 新增 `sun-paladin-preset`（schema+目录+真实快照 dry_run） | `test_auto_combat_io.lua`（20）、`tests/native/...` |
| 原生 fixture | **通过（21/21，source 与 `dist/*.teaa` 各一次）** | `tmp/tome-mcp-validation/sessions/p2-check-01/`、`p2-teaa-01/` |
| 既有套件 | Lua **31 套 / 101,849 checks**、Python **33 通过**、两个 `--check` 生成器绿 | `bash game/addons/tome-mcp-bridge/tests/run.sh` 等 |

正式包 **58 个生产文件**，SHA-256：

```text
76b2ea636dcc0c5dbfee990bb35584eb019826a165eaef02f6f3c9a241559fd0
```

P2 范围决定（含显式排除项）见 [P2 设计/状态](docs/tome-mcp-0.9.0-p2-tuning.md)；未修项见 [TODO](docs/tome-mcp-0.9.0-auto-combat-todo.md)。

## 0.9.0：自动战斗插件 P1b（原生活动）

日期：2026-09-17。把 `rest` / `auto_explore` 变为数据策略的一等动作，抽出通用 `NativeActivity`；`change_level` 仍为显式 opt-in 且默认关闭。执行仍由 `allow_auto_combat_execution` 门控（默认关）。

| 检查层 | 结果 | 证据 |
| --- | --- | --- |
| `NativeActivity` 抽象 | **通过**：新增 `overload/mod/mcp_bridge/NativeActivity.lua`；`Runtime` 的 `nativePhase`/`busy`/`revoke`/`settle`/rest 回调/dialog ownership 全部委托，不再按 action.type 分支 | `tests/test_native_activity.lua`（17）、`tests/test_tasks.lua`（65） |
| `rest` / `auto_explore` 策略动作 | **通过**：schema + capability catalogue + evaluator（`max_turns`）+ 执行器 adapter；控制器复用 `native_pending` 等待语义；活动存活期间不重提、交互即暂停 | `test_auto_combat_policy.lua`（38）、`test_auto_combat_controller.lua`（57）、`test_auto_combat_catalog.lua`（30） |
| `change_level` opt-in | **通过**：`permissions.change_level=true` 才通过 schema/目录校验，内置预设不启用 | `test_auto_combat_policy.lua`、`test_auto_combat_catalog.lua` |
| 原生 P1b fixture（含预声明信号） | **通过（17/17，source 与 `dist/*.teaa` 各一次）**：`rest-policy`（数据策略驱动真实原生 rest：`wait_native`→`stopped`）、`explore-policy`（原生 `enemies_in_sight` 守卫生效并声明） | `tmp/tome-mcp-validation/sessions/p1b-check-06/`、`p1b-teaa-01/` |
| 既有套件 | Lua **30 套通过**、Python **33 通过**、两个 `--check` 生成器绿 | `bash game/addons/tome-mcp-bridge/tests/run.sh` 等 |

正式包 **58 个生产文件**，SHA-256：

```text
420eaedaf567d6dd30e107a0c1572ed056206ddac8f0561ce88ab2841ebbdedb
```

§16 三项未决已解决并于 [TODO](docs/tome-mcp-0.9.0-auto-combat-todo.md) 记录；设计见 [P1b 设计](docs/tome-mcp-0.9.0-p1b-native-activity.md)。

## 0.9.0：自动战斗插件 P1a（首个可用闭环）

日期：2026-09-16。数据-only 战斗策略由原生执行器逐回合本地执行；MCP 只观察/校验/仲裁。人类可用游戏内编辑器独立使用（无需 MCP 客户端）。

| 检查层 | 结果 | 证据 |
| --- | --- | --- |
| 游戏内 UI（无 MCP） | **通过**：Ctrl+G 打开 `Auto-combat policy` 对话框、Esc 关闭；Ctrl+Shift+G 在未加载预设时优雅返回 `not_activated`；无 Lua 错误 | `tmp/tome-mcp-validation/sessions/agent-ham-insane-31/`、`validation/2026-09-16-auto-combat/ui-verification-round31.json` |
| 原生 §14 fixture（预声明暂停原因） | **通过（13/13）**：start-when-ready、pause→resume 丢弃旧决策、native_pending 不重提、危急态不输出普通规则、strict resume、无 MCP 单机 pump 执行真实原生动作 | `validation/2026-09-16-auto-combat/native-fixture-summary.json` |
| 实机 playtest（Insane Anorithil） | **通过**：94 条决策（melee/ray/finish/heal/sustain 均真实原生生效），暂停仅 `new_enemy`/`no_emergency_action`，无 bridge `native_error`、无租约丢失、无卡 `settling` | `tmp/mcp-play-support/agent-ham-insane-27-report.md`、`validation/2026-09-16-auto-combat/playtest-round27-summary.json` |
| playtest 修复复验（引擎内） | **通过**：auto_combat 持租约时远程 `act` 返回 `control_conflict`；`connect control` 原子接管后 `act` 恢复；无规则命中的 hold 变为 `no_available_action` 停止并记日志 | `validation/2026-09-16-auto-combat/fix-verification-round28.json` |
| 实机 playtest round 2 | **通过**：两个 P0 均复验通过（`no_available_action` 停止交还 manual；`control_conflict`+`connect_explicitly` 互斥生效）；新增预设显式 `recover` wait 规则解决冷却期频繁停止 | `tmp/mcp-play-support/agent-ham-insane-32-report.md`、`validation/2026-09-16-auto-combat/playtest-round32-summary.json` |
| `dry_run` 规划级求值（本次收尾） | **通过**：`tome.policy policy_op=dry_run` 返回 decision/rule/action/talent/bound_target/critical/layer/`results` 轨迹/暂停原因与 snapshot 元数据；`executed=false`、`side_effects=none`，执行器零调用；执行默认关闭时可用，observe 连接可用，写策略仍被拒 | `test_auto_combat_service.lua`（52）、`test_runtime.lua`（135）、`server/tests/test_server.py`（33） |
| 既有套件 | Lua **29 套通过**、Python **33 通过**、`generate_protocol.py --check` 与 `generate_native_seams.py --check` 绿、原生套件 **100 通过** | `bash game/addons/tome-mcp-bridge/tests/run.sh` 等 |

正式包 **57 个生产文件**，SHA-256（dry-run 收尾包）：

```text
ea3c9f71ae6c6b8039445cce5d9bfda2889df0a3c7a68c484033a567a18a9487
```

> 上一版（P1a 首包，rounds 1–2）SHA-256：
> `ea15541bdefb8c565f8a9afaaca4ac70cd211c398d3bfe0f9c193f3c418ae30e`。

设计正文见 [自动战斗插件设计](docs/tome-mcp-auto-combat-plugin-design.md)；反馈与未修项见 [round1](docs/tome-mcp-0.9.0-auto-combat-round1-feedback.md)、[round2](docs/tome-mcp-0.9.0-auto-combat-round2-feedback.md) 与 [TODO](docs/tome-mcp-0.9.0-auto-combat-todo.md)；dry-run 收尾与 §15/§15.1 审计见 [P1a 收尾](docs/tome-mcp-0.9.0-p1a-dry-run.md)。执行仍由 `allow_auto_combat_execution` 门控（默认关）。

## 0.8.0：协议 v3 技能查询/目标预填与原生洗点

日期：2026-09-15。本版只保留协议 **v3**（v1/v2 已在测试阶段移除）：只读技能查询（射程、基础与实时消耗、冷却、条件/可用性提示）与一次性目标预填（actor/position）；新增原生 `unlearn_talent`（仅退还原生 `last_learnt_talents` 窗口内、非战斗、非 item 授予/保护的技能点）。核心游戏文件未修改，原生插入点未变。本版经独立 agent 验收，发现并修复预填绕过原生射程（F-1）与带魔像角色被拒绝成长（F-2），并补充实时消耗（`current_costs` + `base_costs`，F-3），随后复验通过。

| 检查层 | 结果 | 证据 |
| --- | --- | --- |
| Lua 单元 | **896 项通过**（Actions 65、Talent query/prefill 46、Progression 231、Interactive Runtime 70） | `bash game/addons/tome-mcp-bridge/tests/run.sh` |
| Python / 官方 SDK | **26 个测试通过** | `server/tests/` |
| 原生 v3 查询（含实时消耗） | **通过（78 项，0 硬失败）**：动态 range/requires_target/target 标 `unknown`；纯度探针 0 次 RNG/preUseTalent/info/canSee；`distance`/`in_range`/冷却/可用性与实测一致；`current_costs` 为实时值（`T_LIGHTNING` mana 基础 10 → 实时 12.4，与实测扣费一致），`base_costs` 为基础值，`costs_complete` 标明完整性 | `tmp/tome-mcp-validation/sessions/mcp-v3only-02/result.json` |
| 原生 v3 预填（含 F-1） | **通过**：静态越程在动作开始前拒绝（`target_out_of_range`，0 能量）；动态射程在第一次 `getTarget` 处校验，越程/自我警告回退原生目标提示；只在第一次 `getTarget` 消费一次并恢复；不使用 `target.forced` | 同上 |
| 原生 `respond` 射程 | **通过**：`target.grid` 越程返回 `position_out_of_range`，射程内正常提交 | 同上 |
| 原生 respec（含 F-2） | **通过**：窗口内学习/退还 1 点、点池与面板一致、保存副本重载保留；窗口外 `talent_not_recently_learnt`、战斗中 `respec_in_combat` 拒绝；单元覆盖带 `alchemy_golem` 角色不再被拒绝 | 同上 |
| 原生 v3 套件 | **native 100/100、interactions 94/94**（均为协议 3，信封 `v=3`） | `tmp/tome-mcp-validation/sessions/mcp-v3only-native-03`、`mcp-v3only-interactions-01` |

正式包 **36 个生产文件**，SHA-256：

```text
7a183788dd63284f65807065e06e9bf80a7e53c707fe94cd21180bf2703be6df
```

已知限制：

- **F-4（信息）**：未解析的 `target_id` 在命令记录生成后、原生体之前返回 `target_lost`（0 能量），功能正确。
- `current_costs` 仅在基础消耗为静态数值且原生 `alterTalentCost`/`cost_factor` 未被改写时给出实时值；动态基础消耗对应项为 `unknown` 且 `costs_complete=false`。计算实时值会调用原生 `cost_factor`（可能读取只读疲劳 getter），不消耗 RNG、不改变状态。

本版只保留协议 v3：移除了 v1 白名单适配与 v2/v3 分支（`atLeast`），TCP 信封 `v` 固定为 3，`tome.connect` 不再接受 `protocol_version`；同时对返回字段做了统一重命名（`current_costs`、`control_source`、顶层 `truncated`、`point_cost`、`readiness_reason`、`requirements_are_raw`、`combat_values_are_raw`、`speed_values_are_raw`、`required_level`；移除 `costs_are_final`、`query_is_final`、`readiness_is_final`、`map_omitted`、`observation_truncated`）。字段清单见 [API 字段](docs/tome-mcp-api-fields.md)。

respec 原生验收使用隔离新角色，不是既有长期战役存档副本；未触碰用户原存档。以下为历史验收记录。

## 0.7.0：原生 Chat、护送奖励与告别

日期：2026-09-15。正式包 36 文件，SHA-256 `23e34185c3be9c465079bf71626e072fd53f71faa8ea382dec3a5f71f8a9b196`。Chat 沿实际可见选项和原生 `use` 继续；连续页、NPC 回合、换层租约恢复、加载窗口和自动保存纳入同一命令生命周期。

| 验收层 | 最终结果 | 证据 |
| --- | --- | --- |
| Lua / Python | **912 / 25 项通过** | [Lua](validation/2026-09-15-chat/lua-tests.log)、[Python](validation/2026-09-15-chat/python-tests.log) |
| 原生 v1 / v2 三插件组合 | **100 / 96 项通过** | [v1](validation/2026-09-15-chat/v1-result.json)、[v2](validation/2026-09-15-chat/v2-result.json) |
| 原生 Chat 专项及未修改的先知奖励脚本 | **41 项通过** | [Chat](validation/2026-09-15-chat/fixture-result.json) |
| 普通存档自然护送与重载 | **87 项，63 次动作全部 completed** | [自然护送](validation/2026-09-15-chat/natural-result.json) |
| 最新 6 级存档升级加载与重载 | **5 项通过** | [6 级存档](validation/2026-09-15-chat/lv6-result.json) |

五组最终原生运行均使用同一正式包。自然护送从已发布 0.6.0 的 Lv5 世界地图副本开始；lost warrior 的开场、Strength +5 奖励、Thank you 告别全部使用 MCP。奖励来自已经完成的向南移动，重复请求不重放移动或奖励，保存重载保留 +5。另用原生 `escort-quest.lua` / `EscortRewards` 的明确 fixture 验证先知 Willpower +5。最新 0.6.1 的 Lv6 Kor'Pul2 存档独立复制加载，原有意志奖励不重做。

历史 **126,350 文件**哈希未变。早期生产缺陷、驱动错误、随机未触发护送和 NPC 战死等失败均保留；完整说明见 [0.7.0 交付](docs/tome-mcp-chat-0.7.0.md)、[冻结汇总](validation/2026-09-15-chat/summary.json) 和 [复现方法](tests/chat/README.md)。本轮没有完成整场战役，交付后按用户要求暂停。以下历史记录原文保留。

## 0.6.1：世界地图可见地形与入口

日期：2026-09-15。正式包 34 文件，SHA-256 `7df97a9121ac75470436f48c136dbe366f12b083688f0c508d1c86e367e7af0e`。沿经源码校验的原生世界地图 `applyLite` 可见缓存修复漏报；地牢 `infovs`、ESP 和失明保护保留，核心游戏代码未改。

| 验收层 | 最终结果 | 证据 |
| --- | --- | --- |
| Lua / Python | **876 项 / 25 项通过** | [Lua](validation/2026-09-15-worldmap/lua-tests.log)、[Python](validation/2026-09-15-worldmap/python-tests.log) |
| 原生 v1 与存档重载 | **100 项通过** | [结果](validation/2026-09-15-worldmap/v1-result.json) |
| 原生 v2 三插件组合 | **96 项通过** | [结果](validation/2026-09-15-worldmap/v2-result.json) |
| 普通世界地图存档、导航、实际断线重连与副本重载 | **34 项通过** | [结果](validation/2026-09-15-worldmap/campaign-result.json) |

三组最终原生运行使用同一正式包。v1/v2 均包含九项独立的原生感知检查；fixture 不进入普通战役或生产包。普通运行直接复制已发布的 `campaign-play-v060-02` 5 级世界地图存档，七份存档文件及前序来源链均校验。初始 625 格中可见 39 格、未知 586 格；移动后可见 50 格、累计已知 51 格。仅凭 MCP 地图完成 10 次移动和 2 次原生换层，全部 completed；在 Trollmire 入口 `(28,13)` 满生命、满体力保存，复制重载后当前可见格仍为 39。未完成整场战役。

首个普通尝试进入 Kor’Pul 后遇到不支持的护送聊天，换场已发生且执行占用仍保留；该失败保留，未重放或人工绕过。通过的往返验收改用已探索的 Trollmire；不据此宣称支持护送聊天。两个早期原生 fixture 设置错误及修复过程也保留在 [汇总](validation/2026-09-15-worldmap/summary.json)。

历史 **101,019 文件**哈希未变。[本版冻结安装包](validation/2026-09-15-worldmap/tome-mcp-bridge.teaa)、[交付说明](docs/tome-mcp-worldmap-0.6.1.md)、[复现说明](tests/worldmap/README.md)。以下历史验收原文保留。

## 0.6.0：原生剧情说明与通用物品激活

日期：2026-09-15。Bridge / Python server **0.6.0**，ToME **1.7.6**。针对 [0.5.0 普通战役反馈](docs/mcp-campaign-continuation-0.5.0.md) 实现并验收；保留原生调用、执行占用与回执模型。核心游戏代码未修改。

| 检查层 | 最终结果 | 冻结证据 |
| --- | --- | --- |
| Lua 回归，使用原生引擎相同的 JIT 优化等级 2 | **864 项通过** | [日志](validation/2026-09-15-native-ui/lua-tests.log) |
| Python / 官方 MCP SDK | **25 个测试通过** | [日志](validation/2026-09-15-native-ui/python-tests.log) |
| v2 正式包 + Battle Companion / Danger Alert | **95/95 项** | [结果](validation/2026-09-15-native-ui/v2-result.json) |
| v1 正式包全部原生回归 | **99/99 项** | [结果](validation/2026-09-15-native-ui/v1-result.json) |
| 原等级 3 普通存档副本，自然战斗与奖励 | **51/51 项，91 次 act 全部 completed，8 个说明窗口** | [结果](validation/2026-09-15-native-ui/campaign-result.json) |
| 自然击杀后的人工接管恢复 | **10/10 项**，Prox QuestPopup，经验不重复 | [结果](validation/2026-09-15-native-ui/kill-handoff-result.json) |
| 自然拾取后的人工接管恢复 | **10/10 项**，关闭后仍只有一根 Rod | [结果](validation/2026-09-15-native-ui/pickup-recovery-result.json) |
| 原生保存的独立副本重载 | **5/5 项**，等级、经验、物品和 Recall 效果保留 | [结果](validation/2026-09-15-native-ui/reload-result.json) |

以上六个原生运行均使用相同最终 `.teaa`，**34 个生产文件**，包内逐字节匹配当前源码：

```text
a3bd05bd4968c51dabc25ab8602c5c188e779bbec05f735502d743e15b17a363
```

见 [正式包](dist/tome-mcp-bridge.teaa)、[冻结 manifest](validation/2026-09-15-native-ui/manifest.json)、[输入、结果与哈希汇总](validation/2026-09-15-native-ui/summary.json) 和 [0.6.0 交付说明](docs/tome-mcp-native-notices-items-0.6.0.md)。Python 冻结源码与当前 0.6.0 相同；验证环境也已重新安装，代码版本与安装元数据均为 0.6.0。

### 自然奖励的具体回归

`native-ui-campaign-package-final-02` 从历史 `campaign-play-v030-01` 原始等级 3 存档的新副本开始。没有 gameplay probe、直接改属性、授予技能、生成奖励或全图观察。先通过 MCP 花费角色已有成长点，沿当前可见地图作战、取得并装备真实掉落的铁质巨锤，再原生击败 Prox，升至 5 级。

| 原生触发 | 最终运行命令 | 原生窗口及处理 |
| --- | --- | --- |
| 普通攻击击杀 Prox | notice-82 | QuestPopup，奖励已生效，回答关闭后原命令完成 |
| 移到掉落格 | notice-83 | Rod of Recall、Silk Current、Coral Spray 三个 LorePopup，按实际栈顶逐层关闭 |
| 拾取纸条 | notice-84 | Hidden treasure 的 QuestPopup、simplePopup、LorePopup 三层，仍属一次拾取 |
| 拾取 Rod of Recall | notice-85 | simplePopup，回答前 Rod 已在背包 |

自然掉落类在实际源码中是 **LorePopup**；ShowLore 是收藏目录，其原生关闭另由专项场景覆盖。只暴露对应原生 EXIT 回调；不按文字猜测窗口、不清空窗口栈。动作内登记的原生回合末回调继承归属；无归属或未知 UI 仍移交玩家。

每层检查重复 act 不重放奖励，重复 respond 不重复关闭，实际栈顶顺序和 sequence 单调递增。人工接管分支另在自然 Prox 击杀及真实 Rod 拾取后执行 stop、原生 Escape、显式重连；旧记录继续为 needs_input，执行占用释放，经验和物品没有重复增加。BC 始终 idle / actions=0。

### 通用物品与原生边界

专项场景使用明确的测试物品验证 use_power 两次目标输入、取消不扣充能、一次完整使用扣充能和 1000 能量、重复请求不重复消耗、未穿戴拒绝、use_simple 消耗品移除、use_talent 物品的原生目标和充能处理。此类 fixture 不进入生产包，也不代替自然物品证据。

普通战役最终以通用 use_item 激活自然获得的 Rod of Recall，原生扣充能、耗能并产生 Recall 效果。安全保存时角色等级 5、生命 **209.75/209.75**，Trollmire 3 **(2,5)**；保存副本重载后仍保留 **39 回合 Recall**，新 session 没有旧调用，旧 command_id 返回 unknown_command。本轮验证激活及持久化，没有执行完后续 40 回合传送，也没有完成整场战役。技能本身连续多问由专项场景覆盖；普通战役的多层奖励窗口不等同于技能连续目标问题。

原有目标、方向、确认、列表、库存、任务、取消、保存延期、接管、断线及错误隔离回归继续通过。专项场景末尾的 mcp-expected-after-resume-error 为预期故障注入；没有非预期原生 Lua 错误。UTF-8 长说明截断有边界测试；只读守卫继续验证无额外 RNG、感知、预检、动态说明或物品命名回调。

### 证据保护与失败试验

全部历史及 0.5.0 实战证据在修改前冻结；最后校验 **75,740 个文件全部不变**，包含三轮历史存档、报告与原始运行资料。见 [保护检查](validation/2026-09-15-native-ui/historical-check.json)。新增测试只操作各自独立副本；原生产 0.5.0 另完整备份在 tmp/tome-mcp-native-ui-implementation/baseline-0.5.0.zip。

早期脚本失败及两次自然战斗死亡完整保留在 native-ui-campaign-01 至 -09；它们不算验收通过。修正内容包括读档后敌人／掉落位置变化、换层重连、原生方向回答及相邻纸条拾取。一次同时启动测试导致 Xvfb 显示号冲突，已改用错开启动；它不作为 MCP 断线恢复的产品证据。系统 LuaJIT 默认优化等级 3 下，反复替换虚拟类环境的物品单测出现间歇失败；对齐原生 pre-init 的等级 2 后诊断 **30/30** 通过，完整 Lua 回归通过。诊断原文见 [记录](validation/2026-09-15-native-ui/items-cli-jit-diagnostic.json)。

复现：[自然奖励与接管](tests/notices/README.md)、[原生专项](tests/interactions/README.md)、[v2 契约](docs/tome-mcp-v2-interactions.md)。完整 MCP 调用、原生日志和存档仍在汇总列出的各 session；冻结目录保存精简的结果、输入、测试日志与校验值。

以下保留历史交付记录；其中版本、哈希和限制适用于当时交付，dist 链接指向当前版本。

## 0.5.0：通用原生技能交互

日期：2026-09-15。Bridge / Python server **0.5.0**；ToME **1.7.6**。新增显式协议 v2，默认 v1 保持兼容。相关核心引擎文件未修改；生产 addon 内的生成插入点在打包前通过原生源码一致性检查。

| 检查层 | 结果 | 证据 |
| --- | --- | --- |
| Lua 回归 | **849 项通过**，含调用生命周期 21 项及交互状态机 38 项 | [日志](validation/2026-09-15-interactions/lua-tests.log) |
| Python / 官方 MCP SDK | **24 个测试通过**，含严格回答 schema、旧协议、超时回执与不重发 | [日志](validation/2026-09-15-interactions/python-tests.log) |
| v2 真实游戏，冻结源码 | **73/73 项** | [结果](validation/2026-09-15-interactions/source-result.json) |
| v2 真实游戏，正式包 | **73/73 项** | [结果](validation/2026-09-15-interactions/package-result.json) |
| v2 + BC 0.1.1 + Danger Alert 1.3.1 正式包 | **77/77 项**，包含人工移交后的执行占用阻止助手启动 | [结果](validation/2026-09-15-interactions/three-addons-result.json) |
| 正式包 v1 全部原生回归 | **99/99 项** | [结果](validation/2026-09-15-interactions/v1-result.json) |
| 正式包自然 Lv3 存档成长、物品和重载 | **92/92 项，52 次动作请求**，两份历史存档保持不变 | [结果](validation/2026-09-15-interactions/growth-result.json) |

v2 原生场景实测 Rush、高等级 Phase Door 两次选择、Precise Strikes 开／已开 no-op／关、Fearless Cleave 方向输入、自我目标警告、原生确认和分页列表、两类物品选择、嵌套调用及能量已消费后的挂起。Catapult Trap 第二问取消后仍保留已放置陷阱。Refit Golem 按原生计数等待 **21 步**、消耗 **15 颗宝石**并复活魔像；实测 Refit 等待中被新出现的敌人打断、不复活且不消耗宝石；另测停止、**1000 步**预算及任务结束回调继续提问。

保存验收从挂起输入开始，证明文件在输入未解决前不变，完成原生人工取消后实际保存；加载该保存的独立副本建立新 session，旧协程和命令不恢复，新的交互仍可执行。只读守卫覆盖 observe / inspect、交互和任务描述，无额外 RNG、原生感知、预检或物品命名回调。

验收中修复了 Dialog 提前缓存导致注册缺失、原生自我警告保留 target_co 的归属判断、延迟保存后缺少下一次调度、排队回答遇到死亡／场景变化的边界处理，以及挂起状态误报 native_rejected。取消、stop、断线、人工接管分别保留其语义；错误不声称回滚。

原生场景使用隔离测试角色及 probe，最后一项有意在恢复后扣 5 mana 并抛 `mcp-expected-after-resume-error`，验证 uncertain、写隔离与已应用回执；对应 `##Use Talent Lua Error## T_MCP_TEST_ERROR` 为预期诊断。没有非预期 Lua 错误。自然成长回归使用原真实等级 3 存档副本，`cheat=false`、无 gameplay fixture；BC 保持 idle / actions=0。

正式包：[dist/tome-mcp-bridge.teaa](dist/tome-mcp-bridge.teaa)，**28 个生产文件**，SHA-256：

```text
8e9bf95bc39761cdca28f19ee6a6ea8eabc51dc5bb2603a821585cf6dfa5ec1c
```

包内文件逐字节匹配源码验收候选及当前源码；各正式包运行的冻结副本均匹配该 SHA。见 [冻结 manifest](validation/2026-09-15-interactions/manifest.json)、[结果与证据哈希](validation/2026-09-15-interactions/summary.json)、[复现说明](tests/interactions/README.md) 和 [v2 契约](docs/tome-mcp-v2-interactions.md)。

能力表示可尝试通用原生入口及已覆盖的输入提供方，不代表所有技能、自定义 UI 或任意插件组合都能全自动执行。库存选择限当前原生筛选／页签；其他界面和无可识别恢复入口的裸 yield 仍需人工处理或重新加载。单技能实例可有部分效果，后续错误与取消不会撤销它们。本轮没有完成整场战役。

以下保留历史记录；旧版“当前包”与限制只适用于当时版本。

## 0.4.0：角色成长、自然物品与存档重载

日期：2026-09-15。Bridge 与 Python server 均为 **0.4.0**，配合 Battle Companion **0.1.1**、Danger Alert **1.3.1**；ToME 1.7.6、Linux/LuaJIT、Xvfb、软件 OpenGL。

| 检查层 | 最终结果 | 证据 |
| --- | --- | --- |
| MCP Lua | **790 项通过** | [单元日志](validation/2026-09-15-growth/lua-tests.log) |
| Python MCP | **19 个测试通过** | [单元日志](validation/2026-09-15-growth/python-tests.log) |
| 成长驱动来源/保存比较 | **16 个测试通过** | [单元日志](validation/2026-09-15-growth/growth-driver-tests.log) |
| 自然 Lv3 角色，冻结源码 | **91/91 项，76 个唯一动作请求** | [结果](../../../tmp/tome-mcp-validation/sessions/growth-source-final-01/result.json) |
| 自然 Lv3 角色，正式包 | **92/92 项，73 个唯一动作请求** | [结果](../../../tmp/tome-mcp-validation/sessions/growth-package-final-01/result.json) |
| 正式包完整原生回归 | **99/99 项通过** | [结果](../../../tmp/tome-mcp-validation/sessions/growth-native-package-final-01/result.json) |
| 三插件正式包互操作 | **35/35 项通过** | [结果](../../../tmp/tome-mcp-validation/sessions/growth-control-package-final-01/companion-result.json) |

两个成长验收都复制 `campaign-play-v030-01` 的原生等级 3 存档，`cheat=false`、无 gameplay fixture；全部成长、战斗、移动和物品操作通过官方 MCP SDK。实际花费 9 属性、5 职业、4 通用、1 类别点；力量达到 20、体质 17，Stunning Blow/Warshout 各 3、Rush 1、Heavy Armour Training 2、Vitality 3。源码解锁 Dirty Fighting 树，包运行将双手武器攻击树掌握度由 1.3 提升至 1.5，均在各自独立副本中执行。

两轮均拾取自然铁质巨锤，替换原双手剑、卸下、重穿，并用真实 Ctrl+S 保存后加载新存档的副本。成长与装备状态保留，新 session 拒绝旧 session，首份新保存副本未被重载改写。非法/未知、点数不足、前提不符和重复命令均有检查；请求数包含预期失败命令。BC 全程 idle/actions=0，无 Lua 错误。

两份历史存档各 6 文件及原报告证据完整保留。只读查询通过动态学习条件/说明、RNG、感知、物品命名/鉴定守卫。完整原生 99 项与互操作 35 项使用隔离测试角色/场景，特殊回调及多物品拾取分支另由单元差分覆盖。

当前包：[dist/tome-mcp-bridge.teaa](dist/tome-mcp-bridge.teaa)，**15 个生产文件**，SHA-256：

```text
ff627dd0a9c686b27da034e86db0a5b3bc3ce075e1feeb7858aa1dc16e2c9a74
```

包与冻结源码一致；Python 源码及成长驱动在最终两轮间一致。见 [manifest](dist/manifest.json)、[成长汇总](validation/2026-09-15-growth/growth-summary.json)、[回归与文件校验](validation/2026-09-15-growth/regressions.json)、[详细验收](tests/growth/VALIDATION.md)、[复现说明](tests/growth/README.md) 和 [0.4.0 交付报告](docs/tome-mcp-growth-items-0.4.0.md)。

本版成长执行限审核过的标准 Berserker 类别，支持与技能激活范围分开判断；传奇点、洗点、铭文槽、复杂装备和任意对话未适配。raw 字段不是最终面板值。未改变战斗平衡，未以接口验收代替完整战役。

以下保留历史记录，其中“当前包”和限制描述指各版记录当时的状态；本页首节描述现行产物。

## 0.3.0：普通战役技能、恢复与换层（历史）

日期：2026-09-15。Bridge 与 Python server 均为 **0.3.0**；Battle Companion **0.1.1** 与 Danger Alert **1.3.1** 保持原版本。环境为 ToME 1.7.6、Linux、LuaJIT、LuaSocket、Xvfb 与软件 OpenGL。

| 检查层 | 最终结果 | 证据 |
| --- | --- | --- |
| MCP Lua | **457 项通过**：62 JSON + 28 TCP + 159 Actions + 29 Journal + 72 Observer + 62 Tasks + 45 Runtime | [独立审阅](docs/tome-mcp-campaign-review.md) |
| Python MCP | **17 个测试通过**，含真实官方 SDK stdio 和动作 schema／紧凑轮询 | `server/tests/` |
| 普通战役，冻结源码 | **40 项通过，202 次 MCP 动作，4 次原生日志击杀** | [结果](../../../tmp/tome-mcp-validation/sessions/campaign-source-final-01/result.json) |
| 普通战役，正式安装包 | **36 项通过，69 次 MCP 动作，4 次原生日志击杀** | [结果](../../../tmp/tome-mcp-validation/sessions/campaign-package-final-01/result.json) |
| 正式包原有完整原生回归 | **92/92 项通过**，包含只读纯度、去重、手动接管、保存／重载 | [结果](../../../tmp/tome-mcp-validation/sessions/campaign-mcp-release-01/result.json) |
| 三插件正式包互操作 | **35/35 项通过**，旁观／控制、助手暂停、键盘接管、保存／重载 | [结果](../../../tmp/tome-mcp-validation/sessions/campaign-control-release-01/companion-result.json) |
| 其他插件单元回归 | BC **486 项**、Danger Alert **1540 项**通过 | 各 addon 的 `tests/run.sh` |

两次普通战役运行都从原试玩存档的全新隔离 HOME 副本出发：保留出生辅助 addon、原有技能装备与属性，`cheat=false`，没有加入战斗 fixture。所有战斗、恢复、移动与换层都经官方 MCP SDK；原存档全部文件 SHA-256 在运行前后不变。

两次均实际从 Trollmire 1 进入 **Trollmire 2**，验证换层撤销租约、原命令去重、显式 reconnect 后普通等待，以及五个原有核心技能的原生冷却／资源／能量或效果。休息均精确执行 **5/5 回合**上限；自然敌人在场时 0 步停止，源码运行另遇到休息 4 步／1 步后的敌人中断。两次均完成原生恢复，最终 **HP 132/132、stamina 100/100、五技能冷却 0**，无当前可见敌人，BC idle/actions=0，无 Lua 错误。增量日志分别采集 74／79 项，无游标缺口。

当前生产包：[dist/tome-mcp-bridge.teaa](dist/tome-mcp-bridge.teaa)，**13 个生产文件**，SHA-256：

```text
e88a46a8888f9a0d9ae2ddbb5642dae5010e0830b7a45c7114cf103036035a8d
```

包内文件与最终源码候选逐字节一致；两次普通战役使用的 Python 源码和验收驱动哈希一致。见 [manifest.json](dist/manifest.json)、[普通战役汇总](validation/2026-09-15-campaign/campaign-summary.json)、[回归摘要](validation/2026-09-15-campaign/regressions.json)。完整行为说明、反馈处理与证据目录见 [0.3.0 交付报告](docs/tome-mcp-campaign-improvements.md)。

复现普通战役见 [执行器说明](tests/campaign/README.md)。本轮验证了第二层的普通战斗、恢复与继续行动；没有完成整场战役。Wild 已验证原生瞬发防御效果，未证明对特定缴械状态的解除；升级选项、拾取／穿戴／加点、任意对话和其他技能仍未自动化。伤害／断线等休息生命周期专项由隔离测试补充，不能当作普通战役都实际触发过这些场景。

以下保留旧版历史记录；旧哈希与旧能力范围不代表当前包。

## 0.2.0：旁观连接与自动战斗交接（历史）

日期：2026-09-15。Bridge 和 Python server 均为 0.2.0；组合使用 Battle Companion 0.1.1 与 Danger Alert 1.3.1。

- Lua 回归 **135 项**（JSON 62 + TCP 28 + Runtime 45）、Python **16 个测试**通过。
- 更新后的正式 MCP 包通过原有完整 **92/92 项**真实游戏验收：[结果](../tome-battle-companion/validation/2026-09-15/mcp-regression-result.json)。
- 三插件组合分别用源码和正式 `.teaa` 通过 **35/35 项**官方 SDK MCP 验证：[源码](../tome-battle-companion/validation/2026-09-15/source-result.json)、[安装包](../tome-battle-companion/validation/2026-09-15/package-result.json)。
- 只读旁观不获取 token、不停止助手，观察能显示连续战斗与敌方损血；显式控制接管后取消助手队列。原生键盘接管、保存、复制新测试角色存档后重载均不恢复自动动作；原存档和副本哈希不变。
- 源码／包组合各 36 次受监测的观察／检查均保持纯度。没有 Lua 错误。

0.2.0 历史生产包有 11 个生产文件，SHA-256：`5badcb410662b0a36f0638418fb179464813544b2cc84bf0233de51a0e877bc8`。当时归档与被测文件一致。详细证据和适用范围见 [组合验收](../tome-battle-companion/VALIDATION.md) 和 [文件哈希](../tome-battle-companion/validation/2026-09-15/sha256.json)。

以下保留 0.1.0 首版历史验收，旧哈希不代表当前安装包。

## 0.1.0 首版验收

日期：2026-09-15。适用范围：ToME / T-Engine 1.7.6，Linux、LuaJIT、LuaSocket、Xvfb 与软件 OpenGL；联网能力已启用。

## 结果

首版源码与正式安装包均通过验收，可以作为后续自动战斗插件开发的基础。

| 检查层 | 结果 | 证据 |
| --- | --- | --- |
| Lua JSON / 非阻塞 TCP / Runtime | **120 项通过**（62 + 28 + 30） | `bash game/addons/tome-mcp-bridge/tests/run.sh` |
| Python TCP client / MCP schema / stdio | **14 个测试通过** | `server/tests/`；包括当前及 initialize 模式的官方客户端 |
| 独立审阅 | 未处理的审阅发现为 0 | [审阅记录](docs/tome-mcp-review.md) |
| 真实游戏源码安装 | **92 项通过** | [native-06/result.json](../../../tmp/tome-mcp-validation/sessions/native-06/result.json) |
| 真实游戏 `.teaa` 安装 | **92 项通过** | [package-01/result.json](../../../tmp/tome-mcp-validation/sessions/package-01/result.json)；与交付归档哈希一致 |

JSON 与 transport 另经 Lua 5.1 / LuaJIT 检查；500 个随机 JSON 样本与 Python 往返一致，见独立审阅记录。

## 原生验收内容

- 创建独立新 Cornac 测试角色及固定竞技场，没有导入用户存档。
- 半包、多包 TCP；重复观察和检查不改变位置、生命、资源、能量、冷却或世界 tick。探针检测到的 RNG、`canSee` 和技能预检调用数为 0；真实隐藏角色不可检查。
- 等待、移动、普通近战、Lightning、自疗、瞬发 Adrenaline Surge 经过原生入口。能量、资源、冷却、效果和敌方回合按原生机制结算，最终返回玩家可行动边界。
- 命令重复、参数冲突、旧版本拒绝；断线重连查询原结果；queued 动作被 stop 取消。
- XTest 真实键盘事件在游戏和原生 Escape 菜单中均撤销控制；菜单期间返回 `needs_input`，拒绝世界动作。
- 官方 MCP 客户端通过 stdio 启动外部服务，经 TCP 调用全部六个工具和规则资源，完成真实等待、结果查询、去重与 stop。
- 真实 Ctrl+S 保存；复制本次测试 HOME 后重载同一角色，复用端口。新 session 拒绝旧 session 和旧 command history，闲置不恢复自动行动；重载后可重新连接并执行等待。原始和复制的测试存档均未被重载过程改写。

Runtime 专项用受控异常检查嵌套 tick、保存、切图失败的清理及错误传播，保证已开始动作标记不确定、后续写入隔离、只读仍可用，读档后恢复。另覆盖普通视觉 fallback、特殊视觉保守拒绝、T_ATTACK 原生拒绝耗能的分类、对话输入及旧 Game 内存回收。这些专项是单元证据，不冒充真实引擎异常注入场景。

## 可复现安装包

0.1.0 历史生产包 SHA-256（当前包见上方 0.3.0 记录）：

```text
023f67a1b5762e9c1acba858b5ed0bdac3b68e2669e54ed0aaeace09b91bff1a
```

历史包内共 11 个文件（运行 Lua 与 README），没有测试 probe；当时已验证归档内容与 0.1.0 生产文件一致。当前包的逐文件 SHA-256 见 [manifest.json](dist/manifest.json)。Python MCP server 单独安装，见 [README](README.md)。

原生执行器 SHA-256：`5aa8fe5cfa8f0cde3aa82deb4602be95d8f7668e7d5d2ea4ce450cae18248dc7`。每个验收目录的 `input.json` / `candidate.zip` 固定引擎、Lua 候选与配置，`result.json` / `wire.json` / `game.log` / `mcp.log` / `reload.log` 保留结果。源码和包验收分别位于 `tmp/tome-mcp-validation/sessions/native-06/` 与 `tmp/tome-mcp-validation/sessions/package-01/`。两次完整验收均未发现 Lua 错误。

复现步骤与依赖见 [原生测试说明](tests/native/README.md)。本工作区运行：

```sh
PYTHONPATH=server/src tmp/tome-mcp-venv/bin/python -m unittest discover -s server/tests -v
python3 game/addons/tome-mcp-bridge/tests/native/run.py release-check-01 \
  --mcp-python /workspace/t-engine4/tmp/tome-mcp-venv/bin/python \
  --addon-archive /workspace/t-engine4/game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa
```

每次使用新的运行名；运行器会清理自己启动的进程。

## 已知范围

本次是受控真实游戏场景，测试 probe 仅用于布置角色/场景及记录原生调用。没有验证完整战役、全部职业、Windows/macOS、窗口最小化节流或与全部第三方 addon 的组合。真实切图中的中断、鼠标接管和复杂多段目标操作尚无本轮完整原生场景覆盖；相关边界依靠已有实现与专项检查，不能据此宣称全流程自动游玩。

首版仅支持 README 列出的三种技能和基本动作。特殊感知缺少可信缓存时保守省略；地形采用有限玩家视角记录，可能少报火炬照明下角色脚下的地形。失败动作可能已经消耗能量，超时必须查询原 command_id；这些是接口语义，调用方必须处理。
