# SYSFIX-20260922：协调者绑定决策 v1.1

状态：2026-09-22 用户已要求启动代理修复系统审核问题，本文件为该轮派发的绑定决策；不代表实现或验收已完成。
基线产品：caefa9a94af85dabd73c0d7e74ef764081b1fb3e。依据系统审核报告与修改方案。

## EXEC-01@1：角色与执行方式

沿用用户明确指定的 Codex 内置 subagent。Dev 使用内置当前模型（未覆盖，继承主代理模型）；Review 固定 gpt-5.6-sol/high；新建 Dev，不复用 Review 做实现。由于内置工具不提供仓库的 A/B pi 模型，本轮作为用户指定执行方式的例外，A/B 轮换不推进，逐次记录实际工具配置。Test 另派独立身份。只通过内置协作通道异步回报，避免 Paseo CLI send 阻塞父会话。

## PUBLIC-01@1：公共 v4 请求

公开 action 只接受协议声明字段；force_actor/force_grid/authoritative_target/sequence 是内部执行上下文，绝不因请求提供一个模式位而开放。内部 native executor 共用，但公开验证与内部 carrier 验证分开。入站 envelope/args/action 闭合；sections 等数组先验证稠密、闭合、元素类型再迭代。保持合法 one-shot prefill、幂等重放、账本拒绝语义和原生目标守卫。

## POLICY-01@1：有效动作与原生提交分开计数

取代主设计 §4.1 中“所有真实调用尝试都计入 max_actions_per_tick”的旧文本，保留 anor-reg-01 fix2 已解决的 limit-1 防活锁行为。
max_actions_per_tick 是每 action opportunity 的有效原生动作预算：settled status=ok 或 energy_spent=true 仅计一次；无耗能 settled reject 不计入。instant 单独计数；显示帧、重复 pump、重新快照不重置 opportunity 预算。native_pending 不重发，最终结算仅计一次。
新增内部硬上限 MAX_NATIVE_SUBMISSIONS_PER_OPPORTUNITY=32，计任何真实 host.request/native 提交（包括拒绝和 pending 的首次提交），不计 guard 预拒绝；对同一 opportunity 跨 pump 累计，不随显示帧重置。预算到顶不再提交，pending 先追踪到可判定边界，然后 stop/release。现有每步 8 次 rule-loop 界保留，不替代跨 pump 的提交界。
status/log 明确区分 native_submissions、effective_actions、instant_actions、run_actions（可保留旧 attempts/actions 兼容别名并明确其含义）。所有 counter 在 dry_run 中只读。

## POLICY-02@1：emergency_only 与显式 fallback

emergency_only 首次与重评估都只选 emergency 规则。增加 mode.on_emergency_unavailable=release_control|evaluate_rules，缺省 release_control；明确选择 evaluate_rules 时，才允许 emergency 已知 settled 拒绝后的普通规则 fallback。unknown/pending 不可据此放宽完整性边界。
release_control 分支 stop(action_denied 或已定义的精确原因)+归还 lease，不能回到冻结式持 lease pause。内置需要旧 fall-through 的 preset 显式写 evaluate_rules；strict preset 写 release_control。移动/撤退/传送/换层等动作不增加任何战术硬禁令。
迁移必须可见：旧策略缺字段且使用 emergency_only 时，校验/导入/加载暴露语义迁移提示。旧已批准策略不能静默以新解释自动激活；将需要迁移的策略保留为规范化 draft，要求重新 approve/activate，记录 warning/reason，避免丢失原用户数据。未受该字段影响的策略不做无意义迁移。主设计、schema、preset、codec/store/service 与必要测试同步。

## POLICY-03@1：max_consecutive_actions

定义为一次 start 建立的 run 内累计有效原生动作；新 start 归零，pause/resume 不归零。缺省采用 Schema.HARD.max_consecutive_actions（当前200），策略只可收紧。普通规则、sustain、移动与原生活动共用计数；pending 最终结果只计一次，无耗能拒绝不计但受提交界限制。达到 cap 后不得再提交，结算后 stop/release，generation 单次转换。状态与日志可解释。
U-01 max_candidates 本批先核实消费范围并提交明确提案/证据，不默默截断 footprint；该未定项不得被声称已修。后续由协调者补充唯一语义。

## SETTLEMENT-01@1：异步原生结算（本次补充）

补充 POLICY-01/03；不改变已提交动作的原生生命周期。Controller attempt 与最终 outcome 使用稳定的 run_id + submission_id + 原提交 generation 关联。pause/resume 可使未提交决策失效，但同一 run 已提交的 pending 仍接受一次结算；旧 run 的迟到结果不得计入新 run。不能只拿当前 generation 与原提交 generation 比较后丢弃结果。
Runtime 只对初始返回 native_pending 的调用保留此关联；最终 reap 在计算 sequence/postcondition deviation 后调用 Service.nativeSettled，携带实际 native_return、累计 energy/instant 和关联信息。同步结果沿既有直接返回路径结算，不额外回报。NativeActivity 同样必须以实际可判定的终止/进展信号结算，不能把运行句柄消失或 phase ready 单独当作成功。必需信号缺失时结果为不可判定/失败。
若同次终止伴有 sequence/postcondition deviation，先完成计数，但不得先因额度 stop 再因 deviation handoff；保留更精确的偏离原因，generation 只转换一次。必须覆盖 pending→pause/resume→settle、重复settle、旧run迟到、cap与deviation同时出现的精确计数及generation delta。

## STORE-01@1：策略持久化

集中成功 mutation→persist 规则供本地/远程共用，包含 clear。只清 draft 的既有含义保持；runtime socket/queue/coroutine/token/lease 不入角色保存。

## EVIDENCE-01@1：门禁与证据

恢复实际可运行的 A/B 结构检查，C/D/E 仅 REVIEW 并指向行为回归；禁止把字符串存在当作行为证明。manifest passed gate 引用必须有已校验 hash 的 evidence，raw/artifact 来源按声明范围校验。源码和 dist 的模块测试不是 native 验收。
每个分批先实现/单测/完整 disposition，再由协调者允许 packaging/native probe；未完成其它批次列为具名后续阶段，不宣称13项全修。测试会话报告落盘即回收。执行默认false、v4、原生入口和读政策不变。
