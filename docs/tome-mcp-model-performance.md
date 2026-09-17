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
| **A** | `pi` / `commandcode/deepseek/deepseek-v4.1-flash` | high | 现行主力 |
| **B** | `opencode` / `go/glm-5.3-flash` | high | 需启用 `opencode` provider（当前 daemon 配置为 `enabled:false`） |

**轮换规则**：按 loop 交替 A → B → A → B …，保证使用频率均等。
**上下文窗口**：A、B 均配置为 **600K + 自动压缩（auto-compact）**（配置面见下"待办"）。

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

## 待办（维护者已定的配置项，尚未落实）
1. **启用 `opencode` provider**：daemon 配置 `agents.providers.opencode.enabled=false`；需启用并确认
   `go/glm-5.3-flash` 的确切 provider/model 串与 thinking 选项。
2. **A/B 均设 600K 上下文窗口 + 自动压缩**：paseo 侧存在 `contextWindowMaxTokens` /
   `autoCompactEnabled` / `autoCompactThreshold` / `autoCompactWindow` 等设置面；需确定这两个
   provider 的具体配置键（provider 自己的配置文件或 paseo per-provider 设置）并写入，然后验证。
3. **轮换生效点**：从**下一个独立 loop** 起，按 A→B→A→B 派发执行代理。
