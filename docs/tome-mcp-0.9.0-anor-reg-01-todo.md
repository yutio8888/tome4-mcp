# ToME MCP 0.9.0 — Anorithil 回归轮 D-1/D-2/D-3/D-4 证据与待办

日期：2026-09-18。Branch `fix/emergency-deny-livelock` off `main@3fe98ed`。Role `[Dev]`。merge=no。

修复说明见 [docs/tome-mcp-0.9.0-anor-reg-01-feedback.md](tome-mcp-0.9.0-anor-reg-01-feedback.md)。

## 反馈台账（全部处理，无延期项）

| finding | 必需 | 处置 | commit/TODO | 证据 id | 独立裁决 | 阻塞 |
| --- | --- | --- | --- | --- | --- | --- |
| D-1 P1 活锁 | 是 | 已实现（evaluator fall-through + typed `action_denied`） | 本分支 | 单测 trio + 原生 `critical:*` | 待新 Review | 否 |
| D-2 P2 denied 详情 | 是 | 已实现（生产映射 + AutoCombat.deny + service notify + PolicyLog 白名单/类型守卫） | 本分支 | 单测 4 处 + 原生 `critical:denied-detail` | 待新 Review | 否 |
| D-3 P2 new_enemy 暂停风暴 | 是 | 已实现（校验 mode 字段 + anorithil preset=continue + editor 同步） | 本分支 | 单测 4 处 | 待新 Review | 否 |
| D-4 P3 status 尾部一致性 | 是 | 已实现（`status.window` + semantics） | 本分支 | `test_auto_combat_service.lua` | 待新 Review | 否 |

## 证据（raw 在 `tmp/`，git-ignored；下列 sha256 为提交摘要）

Lua 41/41：`tmp/anor-livelock-evidence/lua-suite.log`
sha256 `57176b039127da0dc1f43198b505e2e81525b65677a9d0c68e3afd59f0b49dd9`

Python 39 OK：`tmp/anor-livelock-evidence/python-tests.log`
sha256 `a9e6f742893f0c7ad5042db4cdcd6c6bf67d343f563afc50d84698bca929a44e`

三个 `--check` 退 0：`tmp/anor-livelock-evidence/generator-checks.log`
sha256 `e8a37d60d7488e5dcb7acbcd37ff6e97208df9a08ab6f25bef3902b20cc50bc8`

D-1 before：`tmp/anor-livelock-evidence/repro-prefix.out`
sha256 `ae215f9087490e7d5f192b3e4d27b12216444d6b97e9d37ffa00ae2335875210`
（`decision=pause reason=no_emergency_action rule=nil`）

D-1 after：`tmp/anor-livelock-evidence/repro-fixed.out`
sha256 `fe344afab433eaa390e38ad9abb8e70f09cdb4608f87ee9e9461fc141732a681`
（`decision=act rule=melee fallback=true`）

auto-combat 原生探针（126/126 各）：
- source `anor-live-src-05`：`result.json` `1fc4be5b163111d2186608e96973197e18688faa974a9788e21f06bfca344857`；
  `game.log` `8bbc25ab2e9db2f05b408aad5d14badb5cd1b971c3f8cc65c096f3752f449b28`
- dist `anor-live-dist-01`（`dist/tome-mcp-bridge.teaa`
  `e4bc4cb53c0cb051cafca6e600096c7fac780497f96d773ca1cb17a08da73955`）：
  `result.json` `1e6dc5f6cb144f354982db9106374995a5499694c61e9ae9334fbbbf64cd0b9c`；
  `game.log` `384bf8500af67327b6a37b349648cd5873f50bb59ab742bc8eec7bab38f44a0b`

原生验收（101/101 各）：
- source `anor-live-accept-src-01`：`result.json`
  `cfa8dd9bdbf1f5589044b804f896bca6506d97615dbd8bad10f72b6bf62d6d94`；`game.log`
  `fb69351956f10345ed9987589de45bddbb236678b114b7e008e47432d3fc7499`
- dist `anor-live-accept-dist-01`：`result.json`
  `34f876e86f674910d4c2b876424910121da6ff98af9e5cd1bc8de0d137086551`；`game.log`
  `fe6824a9673b00d52467c94607cd5e010c6484b85323dd771936e3590a131f48`

## 待办

- 无未修项。所有 D-1..D-4 已实现并有回归证据；D-5（每场战斗结束即 `no_visible_enemies` stop、
  需手动 start）仍是报告中的“已声明 preset 设计取舍”，不在本次范围（记录为**后续可选**）。
- 复核（新一轮独立 `[Review]`）待派发。
