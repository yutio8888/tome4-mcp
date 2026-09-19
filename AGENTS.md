# AGENTS.md

## 项目背景

ToME MCP Bridge 把 ToME 1.7.6（T-Engine）接入 MCP，让 LLM / Agent 以**玩家视角**读取游戏状态，并执行**经过原生结算**的游戏动作。它由两个组件组成：

- **游戏内 Lua addon**（本仓库根目录）：随游戏加载，负责观察和执行。
- **外部 Python MCP server**（`server/`）：实现 MCP 协议，监听 stdio。

两者通过 `127.0.0.1` 上的非阻塞 TCP + 行分隔 JSON（当前协议 v4）通信。

## 目录速览

| 路径 | 内容 |
| --- | --- |
| `init.lua`, `hooks/`, `overload/`, `superload/` | 游戏 addon（`overload/mod/mcp_bridge/` 是核心 Lua 模块） |
| `server/` | Python MCP server（`bridge.py` 传输、`server.py` 工具与 schema） |
| `tests/` | Lua 单元测试与集成驱动 |
| `tools/` | `generate_native_seams.py`（生成 superload）、`package.py`（打包 `.teaa`） |
| `docs/` | 架构、契约、字段清单与各版本设计文档 |
| `validation/` | 按日期归档的验收证据与生成包 |

核心模块说明见 `docs/tome-mcp-architecture.md`，接口字段见 `docs/tome-mcp-api-fields.md`，验收结果见 `VALIDATION.md`。

## 重要约定

- **不修改游戏核心**。所有介入只通过 addon 的 hooks / superload / overload 缝隙完成。
- **`superload/` 下标注 `GENERATED ... do not edit by hand` 的文件由 `tools/generate_native_seams.py` 生成**，不要手改；源码摘要由 `NativeCompatibility` 作为**重审提示/可选遥测**记录，**不得作为运行期门槛**（见下方“不追求严格审计”）。
- **观察不提交动作、不越权**：读操作**可以**调用游戏内当前实时的原生 getter/builder（**允许消耗 RNG**，不要求“无副作用”、也不要求证明其未被替换——见 `docs/tome-mcp-auto-combat-plugin-design.md` §8.3，v1.4 已废弃旧的“纯度”假设）；但**不得提交动作**（`useTalent` 等执行入口）或推进回合，且只暴露玩家已知信息（不读隐藏实体/未识别属性）。读取只有这两条红线：不提交动作、不泄露玩家未知信息。
- **写操作严格串行且只走原生入口**：不按技能 ID 写死脚本；未适配的界面返回 `needs_input` 交给玩家。
- **运行态不进存档**：socket、命令队列、协程引用、控制租约只保留在内存。
- 改动协议字段或新增能力时，同步更新 `server/`、`docs/` 与测试。

## 插件职责边界（项目级原则，必须遵守）

**自动战斗插件的职责是“忠实执行数据策略 + 提供信息 + 仲裁控制”，不是替玩家/AI 决定战术。**

- **不得施加策略性限制**：凡是插件可忠实执行的游戏操作（移动、撤退/风筝、位移/传送、
  `change_level`、`rest`、`auto_explore` 等），只要**策略写明就应执行**；插件不得因“我们认为
  危险/不常见”而拒绝。玩家常用手段（视野外传送逃跑、拉远距离风筝、上楼逃跑）都属合法策略。
  （“已策展/已适配”只表示语义已被人工审阅并记录，**不是**运行期身份证明，也**不**要求函数是
  未被替换的原生实现。）
- **策略性限制属于预设/模式默认值**：如“只在当前可见战斗内行动”“不换层”“默认不撤退”
  “不使用随机传送”等，由**策略作者**在 preset/mode 中选择，**不是插件硬门禁**。设计文档里
  §0.1 这类表述应理解为“某个 strict preset 的默认行为”，而非插件级契约。
- **必须提供准确信息与不确定性标注**：如“该传送落点随机/未知”“该落点在当前视野外”“自伤风险
  未知”，并在执行前的 `dry_run`/日志/决策中标注，让策略作者知情后**自行取舍**。
- **只对插件自身完整性/不可判定性 fail-closed**：目标丢失或不可解析、必需值因 getter 缺失/报错/
  返回 `nil`/类型或范围不可用而无法取得、控制权丢失、预算/租约边界、原生拒绝——这些表示“插件无法
  正确执行”，而**非**“策略不好”。**源漂移只是策展数据/源码的重审提示或可选遥测，本身绝不构成
  运行期失败**。**已知风险**（如自伤概率）默认只报告，由策略的阈值决定是否拒绝。
- **保留与战术无关的执行模型不变量**：单次行动机会预算、`native_pending` 不重复提交、手动输入
  收回租约、控制仲裁、只读 `dry_run`、确定性 tie-break（无 RNG 平局）。
- **不追求"运行期入口 = 原生入口"的严格审计**：Lua 是动态的，运行期任何函数都可能被其它 addon 替换，
  **无法保证、也不需要保证**入口就是"未被改动的原生实现"。本项目**不为其它插件的错误实现负责**。
  因此：**直接以游戏内实际的 getter/builder 作为正常入口调用**，不施加"身份/摘要/闭包"门槛；方法报错或
  返回 `nil` 时按"该值不可得"（`unknown`/推导失败）处理即可。禁止再引入"必须先证明函数未被替换"这类
  无限闭包要求（源摘要可作为**策展数据的重审提示或可选遥测**，但**不得作为运行期门禁**）。

> 禁止示例：因“随机传送落点不可预测”拒绝 `Phase Door`；因“默认不撤退”禁止策略里的拉远距离/
> 风筝；因“只打当前可见战斗”拒绝策略里的 `change_level`。正确做法：**执行它，并在信息里标注
> 不确定性**，由策略决定是否采用。

## 常用命令

```sh
# Lua 单元测试
bash tests/run.sh

# Python 测试
PYTHONPATH=server/src server/.venv/bin/python -m unittest discover -s server/tests -v

# 重新生成原生缝隙（改动了 superload 相关逻辑时）
python3 tools/generate_native_seams.py

# 打包正式 addon（会先校验生成的 superload 是否为最新）
python3 tools/package.py
```

游戏安装、配置与 MCP 客户端接入方式见 `README.md`。

## 开发对话与测试对话（反馈循环）

本项目用两个角色反复迭代，**不要混用**：

- **开发对话（拥有仓库/MCP 实现的这方）**：负责启动游戏、评审反馈、修改代码、跑单测、打包、重启测试、归档测试对话。
- **测试对话（每轮由开发对话通过 Paseo CLI 启动的 agent）**：**只负责实机游玩与反馈**；不得修改仓库/游戏文件，不得重启或 kill 进程。

### 一轮循环

1. 开发对话启动隔离游戏 + FIFO 控制台（`tmp/mcp-play-support/agent-play.py`，会话名如 `agent-ham-insane-02`），用 v4 出生插件创建目标角色（如 半身人/星月术士/Insane）。
2. 开发对话用 Paseo CLI 启动测试对话：
   `paseo run -d --provider pi --model commandcode/deepseek/deepseek-v4.1-flash --thinking high --cwd /workspace/t-engine4 --title "ToME4 MCP play roundN…" "$(cat tmp/mcp-play-support/agent-insaneN-prompt.md)"`
   prompt 里给出会话专用接口 `tome-insaneN.sh` / `map-insaneN.sh`、目标与反馈要求。
3. 测试对话通过控制台游玩；在**死亡 / 长时间卡住 / 完成**时：
   - `paseo send <开发对话 agent id> "<一句话结论>"` 通知开发对话；
   - 写报告到 `tmp/mcp-play-support/agent-<session>-report.md`（最终状态、经过、技能/物品、**MCP 问题 + 原始 JSON 证据**）。
4. 开发对话：收集报告 → 实现修复 + 新增/更新单测 → 提交推送（开发分支经 PR 评审）→ **确认本轮反馈的所有问题都已处理（已实现/已测试/已提交，未修项已记入 TODO 并说明）后，才 `tools/package.py` 重建并重启新一局** → 启动新测试对话 → **归档上一轮测试对话**。

> **顺序约束（重要）**：不得在处理完当前反馈前重启。每轮必须先把该轮报告的问题处理到“已修且有证据/单测”或“明确记入待办并说明原因”，然后再停止游戏、重建、重启下一轮。

### 边界与约定

- 测试对话只通过 `tome-insaneN.sh` / `map-insaneN.sh` / `send.sh` 交互；不写代码、不改 addon、不 `kill`/`quit` 游戏。
- 开发对话不替测试对话长时间游玩；用 `paseo ls` / `paseo send` / 报告文件收集反馈。
- 每轮修复必须落成文档（如 `docs/tome-mcp-0.9.0-round*-feedback.md`）并新增/更新单测；未修项记入 `docs/tome-mcp-0.9.0-todo-*.md`。
- 每轮结束，开发对话主动 `paseo archive <测试对话 id>`。


## 代理派发原则（独立上下文，必须遵守）

- **测试、开发、审核必须使用彼此独立的代理，禁止混用上下文。** 一个代理只承担一种
  角色：不得让测试代理改代码、开发代理扮演审核、或审核代理延续实现者的假设。
- **审核（Review）每轮都必须使用全新代理**，以保证独立视角，不受上一轮实现细节影响。
- **唯一例外**：当本轮工作就是"修复/回应上一轮审核发现的问题"时，可以**复用上一轮的
  那个审核代理**来做复核（只有它持有该轮问题与证据的上下文）。
- 派发时在 agent 标题与简报里标注角色前缀（`[Dev]` / `[Test]` / `[Review]`），并在简报中
  明确"不得越过角色边界"。
- **会话回收是派发方的固定职责（强制）**：一场 `[Test]`/原生会话的**报告一落盘**，立刻用
  `harness/console/reap-session.sh <session>` 回收其进程组（agent-play.py + t-engine + Xvfb +
  tome_mcp）并删除 FIFO；需要保留现场时先 `--stop`（CPU≈0）取证再回收，最后 `--all` 清场。
  派发下一位代理前先 `--list` 确认无残留。**理由**：无头 Xvfb 渲染不节流，残留会话每个持续
  烧 200–360% CPU（实测 3 个 ≈ 900%，load 30/16 核），会拖慢并可能扰乱后续构建与原生 probe。
- 开发对话（拥有仓库的这方）负责：派发、验收、合并、打包、归档；**不代替审核**——审核
  结论必须来自独立的审核代理。
- 角色与产物：
  - `[Dev]`：改仓库代码/文档 + 单测 + 打包；交付分支/PR。
  - `[Test]`：只游玩/实测与反馈，不改文件、不 kill 进程。
  - `[Review]`：只读，只出问题清单（P0–P3 + 证据）；不改代码。
- **模型角色与轮换（协调者定稿，2026-09-18）**：
  - `[Review]` **固定由 GPT-5.6 Sol（Codex）担任**：`pi` / `openai-codex/gpt-5.6-sol`，
    `--thinking high`；**不使用 A/B 做评审**。
  - `[Dev]` 与 `[Test]` **各自独立轮换**两个执行模型，互不牵连、各自计数：
    - **Dev**：本轮 A → 下轮 B → 再下轮 A …
    - **Test**：本轮 A → 下轮 B → 再下轮 A …
    - A=`commandcode/deepseek/deepseek-v4.1-flash`，B=`opencode-go/glm-5.3-flash`（均 `pi`，thinking high）。
  - 派发简报里必须写明“本轮 Dev/Test 使用模型 X（该序列上次为 Y）”，并在
    `docs/tome-mcp-model-performance.md` 记录每轮 Dev/Test/Review 的**实际**模型。
  - **`[Designer]` 角色与路径对比实验：已放弃（2026-09-18）。** 配对不成立（两臂任务/基点/规模不等价），
    且两臂都出现同一族缺陷。恢复原执行流程：`[Investigation]`（可选）→ `[Dev]` → `[Test]` → `[Review]`。
  - 上下文：执行模型在 **600K** 触发自动压缩（`models-store.json` `contextWindow=616384` +
    默认 `reserveTokens=16384`）；Review 模型（Sol）保持其真实 **272K** 窗口。

### 边界输入与引擎字段清单（强制自检，2026-09-18）

最近六轮评审反复出现同一族缺陷，且**每次都只有独立评审发现、作者自查从未发现**。故把该族固化为规则，
并已做成**可执行自检**：`python3 tools/check_boundary_rules.py --check`（已接入 `tests/run.sh`）。

**A. 调用方提供的数组/枚举**：一律**稠密 + 闭合**校验（拒绝非整数键、空洞、越界尾键），且必须在任何
`#`/`ipairs`/长度比较**之前**完成。**禁止**直接信任调用方数组——`#` 遇洞即停、`ipairs` 在洞处终止。
本族已在 `plan.values`、`plan.request_sequence`、`candidates.cells`、`target_plan` **四处**各出现过。

**B. 引擎会读取的 raised spec 字段**：必须**全部转发**（保留显式 `false`，引擎依赖 `false`），或对
**函数值字段**（`block_path`/`block_radius`/`filter`）转发真实回调、**否则显式 `unknown → fail closed`**；
**绝不静默丢弃**，且注释/文档必须如实说明转了哪些、没转哪些。以 `Target.lua`、
`interface/ActorProject.lua` 为准（新增字段须先核引擎）：`friendlyblock`、`friendlyfire`、`selffire`、
`pass_terrain`、`no_restrict`、`actorblock`、`stop_block`、`force_max_range`、`min_range`、`grid_exclude`、
`requires_knowledge`、`block_path`、`block_radius`、`filter`、`act_exclude`。

**C. 缺失/畸形输入必须收敛为 unknown**，**不得**退化为"更小的完整集合"（例如网格 plan 缺少可读的
`annotation.landing` 时，必须走保守包络或 unknown，不得当作"确定性单格"并被正常测量）。

**D. 状态转换只发生一次**（例如 `movement_postcondition_mismatch` 的同步/异步路径各只能推进一次
generation；"pause + stop" 组合会加两次，必须直接实施一次或同因 no-op）。测试须断言**精确 delta**。

**E. 证据与文档同源**：未真正执行的原生行**不得**在 `VALIDATION.md` 标 PASS 或声称"端到端"。

> 自检工具的 `A`/`B` 为结构性检查（`--check` 失败即退出非零）；`C`/`D`/`E` 由对应回归与评审清单强制，
> 工具只报 **REVIEW** 并指明强制它们的回归，**不得**打印 PASS。
>
> **可执行自检**：`python3 tools/check_boundary_rules.py --check`（已接入 `tests/run.sh`，在 Lua
> 套件之前运行，因此边界违规会让标准套件失败）。`--list` 打印每个被扫描的调用方数据 `#`/`ipairs`
> 站点（含 `guarded`/`unguarded`），`--self-test` 自证 A/B 检测器会命中真实违规、放行已加护形
> 式。若工具误报/漏报，必须先修工具并说明改了什么——开发者学会忽略的 lint 比没有更糟。

## 简报契约（派发必须遵守）

派发任何代理前，按 `docs/tome-mcp-agent-brief-contract.md`（完整规范）把简报渲染成
"**共享核心 + 恰好一个角色模块**"，逐次自包含，不依赖上一段对话。

**共享核心（每份必含；不留空字段，用 `N/A: <reason>`）**
1. **Dispatch contract**：简报 id/版本/时间；角色（唯一）；**回报地址（精确 Paseo agent id）**；收件人；
   独立性（fresh 或限定"复核上轮 review 的 finding id"）；实现/测试/审核者 id；绝对 roots（repo/support/evidence）；
   基线（分支+完整 commit+dirty overlay）；目标产物路径+sha256；权限（read/write/git/processes；merge=no；
   共享游戏生命周期=no）；单写者与依赖；停止/回报条件。
2. **Task and boundary**：一句祈使+可观测结果；必需 ID/交付物；**显式 out of scope**（含下一阶段与不改的默认值）；
   允许的实现自由度；契约变更只能由派发方修订简报。
3. **Binding contract (read first)**：内联绑定决策（决策号@版本 + 取代哪些旧文本）；关键不变量/默认值的**可观测含义**；
   必读文档（绝对路径+钉定版本/hash+章节+为何读）；历史材料标注"非规范"。
4. **Current state and relevant files**：区分 verified fact（带来源+版本）/ reported hypothesis / 已试错（附证据）；
   只列开始所需文件。
5. **Work and acceptance table**：每需求一行 → 生产入口 + 期望可观测 + 方法/允许替身 + 层/产物 pin + 独立验收人；
   结果词汇 `PASS/FAIL/BLOCKED/NOT_OBSERVED/N/A(reason+authority)`；禁止"works correctly"式空行。
6. **Feedback ledger and exit condition**：全量反馈台账（必需?/处置/commit 或 TODO+原因+owner/证据 id/独立裁决/是否阻塞）；
   角色专属完成态；下一阶段 owner。
7. **Report via Paseo**：写报告到绝对路径，再向回报地址发送固定字段信封；原始输出留 evidence root，不提交大文件。

**角色模块（恰好一个）**
- **`[Dev]`**：唯一改代码者；**只报告 "ready for review"，绝不自称 accepted/merged**；交付分支+PR。
  证据须覆盖**生产路径**；运行时改动需 source **与** dist probe + `dist` sha + 不变量行；docs/server-only 可
  `N/A: <reason>`；命名单写者与可写路径。
- **`[Test]`**：只游玩/实测与反馈；不改仓库、不 kill 进程；用会话包装器；原始证据留 tmp；交付报告+sha；
  不承担改码/PR/重启（那属于协调者/Dev）。
- **`[Review]`**：**全新代理**（仅复核"上一轮 review 的 finding"时可复用上一轮 Review 代理）；只读 + 允许写报告到指定
  tmp；输出 P0–P3 问题清单（id/类别/文件:行/为何重要/证据/建议方向）+ 已核查正确项 + 不确定项；不提纯风格问题。
- **`[Investigation]`**：只调研不改产品代码；交付方案文档；结论须带 file:line 证据。

**派发前检查清单**
- [ ] 唯一角色；Dev/Test/Review 身份互不相同；Review 全新或明确限定"复核上轮"。
- [ ] 精确回报 agent id；绝对 repo/support/report 路径；被引用文档可获取。
- [ ] 完整基线 + dirty overlay；正确的 package/hash 与加载方式（避免"隐式重建当前 main"漂移）。
- [ ] AGENTS/规范/简报一致；绑定决策内联；指令冲突先解决再派发。
- [ ] 必需 ID、out-of-scope、默认值、允许决策、精确写/进程权限明确。
- [ ] 单写者/依赖具名；probe/游戏生命周期归属明确；Test 不承担改码/PR/重启。
- [ ] 每个验收行含输入、可观测结果、证据层/命令、独立 owner；**不得用伪造 outcome 充当证明**。
- [ ] 证据适用性已指派；需要时给出 source/dist 来源与原始检索/hash 计划。
- [ ] 指标口径在评分事件前冻结（分子/分母/窗口/停止条件/缺失处理）。
- [ ] 反馈台账覆盖所有给定 finding；延期不得静默通过；退出态与下一阶段 owner 具名。
