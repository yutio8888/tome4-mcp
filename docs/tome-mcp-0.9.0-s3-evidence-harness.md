# S3 证据夹具（test-only）与 compact 观测修复

状态：`ready_for_review`。本文件由 `[Dev]` 编写，仅描述**测试夹具/控制台**改动；
产品包 `candidate.teaa`（`3a4e186b…f413fb`）与原生动作语义**未改动**。真实的
原生 Vault 请求/应答仍需协调者的补证会话执行；在补证被独立接受前，本仓交付中的
原生结果为 **NOT_OBSERVED**，不得据此宣告 S3 通过。

## 1. 改了什么

| 文件 | 作用 |
| --- | --- |
| `harness/console/agent-play.py` | HARN-01：`snapshot_summary` 转发 `s['auto_combat']` |
| `tests/native/tome-s3-observer/init.lua` | TEST-ONLY 插件元数据（显式 opt-in） |
| `tests/native/tome-s3-observer/hooks/load.lua` | 在 `ToME:load` 后安装观察器 |
| `tests/native/tome-s3-observer/overload/mod/S3NativeTrace.lua` | 被动观察器与有界 `[S3NativeTrace]` JSON |
| `tests/test_s3_native_trace.lua` | 观察器机制回归（受控函数，非原生证据） |
| `tests/run.sh` | 注册上述 Lua 回归 |

### HARN-01（S3-LIVE-ISSUE-1）

`overload/mod/mcp_bridge/Runtime.snapshot` 已提供公开的 `auto_combat` 对象；缺失的是
控制台 `snapshot_summary` 的字段。现在它转发该对象，随后沿用既有的 `_prune` 语义：

- 真实的 `false` / `0` / `[]` **保留**；
- 嵌套的 `None` 与空 dict 被**移除**（既有 `_prune` 行为，未改动）；
- 桥未提供该域时**保持缺省**（不发明默认值）；
- 不新增任何产品侧 summary/default。

（协调者修复说明：本行不引入新的裁剪规则，只是让 `auto_combat` 走既有的 `_prune`。）

### TRACE-01..04（S3-EVIDENCE-01 / REV-S3-01）

`S3NativeTrace` 在**动作时刻**包裹当前的 `T_VAULT.action`：

1. 记录 `invocation_start`，保存 `rawget(actor,'getTarget')` 与当前 `actor.getTarget`；
2. 若当前 getter 是可调用函数，则用**一个** delegate getter 临时替换它；
3. 用可 yield 的 `pcall` 调用**捕获的原 action 恰好一次**；
4. 动作结束后经 `rawset` 恢复保存的原始字段；
5. 失败时以 `error(err, 0)` 重抛**原始错误对象**；成功时按原始 arity 返回。

delegate getter 与 `wrapAction` 都**先 `pack(...)` 再按 `args.n` 转发**（COORD-HARN-03）：
包括缺失/尾部显式 `nil` 在内的原始参数表被原样传递，不会注入额外的 `nil`；返回值同样按
原始 arity 解包返回。

`request`/`answer` 序号在**每次 invocation 内从 1 开始**（COORD-HARN-02）；观察器另有显式
的生命周期总计 `lifetime_requests`，两者不混用：

- `request` 记录：invocation/request 序号、talent id、actor 位置、`typ` 的真实
  `type`/`range`/`radius`、`nolock_present` 与真实 `nolock`（**absent / false / true
  三态可分**，非布尔则记 `nolock_type`）；
- `answer` 记录：返回 arity、真实 x/y（`nil` 与 `false` 通过 `x_class` 区分）以及存在时
  的 actor `uid`；
- `invocation_finish` 记录：本体成败、`requests`（本 invocation 计数）与
  `lifetime_requests`（生命周期总计）。

错误文本经 `M.safeErrorText` **受保护格式化**（COORD-HARN-04）：即使原生错误对象的
`__tostring` 自身抛错，记录的也只是有界类型/文本，而 `error(err,0)` 重抛的**仍是同一个原始
错误对象**。

它**不**提供目标答案、**不**改动 `typ`/actor/command/plan、**不**重置冷却/资源/能量、
**不**替换结果、**不**自行调用 `useTalent`、**不**篡改 RNG 或控制预算、**不**使用全局
调试钩子或改核心文件、**不**设运行期身份/摘要/闭包门槛。记录只含有限标量与玩家/当前
目标数据，不枚举隐藏实体。

发射为有界 best-effort：sink/编码失败只置 `emit_failures`/`truncated` 诚实标注，
不改变游戏结果，也不吞掉原生错误；**缺失记录不得被推断为原生结果**。

外部只读读取器 `supplement/trace-s3.py`（协调者所有）按 `line.partition('[S3NativeTrace]')`
解析 `json.loads(raw)`，因此本模块只写 `print('[S3NativeTrace] ' .. json)`，且记录中
**不省略任何键**（可空值显式写 `null`）。插件安装本身也发一条**合法 JSON** 记录
（`kind='installation'`，COORD-HARN-01），不打印任何非 JSON 横幅，避免读取器产生
`parse_errors`。

### 仅在显式加载时生效（TRACE-03）

插件位于 `tests/**`，`tools/package.py` 只打包 `init.lua`、`README.md`、`hooks/`、
`superload/`、`overload/`，故**不会**进入 `.teaa`。测试插件不会自动启用：只有测试在
`-Eset_addons={…,"mcp-s3-observer"}` 中显式列出它才会加载（README 集成说明见下）。

## 2. 回归与限制（TRACE-04）

`tests/test_s3_native_trace.lua` 覆盖：参数恒等与 arity（`nil` vs `false`、缺失/尾部
`nil` 的精确 arity）、真实请求/应答捕获、`nolock` 三态、**两次 invocation 的序号与计数
独立**（COORD-HARN-02）、getter 出错后恢复、action 出错后恢复、**`__tostring` 抛错的原始
错误对象恒等重抛**（COORD-HARN-04）、yield/resume 恢复、发射失败隔离（含不吞原生错误）、
记录越界诚实标注、`install()` 幂等与缺技能上报、安装记录为合法 JSON。

**限制（必须如实陈述）**：

- 这些是**受控函数的机制单测**，不是原生 Vault 证据；不得当作 S3 行的直接证据。
- HARN-01 是控制台的一行转发：按简报**不新增 forwarding-only 单测**；由既有 Python 套件
  与协调者的真实 MCP 补充观测共同验证。
- yield 语义要求可 yield 的 `pcall`：这是 LuaJIT（游戏自身在
  `game/loader/pre-init.lua` 选择）的能力，plain Lua 5.1 会在该用法上报
  `attempt to yield across C-call boundary`。测试**在缺少该能力时显式 fail**，而不是
  静默跳过机制校验。`tests/run.sh` 优先使用 `luajit`。
- 观察器包裹的是**当前** getter，属披露的测试插桩；**不**证明该函数是未被替换的原生
  实现（AGENTS.md：无运行期身份门槛）。
- 真实 native 的适用性由协调者在补证会话产生并被独立接受后判定；本交付标记
  `NOT_OBSERVED`。

## 3. 协调者集成说明（不启动游戏）

隔离会话已由协调者准备；要把本夹具挂进冻结包运行，需：

1. **镜像 HARN-01 一行改动**：协调者的启动副本
   `/workspace/t-engine4/tmp/mcp-s3-live-20260922/agent-play.py` 是
   `harness/console/agent-play.py` 的**带环境钉定覆写的拷贝**。请把仓库版本中
   `snapshot_summary` 的同一行
   （`'auto_combat': s.get('auto_combat'),`，在 `'history'` 之后）同步到该副本；
   其余钉定差异（`TOME_MCP_TEST_ARCHIVE`、角色等）保持不变。
2. **显式加载观察插件**：以 `extra_addons={'mcp-s3-observer': <repo>/tests/native/tome-s3-observer}`
   启动（`Runtime` 会把它复制为 `game/addons/tome-mcp-s3-observer` 并加入
   `-Eset_addons`）。**不要**把它加入第 1 步之外的生产包。
3. **收集**：会话 `game.log` 中按 `[S3NativeTrace]` 前缀取记录，例如
   `python3 /workspace/t-engine4/tmp/mcp-s3-live-20260922/supplement/trace-s3.py`。
   期望：同一次 Vault 提交内恰有 `invocation_start`、两次 `request`/`answer`
   （第二次 `nolock_present=true`/`nolock=true`，两次答案坐标不同，第一次答案带 actor
   UID）与 `invocation_finish`；`emit_failures`/`truncated` 均为假。
4. **交叉核对**：与 policy/MCP 原始响应及观测到的落点/伤害/眩晕、`run_actions` 计数
   对齐；任何缺失字段记 `NOT_OBSERVED`，不得推断为通过。

## 4. 未改动的边界

无产品 `init/hooks/overload/superload/server/src` 改动，无协议/API 改动，未重建
`dist`，未改写既有证据/指标/manifest 原文，未改动协调者 roadmap/模型台账。
