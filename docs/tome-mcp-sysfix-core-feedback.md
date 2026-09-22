# SYSFIX core 修复交付（2026-09-22）

状态：**ready for review；尚待协调者固定候选、source/dist 原生验证和独立 Review**。基线 `366b32b4b53f28c3ef6575290f5b290d358ebfb8`，实现角色 `/root/fix_core`。实际模型为用户指定的 Codex builtin / gpt-6-astra/xhigh，本轮不推进 A/B 轮换。

绑定 PUBLIC-01、STORE-01、POLICY-01/03、SETTLEMENT-01；保留默认执行关闭、v4、读取不提交动作/不泄露未知信息、原生入口动态可替换、幂等与单次提交。

## 实现

- **SYS-11**：公开入口用 `Actions.validatePublic`，内部 carrier 留在 `Actions.validate` 和共享 executor。四个内部字段（含显式 false）一律受理前拒绝；请求模式位或 run/submission/generation 字段不能开放内部路径。动态技能和一次性 prefill 继续可提交，原生目标守卫保持原位。
- **SYS-12**：`RequestValidation` 在任何控制/认证副作用前消费生成的 `RequestSchema`，落实 envelope、按 op 的 args、action 的闭合对象及类型/枚举/边界。数组先 `Json.denseArray` 再长度/元素/唯一性检查；`sections={}`/null/空洞/尾键/重复/未知域拒绝，省略和 JSON `[]` 保留完整快照语义。policy/config/filter 继续交给各自语义校验器；answer 保留既有额外字段忽略行为。
- **SYS-12 新增子问题**：旧根 schema 的无判别 args `oneOf` 互相重叠，真实 JSON Schema 验证会拒绝合法 stop/abandon/observe/level_map/policy_log。改为根请求按 op 判别 args，各 action 也是闭合判别联合；真实 before/after 五例均由 invalid 变 valid。生成器不认识的约束关键字/正则直接生成失败，防止漏编译约束。
- **SYS-04**：本地和远程成功操作共用 `persistAutoCombatMutation`，包含 clear。只清 draft，保留 approved；import 仍是原有只读解析语义（共享保存规则不把它变成 set_draft）；assistant store=false 不持久化，store=true 持久化。失败操作不保存，运行态不入档。
- **SYS-10/13**：README 当前描述统一 v4，工具表与实际 13 个 MCP 工具对齐，补本地快捷键与高级编辑器/独立包未交付范围。dismiss 示例只使用实际 option/cancel；sections 的枚举和唯一性也在 Python 入口校验。
- **协调者追加 SETTLEMENT-01 接线**：真正 pending 的 Tracker root / NativeActivity 留下 run_id+submission_id+原 generation；真实终态在 reap 时只回报一次 `AutoCombatService.nativeSettled`。同步结果不再回报。序列/位移偏差先随最终结果记账，再单次 handoff；同一终止不先 cap-stop 后 deviation-stop。活动句柄消失或 ready 不能独立证明成功，必须有完成/步数/能量/位移信号。已有 bounded timeout 也会清除原 pending 关联：保留 native_timeout 的一次终止，再记实际结果/能量或 uncertain，避免下一次 start 因已释放的调用永久拒绝。

## 已执行的证据层

原始证据位于 `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/core/`，交付报告与 SHA 清单由协调者归档。以下都是 **source/offline**，不称为 native：

| 检查 | 结果与范围 |
| --- | --- |
| Runtime 生产模块 | PASS，406 checks；真实 JSON→Transport→Runtime→Actions 校验，精确账本/queue/invocation/energy/turn 不变；真实 service/store/reset 两入口的 mutation 保存矩阵 |
| 真协程生产路径 | PASS；Service→host→Actions.execute→Tracker yield/resume→Runtime reaper→Service.nativeSettled；pending pause/resume/重复/旧run/timeout cleanup、cap+postcondition 精确 generation delta=1、rest 完成与无终态信号 |
| 组合 Lua 全套 | PASS，43/43 已注册文件；core 的 Runtime/Actions/JSON 边界，加 policy Dev 的 auto_combat 模块和已更新的 policy 测试，来源逐文件记录在 combined-suite-manifest.json，检查期间模块 overlay 未变化 |
| 原 core runner + 新 policy 模块 | FAIL，旧 policy test D-1 仍假设缺省 emergency fallback；这属于本轮 policy 同步修改的测试，不能混用旧测试与新契约。组合 suite 使用 policy Dev 的新版测试后通过 |
| Python | PASS，44 tests；其中新增 5 tests 校验所有工具的实际 TCP 序列化、schema 边界、README 工具发现、dismiss Pydantic 示例 |
| 生成器 | PASS：protocol/native seams/effect manifest 的 --check |
| 边界结构 checker | PASS A/B；调用 tooling Dev 的候选 checker 对 core root 验证。C/D/E 仍为 REVIEW，不能当作行为证明 |
| source/dist 原生调用与保存/载入 | **NOT_OBSERVED**；本 Dev 不启动游戏、不打包，下一阶段协调者执行 |

组合模块测试是显式依赖联调：core 分支的异步回报需要 policy 分支的 `AutoCombatService.nativeSettled`，不可单独挑入旧产品后声称完整。它没有重建/测试新 `.teaa`。

## 原生探针交接

`tests/native/run.py` 的 `Acceptance.public_boundary()` 通过真实 TCP 检查四个内部字段、畸形 sections、envelope/args extras，断言账本/revision 与 native actions/energy/world_tick 未变化；已接入既有 `run()`，也可由协调者单独调用。

可选 `tests/native/run.py --sysfix-core` 使用隔离测试配置开关，在出生后调用 `SysfixCoreProbe.prepareLocalClear()`，沿用 Ctrl+S 原生保存和新进程加载保存副本，在 reload hook 调用 `verifyReload()`。默认不开启。出生/读档两份日志必须各有一条 `[MCPProbe]` 的 `kind=sysfix_core` 记录，断言 draft 为空、approved 完整 canonical bytes 一致、保存策略不含运行句柄、manual/inactive/execution=false。角色身份使用原生持久 `Player.puuid` 和 `game.save_name`，实体 `uid` 只作诊断；保存副本逐文件 SHA 比较保留。

## 原生反馈补修：NATIVE-PENDING-01 / NATIVE-IDENTITY-01

协调者执行的 `sysfix-policy-source-02` 为 **FAIL（8 PASS / 1 FAIL）**：原生日志 2475 行已经记录 rest 在 2 turns 后因 `max_turns` 结束，随后 tick 持续推进；fixture 最终报告 `settlement_timeout`。原因是 Runtime 在 `settleAutoActivity → nativeSettled` 已计数、cap-stop 并归还 lease 后，同帧仍调用 `Service.step`；它按 control_lost 路径清除了刚停止的 controller。新回归加入真实 `Game:tick → display` 调用，delegating spy 在旧代码观察到一次错误重泵并失败；原回归的 `tick_serial=0` 未进入该泵条件。Runtime 现仅推进存在且未 stopped 的 controller；policy Dev 的配套修复使显式重复 Service.step 也保留终态。完成态在后三次 tick/display 中保持 controller、计数和 generation 不变，generation 精确 delta=1。

协调者执行的 `sysfix-core-source-01` 为 **FAIL（112 PASS / 1 FAIL，113 checks）**：策略内容和所有保存边界均一致，只有 `player_uid` 从 2394 变为 2865。`engine.Entity:loaded()` 原生重分配 UID；将它当持久角色身份是 fixture 错误。改为比较 `Player.puuid`（`Player:init` 仅在缺失时生成）和原生 save_name，完整 approved bytes 和保存副本 SHA 仍必须一致。原失败会话的两份 `game.teag` 均保存相同 puuid，已作为诊断证据。新增负例要求错误持久 UUID、错误 save_name、任一策略 bytes 改变均失败；仅 UID 改变可通过。

本次离线验证：Runtime **410 checks**、Interactive Runtime **122 checks**；真实 Runtime 本地 prepare/禁用不变；runner **26** 项默认/缺失/重复/错误进程/持久身份负例；Lua/Python 语法与 diff check 通过。依赖 policy `c7a78279995439ec5bba80d70d4b545c02e2a301`。原始证据在 `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/core/pending-native/`。两个原失败结果保持 FAIL；修复后的 source/dist 原生结果 **NOT_OBSERVED**，仍由协调者执行并由独立角色裁决。

## 独立审核补修：RUNTIME-REV-01

实际 MCP `tome.act` 原先接受 `expected_revision=0`，与 `protocol/v4/common.schema.json` 的 Revision 下限 1 不符；act/respond/dismiss 也未统一限制协议上限 9007199254740991。Python 入口现共用 `Revision` 类型，三处 expected_revision 都限制在协议范围；dismiss 仍可省略或为 null。

新增真实 MCP Client→server→BridgeClient→FakeGame 边界回归，对三个工具分别提交 0、1、max、max+1：无效值返回本地错误且 TCP 请求数不变，有效值发出恰好一个符合请求 JSON Schema 的数据包；工具发现的 min/max 同时与共享 schema 定义比较。初版回归在旧实现观察到 revision=0 和三个上界越界请求到达 wire，初版修复后 Python 45 tests PASS。

同一审核 finding 随后扩展到其余 v4 标量：共用 identifier 的 C0 禁止和 256 UTF-8 bytes 上限（移除原 128 字符误限）、option_id 的 512 bytes、cursor 的可打印 ASCII、command_id 的序号上限、events_after 的安全整数上限，以及嵌套 action/answer 的非空 ID。公开工具和模型均应用相应类型；实际协议允许控制字符的 inline respond.interaction_id / policy.expected_hash 只检查非空与字节上限，dismiss.interaction_id 保持其无此限制的 inline 契约。status.options_offset 移除协议未声明的 32 位上限；不新增字符或数字限制。

新增矩阵从真实 common/requests schema 读取约束，覆盖 12 个有参数工具、嵌套动作/回答和可选参数的 **1,787 次实际 MCP 调用**；包含合法/非法上下界、128/129 ASCII 旧误限边界、2/4 字节 Unicode 字节边界、C0/DEL、空 ID、cursor 字符和 command 序号。每个非法输入要求本地错误且无 TCP；每个合法输入要求恰好一个经扩展 v4 validator 校验的请求。工具发现同时比较共享及 inline 的边界、pattern 与字节/序号扩展。测试 oracle 实际执行 x-max-utf8-bytes/x-max-sequence，并使用 Lua wire 的完整字符串正则语义，避免普通 JSON Schema validator 忽略扩展或 Python `$` 接受末尾换行。相同最终矩阵对冻结的前版 `79cf8c4b3389161127a5445f3e36dd005bbad898` 产生 **569 failures**，当前 Python **47 tests PASS**。原始证据在 `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/core/scalar-boundary/`。

这是 server 边界证据，不声称游戏原生验收；独立复核仍待完成。RUNTIME-REV-02 与 NATIVE-PENDING-01 是同一 finding，交叉引用，不重复计数。

## 完整问题台账

独立裁决均为 PENDING，本表不替代协调者 ledger。

| ID | 本次处置 / owner | 是否阻塞最终验收 |
| --- | --- | --- |
| SYS-01 | policy Dev 实现；core 提供真实异步结算接线与回归 | 是，待固定候选 source/dist + Review |
| SYS-02 | policy Dev 实现；API 字段由 core 同步 | 是，待独立验证 |
| SYS-03 | policy Dev 实现计数；core 提供结算与 API 文档 | 是，待独立验证 |
| SYS-04 | core 实现、source 回归通过 | 是，待实际保存/重载 |
| SYS-05 | tooling Dev 独占；候选 checker 对 core A/B 通过 | 是，待集成门禁 |
| SYS-06 | tooling Dev 独占 | 是，待其证据与独立裁决 |
| SYS-07 | 协调者后续候选归档阶段 | 是，原始证据尚待耐久索引 |
| SYS-08 | 协调者后续独立 Dev 里程碑；高级规则编辑未交付 | 未在本批解决，不静默豁免 |
| SYS-09 | 协调者后续独立 Dev 里程碑；独立包未交付 | 未在本批解决，不静默豁免 |
| SYS-10 | core 文档同步、实际工具发现测试通过 | 待 Review |
| SYS-11 | core 公共/internal 隔离、生产入口回归通过 | 是，待 source/dist 原生交互 |
| SYS-12 | core 生成式闭合入站校验、真实 JSON 回归通过 | 是，待 source/dist 原生与 Review |
| SYS-13 | core 示例修正、真实 Pydantic 回归通过 | 待 Review |
| U-01 | policy Dev 取证、协调者后续定稿；API/README 明确 max_candidates 仅 schema 校验未消费 | 不宣称已修，不截断完整 footprint |
| NATIVE-PENDING-01 | core Runtime 停止终态不再自动重泵；policy Service 补显式 step 终态保留；真实 tick/display 离线回归通过 | 是，待修复后 source/dist + Review |
| NATIVE-IDENTITY-01 | fixture 使用持久角色 UUID/save_name，保留策略和保存哈希比较；错误身份负例通过 | 是，待修复后原生保存/载入 + Review |
| RUNTIME-REV-01 | server 共享/inline v4 标量完整对齐；47 Python tests / 1,787 实际 MCP/TCP 标量边界例通过 | 待独立复核 |
| RUNTIME-REV-02 | 同 NATIVE-PENDING-01，不重复计数 | 同该项 |
