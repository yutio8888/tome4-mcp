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

**轮换规则**：按 loop 交替 A → B → A → B …，保证使用频率均等。
**上下文窗口**：两者均为 1M 窗口；已在 `~/.pi/agent/settings.json` 设
`compaction={enabled:true,reserveTokens:400000,keepRecentTokens:20000}`。pi 的自动压缩阈值
= `contextWindow - reserveTokens` = **1,000,000 − 400,000 = 600,000**，即**有效 600K 窗口 + 自动压缩**。
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
| 11 | movement-adapter-factory rev7 | A | 同 #5（复核自身） | 待定 | — | — | — | — | — |
| 12 | docs-antipattern rev1 (PR #17) | A′ (`deepseek-v4-flash`) | gpt-5.6-sol（全新） | FAIL | 0 | 2 | 1 | 0 | 3 |
| 13 | docs-antipattern rev2 | A′ | 同 #12（复核自身） | 待定 | — | — | — | — | — |

> A′ 说明：#12/#13 的 Dev 实际以 `commandcode/deepseek/deepseek-v4-flash`（非 v4.1）启动，属**偏离**；
> 后续统一使用固定 A。

## 汇总（截至当前，仅模型 A）
- Loop 总数：**13**（其中 2 个待定）。
- 已判定：11；**PASS 1**、**FAIL 10**、PARTIAL 0 → **通过率 1/11 = 9.1%**；非 FAIL 率 1/11。
- Issue 合计：28（P0 0 / P1 20 / P2 8 / P3 0）；平均每 loop 2.5。
- 说明：#1–#3、#5–#10 是**同一功能的连续迭代**（每次修复上轮 findings），因此"每 loop FAIL"反映的是
  **迭代收敛过程**，不是独立任务的成功率；后续应以**独立任务**为统计单位，并把"同一功能的
  修复轮次"合并为一组观察。

## 配置状态（已完成）
1. **A/B 串已确认并实测**（见上表"固定执行模型与轮换"）。
2. **600K + 自动压缩已配置**：`~/.pi/agent/settings.json` 的 `compaction.reserveTokens=400000`
   （1M − 400K = 600K 阈值）。
3. **轮换生效点**：从**下一个独立 loop** 起，按 A→B→A→B 派发执行代理。
   （备注：`~/.paseo/config.json` 的 `opencode` provider 启用与 B 无关，B 走 pi 的 `opencode-go`。）
