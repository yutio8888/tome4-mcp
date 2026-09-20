# TODO — X″ 冻结后的事项（0.9.0）

## 状态：X″ 基线已落地
`refactor/xdoubleprime-bytes` 已合入 `main`（merge `5628fe0`），dist sha
`1bd60e6b89375f641ae74d78f53259c60f9c509aa8408b9e28951b3785594623`。
评审链：fresh Sol rev2 = DO_NOT_MERGE（2×P1+3×P2）→ closure 实施 → fresh Sol = MERGE（2×P3）
→ P3 文档修复 ×2 → Sol 最终 = **MERGE，P0–P3=0**。协调者独立验证：`pairs(store)` 0 表键、
重入证伪对（修复前发散 / 修复后 typed abort）、probe 177/177、acceptance 101/101、
parity 70/70、L5 工件独立复现（offending 7/15 vs base 0/15，`-joff` 0/15）。

## 已接受的已知限制（不再追）
| # | 限制 | 可达性 |
| --- | --- | --- |
| L1 | 未枚举的其它**重入变体** | 同进程 Lua（持有 `svc` 调公共 API） |
| L2 | 超出已演练种类的**奇异键诊断** | 同进程 Lua |
| L3 | 替换我方函数 / `debug` 访问私有上值 | 同进程 Lua（`AGENTS.md` 明示不负责） |
| L4 | 超大策略的 codec 成本 | **MCP 可触发**（性能，非安全边界；row 7 只测量不裁决） |
| L5 | LuaJIT **代码形状敏感**观察（重写 `classify` 计数循环可致 spurious `mixed_keys`） | 工件已保留；**micro-cause 为 hypothesis**；缓解=保持 `classify` 与 base 逐字节一致 |

**冻结声明**：X″ 循环**到此结束**。继续追同进程对抗性场景**超出范围**（`AGENTS.md`：
不负责其它 addon 替换实现；Lua 内无绝对完整性保证）。

## X″ 后待办（按优先级）
1. **[P0] 两条准入 rebase 到新 `main` 后重新评估**（Z 已可解除——X″ 基线已落地）：
   - `feat/s3-arm2`（`0e6fee9`，S3 混合组合）——需 rebase（跨 25 处冲突面），rebase 后**必须重新实机验证**；
   - `feat/r2-aprime`（`cb88fc5`，Earthen Missiles）——需 rebase（跨 42 处）。
   注意：Sol 已证明 Earthen Missiles 的 `spellCrit` **逐发**调用 → 答案**不可互换**；
   若 rebase 后仍不能给出可互换的等价性证明，**不应准入**（保持撤回）。
2. **[P1] 恢复路线图**：S3 实机测试（Shadowblade / 训练假人）→ S4（Temporal Warden
   Dimensional Step TL5 换位）→ 收尾 Celestial-Anorithil（星月术士）常规实机回归。
3. **[P2] worktree 清理**：当前 11 个 worktree；目标保留 `main` + 两个准入快照，删除已被取代者
   （`tome-mcp-bridge-funnel`（X′ 切片1，被 X″ 取代）、`tome-mcp-bridge-blint`/`blrev`（checker
   已降级）、`tome-mcp-bridge-xdprev`（评审冻结快照，证据已归档））。
4. **[P3] X″ 切片 2/3（仅在有真实需求时）**：派生 plan/candidate + `plan/annotation/landing`
   判别联合 + raised-spec 语义表；`transition(event_id,…)` 恰好 +1。**当前无阻塞需求，不做**。
5. **[P3] L5 跟进**：若未来在部署版观察到任何 `mixed_keys` 误拒，按保留工件复现路径复核；
   在此之前不升级为事实断言、不改 `classify` 代码形状。
