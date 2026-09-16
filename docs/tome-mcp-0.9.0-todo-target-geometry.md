# 待办：技能目标几何（穿透/范围）不可见

状态：**待办**。来源：用户观察——agent 把 `Moonlight Ray`（穿透射线）当单目标用。
记录日期：2026-09-15。基线：0.9.0 / 内部协议 v4。

## 现象与证据

游戏定义（`game/modules/tome/data/talents/celestial/star-fury.lua`）：

```lua
newTalent{
    name = "Moonlight Ray",
    range = 10, direct_hit = true, reflectable = true, requires_target = true,
    target = function(self, t) return {type="beam", range=self:getTalentRange(t), talent=t} end,
    ...
}
```

实时 `inspect(kind="talent", id="T_MOONLIGHT_RAY")`：

```json
{"range":10,"requires_target":true,"target_type":"unknown"}
```

即：**穿透性（`type="beam"`）没有出现在任何字段里**，`target_type` 还是 `unknown`。

## 根因

1. `TalentQuery.query`（`TalentQuery.lua`）对 `t.target`：
   - `string` → 回该字符串；
   - `table` → `target_type="table"`；
   - `function` → `target_type="unknown"`（**不执行动态 target**，符合 QRY-01 纯度）。
   `Moonlight Ray` 是函数，所以是 `unknown`。
2. `Interactions.openTarget`（`Interactions.lua` 约 47–65 行）只捕获
   `origin.range` / `origin.radius`，**没有 `origin.type`（beam/ball/cone）**，也没有
   `selffire` / `direct_hit` / `reflectable`。
3. `Actions.execute` 的 `getTarget` 包装（约 195–230 行）在第一次原生 `getTarget`
   时**确实拿到了原生 spec `typ`（含 `typ.type`、`typ.radius`、`typ.selffire`）**，
   但目前只用于射程/自伤校验，没有写回命令结果。

影响：不只是 beam；`ball`/`cone`/`wide` 等范围形状、`radius`、`selffire`、
`direct_hit`、`reflectable` 都不可见，agent 只能靠猜。

## 建议改法

### P1 执行期回传原生目标几何（权威、不违反纯度）
- 在 `Actions.execute` 的 `getTarget` 包装里，第一次拿到 `typ` 时记录到命令：
  ```
  command.target_geometry = {
    shape   = type(typ.type)=='string' and typ.type or 'unknown',   -- beam|ball|cone|hit|...
    radius  = finite(typ.radius) and typ.radius or nil,
    range   = finite(typ.range) and typ.range or nil,
    selffire= typ.selffire==true or nil,
    piercing= typ.type=='beam' or nil,
  }
  ```
  并让 `commandView` 返回它；`settle`/`awaiting_input` 时也保留。
- 在 `Interactions.openTarget` 的 `target.grid`/`target.direction` 描述里补
  `shape` / `radius` / `selffire` / `direct_hit`。
- 这是**执行时**的原生 spec，不是为查询而运行 talent，属于纯记录。

### P2 只读 advisory（静态字段，无法覆盖动态 target）
- `TalentQuery.query` 增加：
  - `radius`（`t.radius` 为静态数字时）、`direct_hit`、`reflectable`；
  - `target_shape`：`t.target` 为**表**时取其 `type`；为函数时 `"unknown"`（不执行）。
- `server/RULES` 与字段文档说明：`target.geometry.shape`/`piercing` 在执行/交互响应里
  是权威；`inspect` 的 `target_shape` 对动态目标可能为 `unknown`。

### P3 文档/提示
- `RULES` 明确：`shape="beam"` 表示**沿直线穿透**，命中直线上的多个目标；
  瞄准最远的敌人即可覆盖前排。`shape="ball"` 带 `radius`。

## 验收

- `use_talent T_MOONLIGHT_RAY`（任意目标）结果或 `target.grid` 交互中出现
  `shape="beam"`、`piercing=true`；
- `Shadow Blast`（`type="ball"`, `radius=3`）出现 `shape="ball"`、`radius=3`；
- `inspect(talent)` 对静态 `radius`/`direct_hit`/`reflectable` 正确显示，动态 target 不执行、
  标 `unknown`；
- 新增单测（`tests/test_talent_query.lua` 静态几何 + 一个 `target.grid` 形状用例）。

## 备注

这条与"快照载荷裁剪"（成本）和"成长支持"（能力）不同：它是**信息完整性**问题——
接口本身拿得到 `typ.type`，只是没有暴露。P1 成本很小、收益明确，建议下一轮优先做。
