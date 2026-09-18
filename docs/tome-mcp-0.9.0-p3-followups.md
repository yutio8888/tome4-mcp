# ToME MCP 0.9.0 — P3 follow-ups 清尾（#60-N2 / #63-P3-b / #63-P3-c / #64-RR-1）

日期：2026-09-18。Branch `fix/p3-followups`，off `main@d780865`（worktree `.../tome-mcp-bridge-p3`）。
Role `[Dev]`（model A，该序列上次为 B）。merge=no。`allow_auto_combat_execution` 保持 `false`；
**无游戏核心改动，无生产代码改动**（本分支只触及 `tests/` 与 `docs/`）。

来源：四条既有、非阻塞的 P3 gate（TODO #60-N2、#63-P3-b、#63-P3-c、#64/RR-1）。本文件逐条记录
"确认/修复 + 回归 + 证据"。

## #63-P3-c — `PolicyLog.add` 的 `landing` 类型守卫（确认 + 补回归）

**结论：已修复（dispatcher 预检正确），本分支仅补已提交回归。**

- 生产守卫：`overload/mod/auto_combat/PolicyLog.lua:77` —
  `landing=boundedString(event.landing,64)`；`boundedString`（`:41-45`）对非字符串返回 `nil`，超长
  截断到 64。
- **新增回归**（`tests/test_auto_combat_service.lua`，P3-c 段落）：table 丢弃、number 丢弃、
  200 字符串截断为 64、合法短串 `'4,2'` 原样保留。
- **证伪（变异测试，删除后必须失败）**：
  | 变异体 | 结果 |
  | --- | --- |
  | 去掉守卫（`landing=event.landing`） | FAIL：`a non-string landing is dropped by PolicyLog (P3-c)` |
  | 只做类型守卫不做截断（limit=10^6） | FAIL：`an over-long landing is truncated to 64 characters by PolicyLog (P3-c)` |
  | 字符串原样透传（不截断） | FAIL：同上 |
  | 只把 table 归零（number 泄漏） | 通过（非失败）——已如实记录：该变异体不在本断言的判别范围内 |

## #64 / RR-1 — oldest-first `replay` 窗口断言（补回归）

`PolicyLog.window`（`PolicyLog.lua:132-146`）按返回条目的 `min/max seq` 计算，因此对最新优先的
`log`/`status` 与旧→新的 `replay` 都给出 `first_seq<=last_seq`。此前只有 newest-first 有已提交断言；
现在 `tests/test_auto_combat_service.lua` 补上 oldest-first：

- `replay{after_seq=60,limit=5}` ⇒ `entries[1].seq==61`、末条 `seq==65`、`window.count==5`、
  `window.first_seq==61`、`window.last_seq==65`（extent == **返回切片**，而非 ring 的 1..94）、
  `first_seq<=last_seq`。
- 同页 newest-first `log{limit=5}` ⇒ `window` 与 oldest-first 采用同一 extent 语义（90..94）。

**证伪**：把 `PolicyLog.lua` 换回 R-2 之前的 `window`（`2348556` 树，`first_seq=entries[#entries]`）
后，新增断言失败：`the replay window extent is the returned slice, not the ring (RR-1)`。

## #63-P3-b — 测试根推导不再静默指向规范树（修复）

**问题**：42 个可执行测试文件用
`local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')`。裸相对调用
（`lua tests/test_json.lua`，无 `/tests/` 前缀）不匹配模式，于是**静默回退**到规范检出
`game/addons/tome-mcp-bridge`，从另一个 cwd 跑出"看起来通过、其实测的是别的树"的结果。

**修复**：42 个文件统一改为从**本测试自身路径**推导根：

```lua
local root=(arg[0] or ''):match('^(.*)[/\\]tests[/\\][^/\\]+$')
if root==nil and (arg[0] or ''):match('^tests[/\\][^/\\]+$') then root='.' end
local root_name=(arg[0] or ''):match('([^/\\]+)$') or 'this test'
local root_probe=root and io.open(root..'/tests/'..root_name,'r')
assert(root_probe,'cannot resolve the addon root from '..tostring(arg[0])..'; ...')
root_probe:close()
```

- 绝对路径（`run.sh`）不变；`./tests/x.lua` / `tests/x.lua`（cwd=addon 根）**稳健解析**为 `.`；
  完全无法解析（如 `lua test_json.lua`，文件名不带 `tests/`）**fail loudly**，绝不回退到别的树。
- `tests/auto_combat_ab.lua` 是**辅助库**（被 `test_auto_combat_ab.lua` `require`，不直接执行），
  本身没有根推导，故不在 42 文件之列。

**证伪（哨兵复现，`tmp/p3-followups/p3b-defect/`）**：在备用目录构造一棵"本地树"+一棵
`game/addons/tome-mcp-bridge` 哨兵树，两侧 `Json.lua` 都 `error()` 报出自己被加载的路径。以裸相对
路径从备用目录调用：

- 修复前派生（`or 'game/addons/tome-mcp-bridge'`）→ 报 `.../tome-mcp-bridge/overload/mod/mcp_bridge/Json.lua`
  （证明**测的是规范树**）；
- 修复后派生 → 报 `./overload/mod/mcp_bridge/Json.lua`（**测本树**）；
- 文件名不带 `tests/` → `cannot resolve the addon root from check.lua; ...`（fail loudly）。

**验收**：`bash tests/run.sh` 仍 **41/41**；绝对路径、`./tests/`、cwd=addon 根的裸 `tests/` 调用
全部 41 套绿。

## #60-N2 — 同步 `docs/tome-mcp-api-fields.md`（文档卫生）

按**源码实际发射**补文档（从 emit 点反推，不发明字段）：

| 字段 | emit 点 |
| --- | --- |
| `observe.auto_combat.last_native_abort`（`code='native_timeout'`/`reason`/`cancelled`/`action?`/`talent?`/`target?`/`elapsed_ticks?`/`elapsed_frames?`） | `Runtime.lua:2074-2077`（写入 `s.auto_timeout`），`Runtime.lua:209`（`last_native_abort=s.auto_timeout or Json.null`） |
| `observe.auto_combat.pending_interaction`（条件键，`interaction` 同形） | `Runtime.lua:222-224`（仅当 `s.auto_invocation` 仍有 live 原生请求） |
| policy 事件 `action`、`elapsed_ticks`、`elapsed_frames` | `PolicyLog.lua:75/80-81`；生产写入 `AutoCombatService.lua:368-378`（notify），`AutoCombat.lua:296-299`（`native_aborted`） |
| policy 事件 `native_result`、`landing`、`missing`、`hint`、`native_message` | `PolicyLog.lua:73/77-79`；`AutoCombatService.lua:374/377`；`AutoCombat.lua:280-287`（`movement_retry`）、`AutoCombat.lua:255-269`（`denied` 详情） |

文档改动：新增 **§4.9 `auto_combat`（自动战斗摘要）**、**§6.1.1 policy 事件**表，并显式声明
**请求侧 schema 未变**（`protocol/v4/requests.schema.json` 与 `server/` 的严格请求模型无新字段；
`observe.auto_combat` 对客户端是自由形状）。同时把过期的头部基线（0.8.0/协议 3）更新为
**0.9.0 / 协议 v4**。

## 验收

| 检查 | 结果 | 证据（`tmp/p3-followups/`，均已 sha256） |
| --- | --- | --- |
| Lua 套件 | **41/41 全绿**（`test_auto_combat_service` 146 checks，含新增 7 条） | `lua-suite.log` |
| Python unittest | **39 OK** | `python-tests.log` |
| 三个 `--check` | **3/3 exit 0** | `generator-checks.log` |
| auto-combat 探针 source | **127/127** | `probe-source-run.log` + session `p3-src-01/result.json` |
| auto-combat 探针 dist | **127/127** | `probe-dist-run.log` + session `p3-dist-01/result.json` |
| 原生验收 source | **101/101** | `accept-source-run.log` + session `p3-accept-src-01/result.json` |
| 原生验收 dist | **101/101** | `accept-dist-run.log` + session `p3-accept-dist-01/result.json` |
| `tools/package.py` + parity | **68/68** 成员，归档 = manifest = 源树，0 处不符 | `package.log`、`dist/manifest.json` |
| 不变量集合 | **不变**（预算 charged 计数 / `native_pending` 不重复提交 / 手动输入收回租约 / 只读 `dry_run` / 确定性 tie-break） | 生产代码零改动（`git diff` 仅 `tests/` 与 `docs/`） |
