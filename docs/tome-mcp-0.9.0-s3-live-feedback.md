# S3 独立实测反馈（2026-09-22）

状态：独立 Review 已完成初审，**5/6 有证据，Vault 补证未完成，S3 未验收**。固定产品包 `3a4e186b…f413fb`，产品代码与
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
