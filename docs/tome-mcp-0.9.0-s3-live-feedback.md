# S3 独立实测反馈（2026-09-22）

状态：初审确认首轮 **5/6 有证据**；独立补证 Test 两项已完成，**待原 Reviewer 复核，S3 尚未验收**。固定产品包 `3a4e186b…f413fb`，产品代码与
`main@8e3c219` 一致；本轮没有产品改动。Test 为全新 GLM 5.3 Flash/high，身份及角色见模型台账。

Test 原报告保留 [原文](../validation/2026-09-22-s3-live/test-report.md)，声明 6/6 PASS。
协调者预检将 Vault 行的实际请求观察子项记为 **NOT_OBSERVED**：原生攻击/晕眩/位移有记录，
但规划中的两段队列不等于实际发出的两段请求，报告也明确没有直接观察 `nolock=true`。
冻结六行指标不改写；其余五行已由独立 Review 确认。数据索引及完整台账见
[summary.json](../validation/2026-09-22-s3-live/summary.json) 和相邻 manifest.json。

| ID | 反馈 / 当前取证 | 协调者处置 / 独立初审结果 | 是否阻塞 S3 完成 |
| --- | --- | --- | --- |
| S3-HARNESS-01 | 初次启动夹具缺少 `overload=true`，无法加载训练场 | 评分前已修正并验证；原启动 FAIL 和日志保留，旧会话已回收 | 否 |
| S3-LIVE-ISSUE-1 | Test 把 compact observe 中缺省的 `auto_combat` 解读为 null | 原始 MCP 响应有完整摘要；是控制台 `snapshot_summary` 丢字段，不是产品返回 null。夹具展示后续处置由协调者负责 | 否；不影响本轮用 policy status 取得的控制状态 |
| S3-LIVE-ISSUE-2 | 第一次 Vault start 在 Leap 已消耗的行动机会内预算暂停，opportunity 计数 1 / run 计数 0 | Review 确认符合跨 start 保留机会预算；该 1 不能称为“新提交了 Vault”，未建立产品计数缺陷 | 否 |
| S3-LIVE-ISSUE-3 | `policy_op=log` 被接受，而协调者提示它不是公开枚举 | 协调者提示有误：server.py 明确声明 `log`。保留原报告并更正说明，不能修改产品去拒绝合法操作 | 否 |
| S3-EVIDENCE-01 | Vault 实际 request/answer 两条及 `nolock=true` 缺少直接证据 | Review 确认 NOT_OBSERVED，必须补证；不以规划或“无报错”替代实际观测 | **是** |

测试共有 66 次包装器调用、65 份保存回复和 90 条实际 MCP 记录；丢失的一次本地格式化 observe
输出已重复获取并计数。`raw/010` 本身为零字节；可用回复位于完整 MCP transcript 第 13/14 条，
见 [勘误 v2](../validation/2026-09-22-s3-live/errata-v2.json)。错误装备字段的 schema 拒绝、第一次预算暂停均保留；原生等待/装备为
明确分列的准备操作。训练场赠送技能/盾牌/资源及固定假人，不表示自然成长或常规战役已通过。
手动接管仅覆盖 activate 后尚未 start 的 ARMED 状态，不宣称执行中 pending 接管覆盖。

报告落盘后自动回收整个游戏进程组及 FIFO，`--list` 无残留；Test 代理已归档。
初审提出 `REV-S3-01`（Vault 实际请求观测缺口）、`REV-S3-02`（空文件错误定位）、
`REV-S3-03`（已运行但索引为 not_run）。协调者已独立核实后两项并建立
[新版索引](../validation/2026-09-22-s3-live/manifest-v2.json)，原索引和报告保留。
初审报告另有身份/hash/坐标抄录错误，原 Reviewer 已重新取证并交付
[更正报告](../validation/2026-09-22-s3-live/review-corrected.md)，原错误稿保留且不用于验收。
协调者复算报告中 33 份原始文件哈希一致；完整结论/证据索引见相邻 review-summary / review-manifest。
Review 已关闭 `REV-S3-02/03`，仅 `REV-S3-01` 保持 OPEN。

独立 Dev `4791e304-4f35-47ec-8a81-b8f9d745a6bb` 已接手 `S3-LIVE-ISSUE-1` 的控制台字段修复
及 `S3-EVIDENCE-01 / REV-S3-01` 的测试专用被动请求记录。生产协议/包保持不变。
`REV-S3-02/03` 的协调者勘误已由原 Reviewer 复核关闭；其余三项原反馈保留上表处置。
下一 owner：Dev 交付代码/单测/PR 后，协调者核对全量台账，再启动独立 Test 补证；
实机请求证据仍是完成 S3 的必需项，不能以工具单测代替。

## 补证实现交付与启动门（2026-09-22）

独立 Dev 已交付 [PR #32](https://github.com/yutio8888/tome4-mcp/pull/32)，源码
`440a5a7f1c4bba27accb076b9f7235d23838c0f4`。控制台转发修复与测试专用被动观察器
均已提交；68 项机制检查、完整 `bash tests/run.sh`（含全部生成器）exit0。初次入口失败由
隔离布局缺少只读依赖引起，其日志保留。单测不能替代真实 Vault 请求证据。

全量反馈的实现阶段处置见
[补证启动台账](../validation/2026-09-22-s3-supplement/implementation-ledger.json)。
协调者使用新的 `supplement/agent-play.py`，首轮 driver/metrics/raw/报告保持原样。
产品 72 个 archive member 仍一致，测试观察器作为第三个独立 addon 显式加载。
下一步是新的独立 Test 实机补证，再由原 Sol 复核 `REV-S3-01`；S3 此时仍未验收。

## 补证实测交付（2026-09-22）

全新 Test `522fef2b-f4c1-4931-9ef2-2a21503f4d92` 已交付
[补证报告](../validation/2026-09-22-s3-supplement/test-report.md)：冻结两行 2/2，
22 次包装器调用、28 条 Test MCP 记录（另有 2 条协调者启动记录），3 次原生准备操作，
1 次评分 start，无重试或失败调用。64 份 Test 原始文件哈希已复算一致。

原生日志同一次 Vault 调用依次记录 request1/answer1、request2/answer2；第二次实际
`nolock_present=true` / `nolock=true`，目标 `(8,5)`、UID 15424，第二答案 `(7,4)`。
原生伤害、`EFF_DAZED`、落点 `(7,4)` 与 native/effective/run 各 1 相互对应。
compact `auto_combat` 的 4 次读取与实际原始响应一致，保留 false/0/空数组。
这些是独立 Test 的新增原生观察，未改变首轮六行历史结果；协调者核对不替代 Review。

报告及回报信封的非行为性笔误已单独记录在
[报告勘误](../validation/2026-09-22-s3-supplement/report-errata.json)：信封哈希漏一位、
调用分类漏列两次读取、PI 与 Paseo 身份区分、dry-run 不含所称 costs 字段。
运行中日志快照哈希均与终态日志的对应前缀一致。原报告不改写。
报告落盘即回收会话，Test 代理/工作区及临时工程已归档；原始证据保留。
下一 owner 为原 Sol，仅复核自身 `REV-S3-01` 及其补证工具/证据处置。
