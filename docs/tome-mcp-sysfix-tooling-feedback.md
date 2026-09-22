# SYSFIX-20260922：验证门禁与证据完整性反馈

状态：Dev ready_for_review；独立裁决 PENDING。负责 `/root/fix_tooling`，基线
`366b32b4b53f28c3ef6575290f5b290d358ebfb8`，分支 `fix/sysrev-tooling-20260922`。
绑定 `EVIDENCE-01@1`，只改工具、测试入口及本文，不修改产品 Lua/server/协议或历史证据。
本轮 Dev 实际为内置 Codex gpt-6-astra/xhigh；EXEC-01 例外，不推进 A/B。

## SYS-05：可执行 A/B 结构门禁

新增 `tools/check_boundary_rules.py --check [--root ADDON]`，默认检查脚本所属 addon。
它词法解析 Lua（忽略注释、区分字符串值），定位函数/控制分支，检查以下注册结构：

- A：共享 `Json.denseArray` 的全键/整型/空洞检查；factory/schema 的共享委托；
  Actions sequence、guard `plan.values`/`plan.request_sequence`、`denseCells` 与候选展开、
  planner/schema `target_plan` 的验证→拒绝 return→消费顺序。
  在同一控制分支加入提前 `#`、`ipairs` 或索引消费也会失败，放进无关分支的验证不支配消费。
- A 公共入口：`RequestValidation.validateValue` 的 array 分支；
  `M.validate` 到 envelope/operation schema 的调用；Runtime.dispatch 的验证和拒绝先于 args 分发。
  产品入口与生成 schema 由 SYS-12/core Dev 提供。
- B：实际 raised/footprint 字段表须包含 AGENTS 的 15 项；callback 表须有三个函数字段；
  复制循环保留显式 false、传递原始 callback；不可用函数字段进入 unknown 拒绝；
  mixed path 与 footprint expander 的真实复制结构均有注册。

这是**有限范围的结构检查**，不声称解析所有 Lua 语义、证明任意 addon 替换、自动发现所有新入口，
更不是运行期身份/摘要门禁。新入口/重构需显式更新注册及行为回归。
A/B 成功只输出 “registered structural checks”，C/D/E 始终是 REVIEW：

| 规则 | 实际回归/审核定位 | 未由结构检查证明的内容 |
| --- | --- | --- |
| C | `tests/test_auto_combat_guard.lua` 的 SHORT_REAL_SPEC / FIX1-01 | 缺失/畸形 landing 必须 unknown，不能缩成单格 |
| D | `tests/test_auto_combat_controller.lua` 的 R2-APR3-04 | 同步/异步 mismatch 的 generation 精确 +1 |
| E | `tools/verify_validation_manifest.py`、`tests/test_validation_manifest.py`；独立核查 VALIDATION/raw/source/dist | 哈希不能证明原生执行或证据适用性 |

`tests/test_boundary_rules.py` 有 15 项测试，复制生产 sink 后做破坏性变体（仅临时目录）：
删除验证/拒绝 return、把验证藏进注释/字符串/无关分支、提前长度/迭代消费、弱化 density、
漏 raised/footprint 字段、丢 false/赋值、删 callback unknown 拒绝、删公共入口 gate。
另有测试真正调用 `tests/run.sh`，确认结构缺陷触发非零。
`tests/fixtures/boundary_rules/{Runtime,RequestValidation}.lua` 是**明确的结构夹具**，
隔离本工具测试与并发 SYS-12 实现；不是生产功能/native 证据。
真实 `--root` 总检查该 root 的实际产品文件，没有 fixture fallback。

## SYS-06：manifest 引用与来源闭合

`verify_validation_manifest.py MANIFEST [--root REPO]` 要求根对象含 `evidence` 和 `gates`。
已知根字段接受历史 M5 元数据及 `schema_version`（省略/1/2）、`artifacts`、`source`、`notes`；
未知键、重复 JSON 键、畸形容器均返回非零，不抛未处理 traceback。
`source`/`environment`/`commands` 等仅为上下文元数据；需核验的文件必须声明在下面的文件记录中。

| 字段 | 路径/哈希契约 |
| --- | --- |
| `evidence` | 数组，记录 `{path,sha256,id?,note?}`；path 相对 manifest 目录；每条文件存在且 SHA-256 匹配 |
| `gates` | 数组，记录 `{id,status,evidence,name?,reason?,note?}`；evidence 是顶层 evidence 的 **path** 引用（不是可选 id）；passed 至少一条；所有状态的引用均须存在且已核验 |
| `raw_sources` 数组 | `{path,sha256,base?,id?,note?}`；base 缺省 `manifest`，也可 `repo` 或 `absolute` |
| `artifacts` | 与 raw_sources 数组相同；适用于 `.teaa`、engine、harness、Python 来源归档等 |
| legacy `raw_sources` 对象 | `{repoRelativePath:sha256}`；`--root` 明确其 repo 基准，省略时用脚本所属 addon |
| legacy `package` | `addon_archive/archive_sha256`、`python_source/python_source_sha256`、`game_engine/game_engine_sha256` 成对核验；路径相对 manifest；仅有 digest 或 null 路径失败 |

状态词仍兼容 `passed/failed/skipped/not_run/partial`。工具返回 0 表示**字节和引用完整**，
不是所有 gate 已 passed，更不判断摘要是否足以证明行为或 native。输出明确 `byte integrity only`。
可选 id 在各文件列表内唯一；evidence path、解析后的文件位置、gate id、单 gate 引用不得重复。
相对路径禁止 `..`、绝对路径和越界 symlink；外部来源必须显式使用 `base:absolute`。
所有声明的 raw/artifact 都在可审计范围内，必须可取得且 hash 匹配，不提供静默跳过选项。

例如候选归档可把小摘要留在 manifest 旁，大文件留可读取的 tmp/挂载归档，
无需把包和日志强塞 Git（下例 `sha256` 应填写实际 64 位小写摘要）：

```json
{
  "schema_version": 2,
  "candidate_id": "candidate-id",
  "evidence": [{"path": "summary.json", "sha256": "<actual summary sha256>"}],
  "gates": [{"id": "SCENARIO", "status": "passed", "evidence": ["summary.json"]}],
  "raw_sources": [{"path": "/absolute/archive/raw.jsonl", "base": "absolute", "sha256": "<actual raw sha256>"}],
  "artifacts": [{"path": "/absolute/archive/candidate.teaa", "base": "absolute", "sha256": "<actual package sha256>"}]
}
```

历史边界：M5 的 12 个顶层 evidence 仍可核验；其两个 raw 文件已缺失，且 package 的三个摘要
没有可核验路径，所以**完整 provenance 检查 FAIL**。这不推翻历史游戏结果，也不改历史 hash。
迁移时保留原 manifest；找到原字节后生成新的索引，以数组 `base:absolute/repo` 指向可取得文件；
找不到则保留缺口，不能编造 raw 或把原生未观测行提升为 PASS。
`tests/test_validation_manifest.py` 的 17 项测试覆盖合法当前/历史格式、绝对归档、原始悬空反例、
重复 path/id/ref/JSON key、必填/未知字段、容器类型、三类文件缺失/缺 hash/hash mismatch、
legacy package 缺路径/错误 hash、非 passed 悬空引用和路径范围。

## 统一入口与本批证据

`tests/run.sh` 强制顺序执行边界门禁、两个工具回归、Lua、Python 服务测试及三个生成器；
缺文件/依赖直接失败。纳入 policy Dev 的 `tests/test_auto_combat_sysfix.lua`，没有占位或可选跳过。
Python 选择顺序为显式 `TOME_MCP_PYTHON`、addon 的 `server/.venv/bin/python`、`python3`；
MCP 依赖缺失会明确提示。当前环境使用：

```sh
TOME_MCP_ADDON_DIR=/absolute/candidate/addon \
TOME_MCP_PYTHON=/workspace/t-engine4/tmp/mcp-system-review-20260922/python-venv/bin/python \
bash /absolute/candidate/addon/tests/run.sh
```

本批日志及 argv/cwd/rc/SHA256 索引在
`/workspace/t-engine4/tmp/mcp-system-fixes-20260922/tooling/command-results.json`。
报告另记录精确提交与索引 hash。

| 验证 | 结果/限制 |
| --- | --- |
| 工具回归 | PASS：boundary 15，manifest 17 |
| 旧基线产品上的新 boundary / 新 tests/run | FAIL（预期且保留）：缺 SYS-12 的 RequestValidation 和 Runtime 调用；集成 owner `/root` |
| core Dev 当前源码 boundary 预览 | PASS A/B；检查期间所有 inspected Lua 文件 hash 不变；仅该工作树快照，非最终候选 |
| 现有 Lua 模块 | PASS：43 个模块；使用基线 runner 在本分支代码上单独执行，**不是新统一入口 PASS** |
| Python server | PASS：39 项 |
| native/effect/protocol 三生成器 --check | PASS；不生成/不打包 |
| 原审核悬空 manifest 反例 | PASS（拒绝，rc=1） |
| 历史 M5 完整 provenance | FAIL（明确缺 raw/包来源）；修订归档属于 SYS-07 |
| native / dist 重建 | N/A：简报授权 docs/tooling profile；本批未启动游戏、未打包，native NOT_OBSERVED |

| ID | 必需/处置 | 后续 owner/独立裁决/阻塞 |
| --- | --- | --- |
| SYS-05 | 已实现且工具回归完成；待 core/policy 集成后完整入口 | `/root`；PENDING；阻塞最终候选接受，未豁免 |
| SYS-06 | 已实现且真实 CLI 负例/正例完成；历史缺口已显式说明 | fresh Review PENDING；当前归档由 SYS-07 接手 |

下一阶段由 `/root` 固定整合候选、核对全量 ledger、授权 package/probe、派独立 Test/fresh Review。
本批仅 ready_for_review，不宣称 accepted、merged 或 13 项全修。

## 独立审核整改：EVIDENCE-REV-01 / EVIDENCE-REV-02

上文 15 项工具回归及初次提交检查保留为历史记录；本节替代其 SYS-05 证据适用结论与最新测试计数。

2026-09-22，原独立 Sol reviewer `de482ffb-434f-468a-8c18-1ff3997e90c5` 给出两个 P1；
它们阻塞 SYS-05，先前工具测试全绿不能覆盖这些新反例。协调者简报
`SYSFIX-tooling-reviewfix rev2`（SHA256 `2cf3ada9ca83ce1fa77c1e7e3d75a7b143b85bfafce5280c1670007136b668d5`）
授权本 Dev 只修同一 checker、其测试与本文；manifest 语义、产品代码和 native 生命周期均不改。

**EVIDENCE-REV-01**：把 `Json.denseArray` 整体藏在 `if false` 后返回 `true,0`，
或把 `copyFootprintFlags` 整个转发循环放入 `if false`，旧工具仍输出 A/B PASS。
原因是结构/字段检查只限制到函数范围，没有限制到实际应处的控制分支。
现在每个注册结构必须位于明确作用域：模块级字段/alias、函数直接语句，或逐层指定的
loop/if 分支。被额外的 dead/unrelated 分支包住时失败；函数声明本身也必须位于其注册 owner。
`denseArray` 的键检查明确位于全键循环内；B 的 copy、mixed、expander、unknown 路径均有明确定位。
这不是对任意 Lua 路径的可达性证明，不使用 getter 身份门禁。

**EVIDENCE-REV-02**：在正常转发循环之后插入 `spec.no_restrict=nil`，旧 checker、
15 项工具测试和旧 guard 的 192 checks 都通过。现在 `B.copy-terminal` 注册**完整转发循环**，
并要求该循环之后的函数尾部只剩 `return spec`。因此循环内部新增清空语句、循环后逐字段
清空、下标写入、`rawset` 或整个 `spec` 重绑定都会要求重审并失败。
这是针对这个短小 helper 的闭合结构约束，不声称分析任意 Lua 别名/动态调用或代替行为回归。
未来若此处需新语句，须连同注册与实际字段 round-trip 回归一起审阅。

工具回归增至 22 项，新增真实 CLI 负例分别覆盖两个 REV-01 死/无关分支、三类字段表的死分支、
函数声明死分支，以及 REV-02 的 15 个强制字段逐一清空、下标/rawset/rebinding、循环内清空。
注释中的相同文字仍可通过。所有失败分支保持 C/D/E 为 REVIEW。
完整 15 字段、显式 false、真实 callback 的**产品行为 round-trip**由独立的 policy Dev 在
`tests/test_auto_combat_guard.lua` 补充；本 Dev 不越过该文件单写者边界。

本轮证据根：`/workspace/t-engine4/tmp/mcp-system-fixes-20260922/tooling/review-fix/`。
两个原 reviewer scratch 现分别返回非零（REV-01：A/B；REV-02：B.copy-terminal），正常 canonical
产品结构检查返回 0；精确受检源码 hash 和前后稳定性记录在该目录索引中。
本隔离分支尚无 SYS-12 生产模块，整分支入口依赖仍如实失败；不因此放宽 gate。
这里仍仅 `ready_for_review`，由同一 finding owner 复核这两项；native N/A（tool-only 简报授权），
native NOT_OBSERVED；产品 source/dist 验收和 SYS-07 归档仍由协调者负责。
