# SYSFIX-20260922 修复台账

状态：已授权开始实施，尚无修复验收通过。基线产品 caefa9a；绑定决策见同日期 decisions 文档。协调者维护此文件，Dev 不修改。

| ID | 问题 | 批次 / owner | 状态 | 验收要求 |
| --- | --- | --- | --- | --- |
| SYS-01 | 连续动作上限 | policy Dev | ASSIGNED | 精确额度/请求数、pause/resume/pending/sustain、source+dist native |
| SYS-02 | emergency_only fallback | policy Dev | ASSIGNED | 两种显式模式、无活锁、旧策略可见迁移、source+dist native |
| SYS-03 | 预算契约分叉 | policy Dev | ASSIGNED | 双计数、跨pump界、规范统一、source+dist native |
| SYS-04 | local clear 持久化 | core Dev | ASSIGNED | local/remote对称、reset/reload、原生保存证据 |
| SYS-05 | 边界 checker 缺失 | tooling Dev | ASSIGNED | checker负例与tests/run接线；候选结合SYS-12后统一验证 |
| SYS-06 | manifest 悬空证据 | tooling Dev | ASSIGNED | dangling/duplicate/missing/hash负例及合法历史格式兼容 |
| SYS-07 | 候选证据归档 | 协调者，集成候选阶段 | PLANNED | 最终source/dist身份、可取得raw/hash索引；依赖前三批 |
| SYS-08 | 高级编辑器 | 协调者，后续独立Dev里程碑 | PLANNED | 核心语义稳定后规则创作/导入/审阅/往返；非本批完成声明 |
| SYS-09 | 独立发行 | 协调者，后续独立Dev里程碑 | PLANNED | 核心与host接口稳定后拆包、独立/组合加载验收 |
| SYS-10 | README版本/能力漂移 | core Dev | ASSIGNED | v4/工具列表/当前能力边界与实际schema一致 |
| SYS-11 | public act接受internal字段 | core Dev | ASSIGNED | onRequest/JSON生产边界未受理/未排队、合法internal回归 |
| SYS-12 | 入站闭合/数组校验 | core Dev | ASSIGNED | schema与实际解码一致、精确无动作副作用 |
| SYS-13 | dismiss错误示例 | core Dev | ASSIGNED | 工具描述示例通过实际Pydantic/interaction契约 |
| U-01 | max_candidates消费未定 | policy Dev取证，协调者定稿 | INVESTIGATE | 候选定义/消费点/完整footprint，禁止无证结论 |

所有 ASSIGNED/PLANNED 均不等于 fixed_verified。下一门禁：三位Dev交付分支、单测与报告→协调者核对ledger→固定包/probe→独立Test与fresh Review→整改复核→PR/合并。尚未派发的角色在实际派发时记录精确ID。
