# ToME MCP Bridge 修改方案

日期：2026-09-22。基线：`caefa9a94af85dabd73c0d7e74ef764081b1fb3e`。本文件是修改提案，**不代表产品修复已实施或新契约已生效**。问题依据见[系统审核报告](tome-mcp-system-review-2026-09-22.md)。全部 13 个问题目前仍为 OPEN。

## 1. 修改目标与边界

优先兑现已经接受的策略字段、原生执行和状态一致性契约，再补齐可执行验收，最后完善编辑器与独立交付。保留 Lua addon + Python MCP 架构、原生结算入口和声明式策略内核。

不引入 getter 身份/摘要门槛、不要求观察零 RNG、不硬禁撤退/传送/探索/换层、不把风险判断替换成插件战术。不要把本次工作扩展为所有职业/所有 addon 的自动战斗支持或完全无人值守通关。

每个工作包由一名 Dev 单写；Runtime、schema、生成器等共享文件明确串行。Dev 只报告 ready_for_review；独立 Test 负责实机观察，fresh Sol Review 裁决。协调者负责派发、证据适用性、合并和会话回收。

## 2. 工作包、依赖与验收责任

| 工作包 | 问题 ID | 依赖 / 单写者 | 交付与验收 | 原生证据适用性 |
| --- | --- | --- | --- | --- |
| WP-0 统一契约 | SYS-02/03，SYS-01 的计数边界，U-01 | 协调者先给出一份绑定决策；本文只是推荐 | 主设计/API/schema 的词义唯一，明确取代旧文本；fresh Review 核查一致性 | 文档决策本身 N/A；实施后由 WP-2 验证 |
| WP-1 公共请求边界 | SYS-11/12 | 独立 Dev；Actions/Runtime/protocol 单写，与 WP-2/3 错开合并 | 实际 JSON→Transport→Runtime 负例、内部 auto 正例；Review 核查无已排队副作用 | source+dist 原生交互/连续提示，不改变一次性预填 |
| WP-2 策略与上限 | SYS-01/02/03 | WP-0；controller/evaluator/service/schema 单写 | 精确请求数、额度、rule id、owner、generation 与活锁反例 | source+dist 的低生命/拒绝/pending/instant/sustain 场景 |
| WP-3 本地/远程持久化 | SYS-04 | Runtime 单写，和 WP-1/2 串行集成 | mutation 对称矩阵和清 draft 后 reset/reload | source+dist 角色存档/重载；运行态不入档 |
| WP-4 门禁与证据 | SYS-05/06/07 | 工具可独立开发；候选索引等候最终行为包 | checker 负例、统一测试入口、有效 candidate manifest；Review 验证 raw 可取得 | 工具本身 N/A；归档运行证据必须来自固定候选真实执行 |
| WP-5 文档与示例 | SYS-10/13 | 稳定 API 后，docs/server 描述单写 | README v4/工具清单；示例通过真实 Pydantic/schema，覆盖实际 option | 纯文案 N/A，不因文案修改重跑整局 |
| WP-6 人类编辑器 | SYS-08 | 核心语义稳定；独立产品里程碑 | 人在 UI 完整创作/导入/审阅策略，与 MCP canonical bytes 往返一致 | source+dist 原生 UI，真实输入与保存流程 |
| WP-7 独立部署 | SYS-09 | 共享 facade/host 边界稳定，独立里程碑 | 独立包及与 Bridge 组合；仅一个内核/owner；独立安装说明 | 独立/组合包矩阵、无 MCP 进程、保存/手动接管 |

表中的独立验收人是下一轮专职 Test / fresh Sol Review，尚未派发。每个工作包结束都要回写对应问题 ledger：fixed_verified、deferred（原因+owner+触发条件）、not_a_defect（反证）或 blocked。普通延期不能豁免强制门禁或已接受的策略上限。

## 3. 先冻结两项存在冲突的语义

### 3.1 动作预算采用明确的不同计量对象

**推荐保留后续已合并的“有效动作预算”语义，同时单独约束调用次数。** 不直接恢复造成 limit=1 活锁的旧逻辑。

- 文档明确 legacy `max_actions_per_tick` 实际按 action opportunity 计数；显示帧不重置，settled 且未耗能的拒绝不消耗有效动作槽。
- 记录 `native_submissions`、`effective_actions`、`instant_actions` 和 `run_actions` 等不同计量值，避免 `attempts` 同时表示“提交”和“有效动作”。具体对外名称须在 API/schema 中一次性定稿。
- 原生提交/拒绝由独立、显式的上限约束；可以保留现有规则循环界作为内部上限，但应可观察、有明确 reason。若新增策略字段，应同时补 schema、capability、UI、文档与旧策略兼容说明。
- 达到上限时停止后续提交；未完成原生调用继续追踪，确认结算后交回控制。不得留下持有 lease 而世界无法推进的无限冻结。
- 更新主设计 §4.1、API 字段、修复轮 supersession 和测试 oracle，明确哪段历史文本被取代。

验收：limit=1 的 settled reject→另一条规则仍能合法执行一个有效动作；所有拒绝路径真实提交次数受独立上限约束；native_pending 仅一次提交；显示帧或重复 opportunity 不刷新额度；到顶时 generation 精确变化一次，lease 如契约释放。

### 3.2 emergency_only 必须保持显式调度集合

**推荐 `emergency_only` 只调度 emergency 规则，无法执行时 stop + release。** 需要普通 fallback 的策略应显式选择，不由执行器推断。

- evaluator 首次和拒绝后重新求值都遵守同一个 eligible 集。
- 可以增加明确的 unavailable 选项，例如 `release_control` / `evaluate_rules`；名称和默认值由一次契约修订定稿。希望 fall-through 的内置 preset 显式设置它。
- 保留 `evaluate_rules` 的自由；允许作者把 wait、撤退、传送或换层规则标为 emergency。
- 当所有 emergency 规则不可执行时，输出 typed reason 和拒绝明细，停止并归还 lease；不回到旧的持 lease pause 活锁。
- 老策略的迁移必须可见：说明新增字段/默认语义、更新批准 hash，不能让升级后一个旧策略静默换战术。

验收矩阵必须包含 `emergency_only` / `evaluate_rules`、原生 settled reject / guard reject / unknown / pending、低生命前后与没有 fallback 规则等组合。断言实际提交的 rule id、次数和控制 owner，不能只断言最终状态字符串。

## 4. 修复公共请求边界（WP-1）

### 4.1 分离公开 action 与内部执行上下文

在 `Runtime.dispatch(act)` 先使用 public validator；外部字段严格限制为 v4 action 联合声明的键。`force_actor`、`force_grid`、`authoritative_target`、`sequence` 只由真实 auto host 内部构造，放在独立的参数/类型或单独验证入口中，不能依靠一个公开 JSON 字段决定是否切换到内部模式。

共用原生 executor 与必要的基础值校验；无需复制整套动作逻辑。Python Pydantic 的限制保留，但不能代替 Lua 入站限制。保证合法一次性 target prefill 仍工作，后续原生提示仍进入 respond；自动战斗内部多目标/队列行为仍按其独立契约执行。

验收：对四个内部字段逐个和组合发送公开请求，必须在命令受理/排队前返回结构化错误；command ledger、tick callback、invocation、revision 的差异按“未接受”契约精确断言。同一内部 carrier 经内部 host 仍合法。分别覆盖直接 v4 TCP 和 Python MCP，不把前者被接受、后者被拒绝当成端到端一致。

### 4.2 schema 在真实入站边界生效

建立每个 op 的闭合 envelope/args/action 验证，并从共享协议定义/向量生成或一致性校验，减少三处手写规则漂移。`sections` 等调用方数组必须在 #/ipairs 前验证稠密闭合、元素类型、允许枚举及协议声明的唯一性；明确区分缺省 sections、合法空数组、object/null 和畸形值。

从 JSON 文本经实际解码入口构造负例，覆盖未知顶层/args/action 键、sections object、类型错和边界长度；拒绝时不生成完整快照或排队动作。合法输入的返回字段、分页和载荷上限保持一致。不能只添加“schema 本来就会拒绝”的测试。

## 5. 控制上限与策略写入修复

### 5.1 执行 max_consecutive_actions

建议定义为“同一次自动运行中累计的有效原生动作数”：新 `start` 建立新 run 时归零；pause/resume 不归零，防止以 resume 绕过策略上限。若维护者选择另一含义，必须先改契约和迁移说明。

- 普通规则、sustain、移动和原生活动共用额度检查；在任何下一次原生提交前检查。
- 已提交 pending 的动作不重发、不重复计数；结算成功或实际耗能按统一定义仅计一次。未耗能拒绝仍受独立调用次数界约束。
- cap 到顶后停止运行并释放 lease，保留可解释的原因与已用额度；不要制造 freeze/pause 循环。
- 核查同一 limits 对象的其它接受字段，尤其目前缺少清晰消费点的 `max_candidates`。先定义候选集合和截断语义，不能把不完整 footprint 当完整集合；未定义前不得假称该上限已执行。

验收：schema-valid cap=1 时经过两个机会仍只有一次有效原生动作；cap=N 精确执行 N 次；sustain 与 normal 混合、pending 结算、拒绝、resume、手动接管均不绕过 cap；status/log 数字与实际提交记录一致。

### 5.2 统一本地与远程策略写入的持久化

将“哪个成功操作需要保存角色策略”收敛到唯一生产入口。可让 service 返回显式 mutation metadata，再由共用 facade 统一调用 `saveState`；也可以先集中一份操作表，避免同时维护两份 if 白名单。

- local `clear` 与远程 `policy clear` 保存同一结果；只清 draft，approved/running 的处理保持既有契约。
- 对 set_draft/approve/activate/deactivate/import/import_assistant/clear 做入口对称矩阵。
- 持久化仍只包含用户策略数据和已定义的角色状态，绝不保存 socket、命令队列、协程、控制 token/lease 或临时运行计数。

验收：两种入口执行相同操作后 `saveState` 的规范化数据一致；clear 后 reset/reload 不再恢复旧 draft；失败操作不误写；无客户端模式和远程模式分别验证。生产模块测试后，再用独立 source/dist 游戏存档/重载验证实际存储边界。

## 6. 补齐真实可执行的验证门禁

### 6.1 恢复边界自检及统一入口

恢复 `tools/check_boundary_rules.py --check` 并接入 `tests/run.sh` 或新的统一验证入口；文档中的命令必须在干净 checkout 实际可运行。

- A：数组先做稠密/闭合验证，才进入 #/ipairs/长度检查。
- B：engine-consulted spec 字段完整转发，保留 false；回调转发或 unknown 路径可定位。
- C/D/E 仍明确输出 REVIEW 并指向具体回归；结构匹配成功不得伪装成动态行为 PASS。
- 对 checker 本身加入有意义的失败夹具：删除关键前置验证/丢失字段时返回非零；避免只检查某个字符串在任意位置出现。
- 统一入口串起 Lua、Python、三个生成器与边界检查；依赖缺失必须明确失败，不静默跳过。

### 6.2 验收证据必须闭合

增强 manifest 校验：每个 passed gate 引用都必须指向存在且已校验 hash 的 evidence 条目；重复/未知引用、遗漏 hash、缺文件不能 PASS。raw_sources 如处于声明的可审计范围，需有可解析位置和 hash 校验；外部大文件用可访问的归档引用，不强迫全部提交进 Git。

为当前候选维护一份索引：source commit + dirty overlay hash、package hash、引擎/harness 身份、source/dist 加载来源、场景 id、结果、命令与原始证据。VALIDATION 首页仅摘要该索引，其余按日期保存历史。

不得将本轮模块复现称为 native；未观测场景写 NOT_OBSERVED，旧证据只在相关源码/包/fixture 未变且适用性明确时复用。

## 7. 修正文档和可执行示例（WP-5）

统一 README 当前版本为 v4，列出实际 MCP 工具及自动战斗快捷键/本地入口，明确哪些高级 UI 与独立发行能力尚未交付。历史 v3 链接保留历史标签，不再混入当前操作说明。

`tome.dismiss` 自述删除不存在的 `confirm` 答案，指导客户端读取当前 interaction 的 answer_types/options，再用合法的 option/cancel。为文档中的结构化示例运行真实 Pydantic/JSON Schema 检查；此修复不扩充新协议能力。若以后要加入 confirm，须另立全链路方案。

## 8. 逐步补齐产品目标与架构边界

### 8.1 编辑器

将能力拆成可独立验收的增量：规则增删/复制/排序，谓词与动作/selector 结构化编辑，文件或粘贴 JSON 导入及错误定位，draft/approved/running 差异展示与 proposal 审阅。UI/MCP/import 必须调用同一 schema/codec/store。

先达到策略 JSON 稳定往返、用户能在 UI 创建和修改一条完整规则，再增加更复杂的条件树与合并体验。若阶段内不实现完整目标，应明确产品范围与后续 owner，不能继续将它当成已达成。

### 8.2 无外部客户端与独立发行分开验收

先提取 transport-free 本地运行服务，将控制、host/原生集成与可选 TCP/MCP facade 分开；UI 只依赖本地服务。Json/Distance 等通用工具可放共享层，避免为了独立插件复制两份策略内核。

独立发行 `tome-auto-combat` 需要独立入口/元数据/包/安装说明和加载矩阵：只装自动战斗包、与 bridge 同装、没有 token/外部客户端、保存重载、双 owner 争抢。单纯设置 disabled 或不启动 Python 不能算完成独立发行。

按行为边界逐项迁移 Runtime，保留兼容 facade；每次重构都沿既有生产链证明控制和结算不变。

## 9. 完成与验收规则

每个 finding 交付生产路径回归、精确源版本、所需文档/schema 更新、证据索引和独立裁决。测试要证明触发原因：例如上限拒绝必须由上限触发，不能因为技能本来就在冷却而“碰巧拒绝”。

涉及 Lua runtime 的修复：先单元/受控复现，后固定候选的 source 与 `.teaa` 原生 probe；在实际 engine 中观察请求数、能量/回合、pending、owner/lease、generation、保存重载和必要的游戏可见信息。不用伪造 outcome 代替正在证明的原生行为。

Dev/Test/Review 使用独立身份；本轮未实现，下一独立 Dev 按当前模型记录回到 A，Test 轮换在实际派发前核对其独立计数。每次简报自包含且限定单一角色。原生报告落盘后立即回收其会话，下一次派发前确认无残留。

建议退出态：所有必修 P1 已经 fixed_verified 或经明确契约修订消除；P2 每项有修复证据或具名的延期原因/触发条件；没有将 mandatory 验收项用普通 TODO 静默豁免。不得以“测试全绿”或“包 hash 正确”独立替代上述条件。
