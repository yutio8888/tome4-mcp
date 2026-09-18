# 执行模型表现账本（execute→review loop 统计）

状态：**现行记录**。每次"执行（Dev）→ 审阅（Review）"闭环结束后，追加一行；按**执行 model**归类，
统计通过率与 issue 数量。审阅 model 另行记录（不属于本账本的"执行 model"维度）。

## 记账口径（冻结）
- **一个 loop** = 一次 `[Dev]` 交付 + 一次独立 `[Review]` 裁决（不含 dispatcher 自查）。
- **执行 model** = 该 loop 中 `[Dev]` 代理使用的 provider/model/thinking。
- **通过（PASS）** = 该 loop 的最终 Review 裁决为 `merge`（无阻塞项）。`merge with follow-ups` 记为
  **PARTIAL**（不阻塞但未干净通过）；`do not merge` 记为 **FAIL**。
- **issue 数** = 该 loop 最终裁决中的 P0/P1/P2/P3 计数之和（`issues`），并分列严重度。
- 通过率 = PASS / 总 loop；同时给出"非 FAIL 率"（PASS+PARTIAL）。

## 固定执行模型与轮换（维护者指定）
| 代号 | provider / model | thinking | 备注 |
| --- | --- | --- | --- |
| **A** | `pi` / `commandcode/deepseek/deepseek-v4.1-flash` | high | **已实测通过**（需在 pi 的 `enabledModels` 中启用） |
| **B** | `pi` / `opencode-go/glm-5.3-flash` | high | **已实测通过**（B 是 **pi 的 `opencode-go` 供应商**模型，不是 paseo 的 `opencode` provider） |

## 角色分工（协调者定稿）
| 角色 | 模型 | 说明 |
| --- | --- | --- |
| **Dev / Test（执行）** | **A ↔ B 逐 loop 交替** | A=`commandcode/deepseek/deepseek-v4.1-flash`，B=`opencode-go/glm-5.3-flash` |
| **Review（复核）** | **固定 GPT-5.6 Sol（Codex）** | `pi` / **`openai-codex/gpt-5.6-sol`**，thinking high；**不再**用 A/B 做评审 |

轮换规则：**执行**侧按 loop 交替 A → B → A → B …；**评审侧恒为 Sol**，且每个新任务用**全新** Review
agent（仅"复核上一轮自身发现"时可复用同一 Review agent）。

## 上下文窗口与自动压缩（2026-09-18 定稿，已实测）
- 全局：`~/.pi/agent/settings.json` → `compaction={enabled:true,keepRecentTokens:20000}`（`reserveTokens`
  用默认 **16384**）。pi 的阈值公式为 `contextWindow − reserveTokens`。
- **A、B 的 600K**：在 `~/.pi/agent/models-store.json` 把 `opencode-go/deepseek-v4.1-flash` 与
  `opencode-go/glm-5.3-flash` 的 `contextWindow` 设为 **616384** → 阈值 = 616384 − 16384 =
  **600,000**，即**在 600K 触发自动压缩**。A 另补 `commandcode` 供应商条目（同一 `contextWindow`）。
- **Sol 保持其真实窗口 272,000**（Codex），阈值 ≈ 255.6K——**不可**套用 400K 预留（会产生负阈值）。
- 实测：`openai-codex/gpt-5.6-sol`、`commandcode/deepseek/deepseek-v4.1-flash`、
  `opencode-go/glm-5.3-flash` 均以 `--provider pi` 启动并正常应答。
已在 `~/.pi/agent/settings.json` 的 `enabledModels` 加入 `opencode-go/glm-5.3-flash`；两个模型均已用
paseo 试跑确认可启动并返回。
**启用点的实测命令**：A = `--provider pi --model commandcode/deepseek/deepseek-v4.1-flash --thinking high`；
B = `--provider pi --model opencode-go/glm-5.3-flash --thinking high`。

## Loop 记录（回填：全部为模型 A；B 尚未启用）
| # | 任务（分支/PR） | 执行 model | 审阅 model | 裁决 | P0 | P1 | P2 | P3 | issues |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | movement-first-tranche rev1 (PR #15) | A | gpt-5.6-sol | FAIL | 0 | 6 | 3 | 0 | 9 |
| 2 | movement-first-tranche rev2 | A | gpt-5.6-sol（复核自身） | FAIL | 0 | 3 | 3 | 0 | 6 |
| 3 | movement-first-tranche rev3 | A | gpt-5.6-sol（复核自身） | FAIL | 0 | 1 | 0 | 0 | 1 |
| 4 | movement-first-tranche rev4 | A | gpt-5.6-sol（复核自身） | **PASS** | 0 | 0 | 0 | 0 | 0 |
| 5 | movement-adapter-factory rev1 (PR #16) | A | gpt-5.6-sol（全新） | FAIL | 0 | 3 | 2 | 0 | 5 |
| 6 | movement-adapter-factory rev2 | A | 同 #5（复核自身） | FAIL | 0 | 2 | 1 | 0 | 3 |
| 7 | movement-adapter-factory rev3 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 1 | 0 | 2 |
| 8 | movement-adapter-factory rev4 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 1 | 0 | 2 |
| 9 | movement-adapter-factory rev5 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 1 | 0 | 2 |
| 10 | movement-adapter-factory rev6 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 1 | 0 | 2 |
| 11 | movement-adapter-factory rev7 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 0 | 0 | 1 |
| 12 | docs-antipattern rev1 (PR #17) | A′ (`deepseek-v4-flash`) | gpt-5.6-sol（全新） | FAIL | 0 | 2 | 1 | 0 | 3 |
| 13 | docs-antipattern rev2 | A′ | 同 #12（复核自身） | FAIL | 0 | 1 | 0 | 0 | 1 |
| 14 | docs-antipattern rev3 | A′ | 同 #12（复核自身） | **PASS** | 0 | 0 | 0 | 0 | 0 |
| 15 | movement-adapter-factory rev8 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 1 | 0 | 2 |
| 16 | movement-adapter-factory rev9 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 2 | 0 | 3 |
| 17 | movement-adapter-factory rev10 | A | 同 #5（复核自身） | **PASS** | 0 | 0 | 0 | 0 | 0 |
| 18 | S1 Rush 实机测试（Test） | **B** | 无（测试任务） | FAIL（主指标 NOT_OBSERVED） | 1 | 0 | 2 | 1 | 4 |
| 19 | auto-combat 移动原生死锁 P0 修复 | A（Dev）/ **B**（Review） | 全新 Review（新任务） | **PASS**（merge with follow-ups） | 0 | 0 | 0 | 5 | 5 |
| 20 | P0 修复后 Rush 复测（Test） | **B** | 无（测试任务） | **PASS**（P0 关闭；新 P2 1 / P3 2） | 0 | 0 | 1 | 2 | 3 |
| 21 | P2-1 备选落点 + P3-2 冷却详情 | A（Dev）/ **B**（Review） | 全新 Review（新任务） | **PASS**（merge with follow-ups） | 0 | 0 | 0 | 3 | 3 |
| 22 | N2 测试运行器根 + N1 日志 landing | A（Dev）/ **B**（Review） | 全新 Review（新任务） | **PASS**（**merge**，无阻塞项） | 0 | 0 | 0 | 3 | 3 |
| 23 | 星月术士回归实机测试（Test） | **B** | 无（测试任务） | FAIL（无 P0 回归；新 P1 1 / P2 1 / P3 2） | 0 | 1 | 1 | 2 | 4 |

> A′ 说明：#12/#13 的 Dev 实际以 `commandcode/deepseek/deepseek-v4-flash`（非 v4.1）启动，属**偏离**；
> 后续统一使用固定 A。

## 汇总（截至当前）
- Loop 总数：**23**（全部已判定）。
- **PASS 7**（#4、#14、#17、#19、#20、#21、#22）、**FAIL 16**、PARTIAL 0 →
  **通过率 7/23 = 30.4%**。
- Issue 合计：**64**（P0 1 / P1 26 / P2 21 / P3 16）；平均每 loop 2.78。
- **#23（模型 B 实机回归）**：**无 P0 回归**（68/68 原生 ok、0 `native_timeout`/`native_aborted`、
  Moonlight Ray 原生目标请求正常结算）——PR #18 在射线类技能上得到正向验证。新发现：
  **D-1 P1**（emergency 治疗被原生拒绝 → `no_emergency_action` 暂停 + 暂停期世界不推进 ⇒ CD 永不衰减
  的活锁，需人工解围并间接致死）、**D-2 P2**（auto `denied` 事件丢掉了命令路径已有的
  `missing={kind='cooldown',...}` 结构化详情）、**D-3 P2**（`new_enemy` 暂停风暴：单场群战 12 次暂停，
  罚站挨打；应做成 preset/mode 可配默认而非插件门禁）、**D-4 P3**（status 日志尾部/`first_seq` 不一致）。
  已派模型 A 修复（D-1 必修，D-2/D-3/D-4 一并）。
- **#22 闭环**：模型 A 修 **N2**（`tests/run.sh` 从脚本自身位置推导 addon 根 + 支持
  `TOME_MCP_ADDON_DIR` + 坏覆盖 fail-fast；旧实现上溯 4 层会**静默跑主检出测试**）与 **N1**
  （`movement_retry` 客户端可见日志携带 `landing`，允许集有界），模型 B 独立复核 → **verdict MERGE**
  （N1/N2 端到端 PASS、证伪干净；3 项 P3 均为环境/加固注记，已登记 TODO #63）。PR #20 合并 `923d0bc6`；
  main 重建 dist `24b99327`。
- **#21 闭环**：模型 A 修 P2-1（approach 被原生拒绝后选次优落点，never-resubmit 三层强制、
  受 `max_actions_per_tick` 约束、非确定性落点与 Rush `authoritative_target` 路径不变）+ P3-2
  （denied 冷却详情），模型 B 做**跨模型独立复核** → `merge with follow-ups`（P2-1/P3-2 PASS、
  证伪干净：无预算绕过/无 exclude 泄漏/无重复提交/无策略限制；3 项 P3 已登记 TODO #62，
  其中 **N2 为 `tests/run.sh` 在备用 worktree 会跑主检出测试的工具链缺陷**）。PR #19 合并
  `8c977429`；main 重建 dist `6d68fdfd`。
- **P0 线程关闭**：模型 B 实测 12/12 `T_RUSH` 经 auto 槽**即时原生结算**（`native_result=ok`、全部
  到达目标相邻），无 `waiting_native`/`settling` 卡死、无 CPU 空转、`native_timeout` 未触发；
  意外 pause/stop = 0。该复测另发现 1 个 P2（approach 被原生拒绝后无备选落点 → `no_available_action`）
  与 2 个 P3（已登记 TODO #61）。
- **#19 闭环**：模型 A 修 P0（#18 由模型 B 实测发现），模型 B 做**跨模型独立复核** →
  verdict `merge with follow-ups`（5/5 断言 PASS，5 项新问题全为 P3，已登记 TODO #60）；
  PR #18 合并 `eb706b7b`，main 重建 dist `2f7c15e4`。
- **模型 B 首次用于 loop #18**（S1 实机测试）：发现确定性 **P0**——auto_combat 槽执行 `T_RUSH`
  原生死锁（waiting_native/settling 永冻、~500% CPU、prompt 不浮出），手动槽同技能可完整结算；
  另 F3/F4 (P2) 与 F5 (P3)。
- 会话计数：模型 A 用于 loop #1–#11、#15–#17（另 #12–#14 为 A′ 偏离）；模型 B 用于 #18。
- 两个任务（docs-antipattern、movement-adapter-factory S1）均已在**第 3 个复审轮**收敛为全 PASS
  并合并（PR #17 `2b5a4cd`、PR #16 `bc3eea0`），无遗留 P0/P1/P2。
- 说明：loop #12–#14（docs 任务）的执行模型为 **A′**（`commandcode/deepseek/deepseek-v4-flash`，
  偏离固定 A）；固定轮换自**下一个独立 loop** 起。
- 说明：#1–#3、#5–#10 是**同一功能的连续迭代**（每次修复上轮 findings），因此"每 loop FAIL"反映的是
  **迭代收敛过程**，不是独立任务的成功率；后续应以**独立任务**为统计单位，并把"同一功能的
  修复轮次"合并为一组观察。

## 配置状态（已完成）
1. **A/B 串已确认并实测**（见上表"固定执行模型与轮换"）。
2. **600K + 自动压缩已配置**：`~/.pi/agent/settings.json` 的 `compaction.reserveTokens=400000`
   （1M − 400K = 600K 阈值）。
3. **轮换生效点**：从**下一个独立 loop** 起，按 A→B→A→B 派发执行代理。
   （备注：`~/.paseo/config.json` 的 `opencode` provider 启用与 B 无关，B 走 pi 的 `opencode-go`。）


## S1 合并后的收尾清单（维护者已同意）
1. **补 DOC-04**：`docs/tome-mcp-0.9.0-movement-s1-implementation.md` 只在
   `feat/movement-adapter-factory`；S1 合并后按文档修复口径（去掉运行期身份/摘要/闭包门控，
   说明"audited"=策展/可观测元数据）修正并提交。
2. **最终核验 `NativeCompatibility` 仅诊断**：grep 确认 `ActorCombat.computed`、`TalentQuery`、
   `Actions` 执行入口不再以 source-diff/identity/digest/closure 决定可用性；替换但可用→使用，
   不可用→typed unknown；执行侧仅保留控制/租约/序列化/pending/native-result 不变量。
3. **更新 `VALIDATION.md`**：记录 v1.6 原则在**代码与文档两侧**的落地——"不追求运行期入口=原生入口的
   严格审计"、"读取无纯度/RNG 门"、"无插件级策略门（限制属 preset 默认）"，并注明本条为现行验收口径。
4. **账本写入** S1 rev8 的最终 loop 结果（该 loop 仍是 A 任务的延续；下一个独立任务起用 B）。
