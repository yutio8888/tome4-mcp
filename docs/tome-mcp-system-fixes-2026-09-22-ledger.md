# SYSFIX-20260922 修复台账

状态：三组代码及后续审核修复已交付/集成；最新标量修复待最后提交后冻结候选。原生验证与独立审核进行中，尚未接受或合并 PR。此前统一测试通过只适用于原候选。基线产品 caefa9a；绑定决策见同日期 decisions 文档。协调者维护此文件，Dev 不修改。

| ID | 问题 | 批次 / owner | 状态 | 验收要求 |
| --- | --- | --- | --- | --- |
| SYS-01 | 连续动作上限 | policy Dev | IMPLEMENTED / 最终验收待办 | 精确额度/请求数、pause/resume/pending/sustain、source+dist native |
| SYS-02 | emergency_only fallback | policy Dev | IMPLEMENTED / 最终验收待办 | 两种显式模式、无活锁、旧策略可见迁移、source+dist native |
| SYS-03 | 预算契约分叉 | policy Dev | IMPLEMENTED / 最终验收待办 | 双计数、跨pump界、规范统一、source+dist native |
| SYS-04 | local clear 持久化 | core Dev | IMPLEMENTED / 最终验收待办 | local/remote对称、reset/reload、原生保存证据 |
| SYS-05 | 边界 checker 缺失 | tooling Dev | IMPLEMENTED / 最终验收待办 | checker负例与tests/run接线；候选结合SYS-12后统一验证 |
| SYS-06 | manifest 悬空证据 | tooling Dev | IMPLEMENTED / 最终验收待办 | dangling/duplicate/missing/hash负例及合法历史格式兼容 |
| SYS-07 | 候选证据归档 | 协调者，集成候选阶段 | PLANNED | 最终source/dist身份、可取得raw/hash索引；依赖前三批 |
| SYS-08 | 高级编辑器 | 协调者，后续独立Dev里程碑 | PLANNED | 核心语义稳定后规则创作/导入/审阅/往返；非本批完成声明 |
| SYS-09 | 独立发行 | 协调者，后续独立Dev里程碑 | PLANNED | 核心与host接口稳定后拆包、独立/组合加载验收 |
| SYS-10 | README版本/能力漂移 | core Dev | IMPLEMENTED / 最终验收待办 | v4/工具列表/当前能力边界与实际schema一致 |
| SYS-11 | public act接受internal字段 | core Dev | IMPLEMENTED / 最终验收待办 | onRequest/JSON生产边界未受理/未排队、合法internal回归 |
| SYS-12 | 入站闭合/数组校验 | core Dev | IMPLEMENTED / 最终验收待办 | schema与实际解码一致、精确无动作副作用 |
| SYS-13 | dismiss错误示例 | core Dev | IMPLEMENTED / 最终验收待办 | 工具描述示例通过实际Pydantic/interaction契约 |
| U-01 | max_candidates消费未定 | policy Dev取证，协调者定稿 | REPRODUCED / DEFERRED | 已复现未消费；本批不任意截断，后续语义与owner见同日期todo文档；不得称已修 |

所有 IMPLEMENTED/PLANNED 均不等于 fixed_verified。下一门禁：三位Dev交付分支、单测与报告→协调者核对ledger→固定包/probe→独立Test与fresh Review→整改复核→PR/合并。尚未派发的角色在实际派发时记录精确ID。


## 首批派发记录

共同源码基线：`366b32b4b53f28c3ef6575290f5b290d358ebfb8`（只在 caefa9a 上加入审核/修复契约文档）。三个隔离工作区均 clean 起步；完整路径、简报与 hash 见 `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/dispatch.json`。

| 代理 | 唯一角色 | 分支 | 分配问题 |
| --- | --- | --- | --- |
| `/root/fix_core` | Dev | `fix/sysrev-core-20260922` | SYS-04/10/11/12/13 |
| `/root/fix_policy` | Dev | `fix/sysrev-policy-20260922` | SYS-01/02/03；U-01取证 |
| `/root/fix_tooling` | Dev | `fix/sysrev-tooling-20260922` | SYS-05/06 |

实际模型均为内置 `gpt-6-astra` / xhigh（继承主代理，无覆盖；主代理实际运行模型已通过Paseo状态核对）。禁止Dev自行启动游戏或重建dist；source/dist原生验证和会话生命周期由协调者接手。Review将使用新的Sol/high上下文。

SYS-08/09 和 U-01 的具体未完成项、依赖、owner 与后续触发条件见 `tome-mcp-system-fixes-2026-09-22-todo.md`。这些项尚未验收，首批不得宣称“全量修复完成”。

## 已收集交付与候选验证

- tooling：PR #27，41a34f01b5e65312e86ec0ecf49c33cc6ae1bc53；report SHA256 9ef4bda9ad9efd093d74443917aca1d9781dc847c619caeb7d06000d6afd30d3。
- policy：PR #28，2ed857960de51635accdd07c3e771efdcd952f07；report SHA256 79311477ab9bb592c44a1063492f965c46ab871a53d689e9dd32af0f7e2735af。
- core：PR #29，6628238c82b152e55c19a406bb160ae21e2bf19e；依赖 policy；report SHA256 ded11e761c1d12b3751a29b14f3ec5a410d0a141f8755e308d4921c32ffa448a。
- 临时候选 d42d071dde6d9f5b993bb13d4e5e5a10d440727a；统一入口 rc0（边界15、manifest17、Lua44脚本、Python44、三个生成器）。包72文件 SHA256 1831b912ddc94f5d43a22bb3032391d135a862440f9ea38dda8e972974600fcc。这是开发/协调者证据，独立裁决仍 PENDING。
- 新反馈 NATIVE-STARTUP-01：source `sysfix-policy-source-01` 在 addon 加载时报 sandbox os.getenv 缺失，zero checks；FAIL，已回收；owner policy Dev 修正测试夹具并更新 PR28，不得算作原生 PASS。
- SYS-04 native runner 接线补充：owner core Dev，增加显式 opt-in 的真实 clear→保存→重载断言，更新 PR29；原生结果仍 NOT_OBSERVED。
- fresh Review runtime：Paseo 137119c2-30bc-4f4d-9a4d-7762c9163a6f；tools/evidence：de482ffb-434f-468a-8c18-1ff3997e90c5。均 Codex gpt-5.6-sol/high、独立只读上下文；具体派发原因见 EXEC-02。

## 原生与独立审核新增反馈（尚待最终复核）

| Finding | 严重度 / 现象 | Owner / 已交付证据 | 状态 |
| --- | --- | --- | --- |
| NATIVE-STARTUP-01 | 测试夹具调用引擎沙箱不存在的 os.getenv，出生失败 | policy 29dcbcff；source-02 已实际进入9项检查 | 夹具启动修复已观测；首次 FAIL 保留 |
| RUNTIME-REV-01 | P2：MCP scalar 与 v4 类型/字节/范围约束双向不齐（包括错误拒绝合法长ID） | core；Revision已交付79cf8c4，完整共享标量与实际MCP矩阵待最终提交 | 修复中，阻塞验收 |
| RUNTIME-REV-02 / NATIVE-PENDING-01 | P2：真实 rest 已完成，结算停机后同帧 pump 清掉 stopped controller | core 5fb875b + policy c7a7827；真实 tick/display 回归 | 已集成，source/dist 重跑及复核待办 |
| RUNTIME-REV-03 | P2：双 legacy draft/approved 迁移丢失原 draft 表示 | policy ae8baf8；完整原始 canonical bytes 经 load/save/reload | 独立源码/离线复核接受；最终native待办 |
| RUNTIME-REV-04 | P2：导入 envelope 缺失或非字符串 hash 绕过原始哈希验证 | policy dca36dc；结构有效后保留既有语义校验顺序 | 独立源码/离线复核接受；最终native待办 |
| EVIDENCE-REV-01 | P1：denseArray 与字段复制放在死分支，checker 仍 PASS | tooling；原 Reviewer 两个 scratch 负例与作用域注册 | 已提交06f393f/ca4e24a；独立复核进行中 |
| EVIDENCE-REV-02 | P1：复制后 no_restrict=nil 未被 checker/guard 回归捕获 | tooling checker + policy 15字段真实转发 oracle | 已提交06f393f/ca4e24a；独立复核进行中 |
| NATIVE-IDENTITY-01 | 夹具错误比较跨进程临时 UID；引擎加载会分配新 UID | core 5fb875b；改为 puuid/save_name、approved bytes、保存副本哈希及错误身份负例 | 已集成，source/dist 重跑待办 |

失败会话 `sysfix-policy-source-01`（0 checks）、`sysfix-policy-source-02`（8 PASS/1 FAIL）、`sysfix-core-source-01`（112 PASS/1 FAIL）均已回收；原始 input/result/game/reload/wire 文件保留。索引 `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/prior-native-failures.json` 记录真实整体 FAIL，不因后续修复重新标成 PASS。SYS-07 最终索引仍待新包与最终运行结果。

2026-09-22 后续冻结准备：policy 最终 dca36dc1ac1013e40710d8449cda41931af259b8（报告 SHA256 36692e8d3dbf20b9669455cc2482951382a45a4a0a4477f0fa55a9760ca2c375）；tooling 最终06f393fd603483720c8506c4f3d12bf17f443359。Runtime Reviewer已独立接受REV02/03/04源码/离线修复及puuid身份oracle；不代表source/dist原生已通过。原1831b912包已被产品修复取代，不再作为最终验收包。
