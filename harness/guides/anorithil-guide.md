# 半身人 / 星月术士（Halfling / Celestial-Anorithil）Insane 难度实机操作指南

> 面向 MCP 测试 Agent 的实机决策与操作手册。数据基于 ToME 1.7.6 原生代码与 MCP 桥接协议 v4。

---

## 1. 资源机制：正/负能量闭环

星月术士核心依托 **Positive（正能量）** 与 **Negative（负能量）** 双资源池。

### 1.1 资源基本属性
- **基准上限**：`max_positive = 50`，`max_negative = 50`。
- **自然回复**：战斗中与非战斗默认 `regen = +0.5/turn`（休息时可回满）。
- **维持技能占用（Sustain Reservation）**：每个激活的 Chant 占用 20 正能量上限；每个激活的 Hymn 占用 20 负能量上限。双开维持后，可用能量上限均为 `30/30`。
- **负消耗即产生**：ToME4 源码中技能声明 `positive = -15` 表示**施法产生 15 点正能量**；声明 `positive = 30` 表示**消耗 30 点正能量**。

### 1.2 能量转化与防卡死循环
- **能量互斥陷阱**：日系输出（Sunburst/Sun Flare/Firebeam）需要高正能量；月系高频技能（Moonlight Ray/Shadow Blast）需要负能量。若负能量为 0，月系技能直接无法释放；若连续消耗同系，极易空蓝。
- **核心转化枢纽（`T_TWILIGHT`）**：消耗 15 点正能量，瞬间转化为大量负能量（受 CUN 缩放，1 级约转化 25~35+ 点）。
- **标准无耗启动闭环**：
  1. `T_SEARING_LIGHT`（消耗 -15 正能量，即**白赚 15 Positive**）
  2. `T_TWILIGHT`（消耗 15 Positive，**转化为 30+ Negative**）
  3. `T_MOONLIGHT_RAY`（消耗 10 Negative 远程贯穿，CD 仅 3 回合）
  4. 8 级习得 `T_TWILIGHT_SURGE`：消耗 `positive = -10, negative = -20`，单次直接**双回（+10正/+20负）**且自身无伤。

---

## 2. 核心技能清单（精准数据速查）

| Talent ID | 类别 | 门槛 | 模式 | 消耗 | 射程/半径/形状 | CD | Direct Hit | 地面留存/自伤风险 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `T_SEARING_LIGHT` | Sunlight 1 | 0级/12魔 | 主动 | Pos: -15 (得15) | 射程 7（瞄准半径 1） | 5 | 是 | 伤害是**单体 `hit`**；地面留半径1/4回合半伤光域，`addEffect(...,selffire=false,friendlyfire=false)` → **无自伤**。`{type="ball",radius=1}` 只是**瞄准光标**，不是伤害范围 |
| `T_SUN_FLARE` | Sunlight 2 | 4级/20魔 | 主动 | Pos: 30 | 射程 0, 半径 2-4 (Self-Ball) | 12 | 是 | 致盲敌人4回合, 照亮全场；**selffire=false 无自伤** |
| `T_FIREBEAM` | Sunlight 3 | 8级/28魔 | 主动 | Pos: 30 | 射程 10 (Beam) | 12 | 是 | 穿透至最远敌人, **后续2回合初自动连发**, 每次命中回正能量 |
| `T_SUNBURST` | Sunlight 4 | 12级/36魔 | 主动 | Pos: 30 | 半径 10 (Smart Beam) | 15 | 是 | 向视野内多名随机敌人发射激光; 强化暗伤转光伤 |
| `T_MOONLIGHT_RAY`| Star-Fury 1 | 0级/12魔 | 主动 | Neg: 10 | 射程 10 (Beam) | 3 | 是 | **贯穿直线所有目标**; 无地面留存; 不自伤 |
| `T_SHADOW_BLAST` | Star-Fury 2 | 4级/20魔 | 主动 | Neg: 20 | 射程 6, 半径 3 (Ball) | 10 | 是 | **selffire~99%！** 留存 3 半径暗云 3-6 回合, **切忌近身施放** |
| `T_TWILIGHT_SURGE`| Star-Fury 3 | 8级/28魔 | 主动 | Pos: -10, Neg: -20 | 射程 0, 半径 5 (PBAoE) | 5 | 是 | 光暗双伤近身清场, **双充能神技, selffire=false** |
| `T_STARFALL` | Star-Fury 4 | 12级/36魔 | 主动 | Neg: 20 | 射程 6, 半径 1-3 (Ball) | 12 | 是 | 眩晕 4 回合 (Darkstun); **selffire 致命**，需控距离 |
| `T_TWILIGHT` | Twilight 1 | 0级/12魔 | 主动 | Pos: 15 | 自身 | 6 | - | 15 正能量转大量负能量, 充能核心 |
| `T_JUMPGATE` | Twilight 2 | 4级/20魔 | 维持 | Neg维持: 20 | 自身脚下 | 8-20 | - | 在脚下设传送门, 激活 `T_JUMPGATE_TELEPORT`(射程13-18逃生) |
| `T_MIND_BLAST` | Twilight 3 | 8级/28魔 | 主动 | Neg: 20 | 半径 10 (Ball) | 15 | 是 | 暗伤 + 混乱敌人, **selffire=false** |
| `T_CHANT_OF_FORTRESS` | Chants (Acolyte)| 0级/12魔 | 维持 | Pos维持: 20 | 自身 (瞬发 0 能量) | 12 | - | **前期核心**：+护甲, +15%硬度, +物理抗性, +物理豁免 |
| `T_CHANT_OF_RESISTANCE`| Chants (Acolyte)| 0级/12魔 | 维持 | Pos维持: 20 | 自身 (瞬发 0 能量) | 12 | - | 四系元素抗性, 远程减伤(>=3格减伤15~33%) |
| `T_HYMN_OF_SHADOWS` | Hymns (Acolyte) | 0级/12魔 | 维持 | Neg维持: 20 | 自身 (瞬发 0 能量) | 12 | - | +移速 (20~50%), +施法速度 (7~20%) |
| `T_HYMN_OF_PERSEVERANCE`| Hymns (Acolyte)| 0级/12魔 | 维持 | Neg维持: 20 | 自身 (瞬发 0 能量) | 12 | - | 眩晕、定身、致盲、混乱抗性 (20~45%) |
| `T_HEALING_LIGHT`| Light 1 | 0级/12魔 | 主动 | Pos: -10 (得10) | 自身 | 10 | - | 强力单体治疗 (20-440 HP), **可暴击, 净赚 10 正能量** |
| `T_BARRIER` | Light 3 | 8级/28魔 | 主动 | Pos: -20 (得20) | 自身 | 15 | - | 10 回合伤害吸收盾 (30-370+), **可暴击, 净赚 20 正能量** |
| `T_BLOOD_RED_MOON`| Eclipse 1 | 0级/12魔 | 被动 | 无 | - | - | - | +法术暴击率 (3%~15%) |
| `T_TOTALITY` | Eclipse 2 | 4级/20魔 | 主动 | Pos: 15, Neg: 15 | 自身 | 30 | - | 光暗穿透提升, **全星月技能冷却缩减 3~6 回合** |
| `T_HALFLING_LUCK`| Halfling 1 | 0级/14敏 | 主动 | 无 (瞬发 0 能量) | 自身 | 25-45 | - | 5 回合大量提高全豁免与全暴击率 (受 CUN 增益) |
| `T_DUCK_AND_DODGE`| Halfling 2 | 4级/20敏 | 被动 | 无 | 受到单次>10-15%生命伤害触发 | - | - | 获得 50% 闪避率与额外闪避值, 极效防猝死 |

*(注：Circles 与 Glyphs 树 10 级前锁定，前期无需分配类别点。)*

> **关于 `selffire`**：`inspect` 里只有技能**显式声明**了 selffire 才是确定值；缺省的面积形状（ball/cone）返回 `"unknown"`。`unknown` **不等于“会自伤”**——Searing Light 与 Moonlight Ray 实际都**不自伤**；真正会自伤的是用 `selffire=self:spellFriendlyFire()` 的 Shadow Blast / Starfall。

---

## 3. 属性与 1–10 级加点优先级（Insane 压力向）

### 3.1 属性加点策略
- **主属性 Magic (MAG)**：每级投入 2 点，优先满足技能法术强度与前置需求（4级需20 MAG，8级需28 MAG）。
- **副属性 Cunning (CUN)**：每级投入 1 点，提升法术暴击率、Twilight 转化量与半身人种族幸运。
- **生存补正 Constitution (CON)**：若遇到装备不足或高压词缀，可在 3、5 级挪出点数补到 15-20 CON 撑基础血量。

### 3.2 技能加点路线（严格按生存收益排序）

| 等级 | Class Talent（职业点） | Generic Talent（通用点） | 核心决策意图 |
| :--- | :--- | :--- | :--- |
| **出生(1)**| 初始自带：Searing 1, Moonlight 1, Twilight 1 | 初始自带：Hymn 1, 种族Luck 1。**首发点 Chant Acolyte 1** | **生死攸关**：立刻常驻 `T_CHANT_OF_FORTRESS`，获得物抗与护甲，免被1级野怪撕碎 |
| **2** | `T_MOONLIGHT_RAY` (2) | `T_HEALING_LIGHT` (1) | 奠定主力输出光束；解锁保命回血与正能量回充 |
| **3** | `T_SEARING_LIGHT` (2) | `T_HEALING_LIGHT` (2) 或 保留 | 增强远程引怪与起始点杀伤害；稳固抬血线能力 |
| **4** | `T_SHADOW_BLAST` (1) 或 `T_SUN_FLARE` (1) | `T_DUCK_AND_DODGE` (1) | 解锁强力控场/致盲；点出半身人被动 50% 闪避，彻底摆脱被秒风险 |
| **5** | `T_JUMPGATE` (1) | `T_CHANT_ACOLYTE` (2) | 设立应急逃生锚点；进一步强化物抗与护甲 |
| **6** | `T_TOTALITY` (1) | `T_HALFLING_LUCK` (2) | 获得爆发与全技能减 CD 窗口；强化对精英怪暴击压制 |
| **7** | `T_MOONLIGHT_RAY` (3) | `T_HEALING_LIGHT` (3) | 核心伤害质变（CD 3回合高频施放）；治疗量超 150+ |
| **8** | `T_TWILIGHT_SURGE` (1) | `T_BARRIER` (1) | **质变期**：近战双充能神技（解围首选）；常备 10 回合伤害吸收盾 |
| **9** | `T_FIREBEAM` (1) | `T_BARRIER` (2) | 超远贯穿打击（连发 3 回合），安全距离外清剿弓箭手 |
| **10** | **Cat Point 保留** 或 开 Circles；学 `T_MIND_BLAST` (1) | `T_CHANT_ADEPT` (1) 或 `T_MILITANT_MIND` (1) | `T_CHANT_ADEPT` 可在切 Chant 时解除跨层异常与负面状态 |

---

## 4. 战斗循环与站位决策

### 4.1 常态维持设置
- **正能量位（Chant）**：巨魔泥沼 1 层常驻 `T_CHANT_OF_FORTRESS`（95% 怪物为物理攻击）；若遭遇骷髅法师/元素精英切为 `T_CHANT_OF_RESISTANCE`。
- **负能量位（Hymn）**：跑图与拉扯常驻 `T_HYMN_OF_SHADOWS`（极高移速拉开距离）；若面对带眩晕/击倒的白熊、巨魔切为 `T_HYMN_OF_PERSEVERANCE`。

### 4.2 起手与循环序列
1. **远距离发现（距离 7-10）**：
   - 目标连线无障碍：先手 `T_MOONLIGHT_RAY`（穿透打残）
   - 后手 `T_SEARING_LIGHT`（击中留存光斑，迫使敌人踩光斑走来）
2. **近身推进阶段（距离 4-6）**：
   - 若负能量不足：立刻使用 `T_TWILIGHT` 转化。
   - 释放 `T_SHADOW_BLAST`：**严禁在距离 <= 3 时释放！** 仅在距离 >= 5 时向后方或敌阵中心丢，避免自己吃到范围暗伤。
3. **被近身贴脸（距离 1-2）**：
   - **绝对禁止用木杖普通攻击**！
   - 施放 `T_SUN_FLARE` 致盲周围全员（selffire=false）。
   - 施放 `T_TWILIGHT_SURGE`（8级后，无自伤高额双伤并补满双能量）。
   - 向后撤入 1 格单行通道，回头释放 `T_MOONLIGHT_RAY` 穿刺。

### 4.3 走位黄金铁律
- **坚决不打宽阔野战**：在 Trollmire 遭遇 2 只以上敌人，立即后撤寻找树木天然形成的单格瓶颈（Chokepoint），形成一对一单挑。
- **Beam 穿透对齐**：走位让两只或以上敌人排成一条直线，`T_MOONLIGHT_RAY` 单发双杀，收益翻倍。
- **逃生预案**：进入未知区域前，在安全树林后方开启 `T_JUMPGATE` 种下锚点。一旦触发危险稀有怪，直接用 `T_JUMPGATE_TELEPORT` 瞬间后跳 15 格。

---

## 5. 生存与 Insane 防猝死指南

1. **半身人初始容错极低**：1 级仅 90 HP，布甲无防。Insane 难度下黄色精英（Rare）一次暴击可打出 80+ 伤害。
2. **生命警戒线与自愈顺序**：
   - 生命值 `< 75%`：立刻启动 `T_HEALING_LIGHT`（不费回合且回正能量）。
   - 生命值 `< 60%` 且处于敌人攻击范围内：开启 `INFUSION:_REGENERATION`。
   - 承受瞬时爆发击穿 50%：半身人被动 `T_DUCK_AND_DODGE` 自动触发（50% 闪避率）；此时立即交 `INFUSION:_HEALING` 瞬抬，并在下回合后撤。
   - 遭遇致盲/定身/流血：交 `INFUSION:_WILD` 解除物理负面。
3. **双盾防御链（8级后）**：进未知房/拐角前预开 `T_BARRIER`（10回合持续，吸收一次致命伤害），破盾后利用 `T_HEALING_LIGHT` 抬血，等待下一次 Barrier。

---

## 6. Trollmire（巨魔泥沼）早期通关路线

1. **第 1 层清理策略**：
   - 出生点周围先小步探路，点亮身边视野。
   - 沿泥路（Road）边缘推进，利用泥路两侧树木遮挡视野，防止拉到深处成群狼群（Wolf pack）。
   - 击杀 1~2 只落单蠕虫/小狼升至 2 级，立刻学出 `T_HEALING_LIGHT`。
2. **下层时机**：
   - 探索完 1 层且达到 **3 级以上** 才踏入 2 层。
   - 不要贪图全图强迫症清理；若已找到下一层楼梯且周围有不可战胜的突变精英怪，果断换层。
3. **精英（Rare/Unique）怪物交战取舍**：
   - **普通巨魔 / 狼群**：单通道卡位轻松击杀。
   - **骷髅法师 / 弓箭手精英**：有高额远程穿透伤害，立即退回拐角视觉死角（LoS corner），卡视野迫使其走入近战距离后致盲击杀。
   - **带闪电/时空词缀的近战稀有**：切忌硬拼，若无 Jumpgate 或退路，尽早使用大地图脱离或绕路。

---

## 7. MCP 规范操作指南（给 Agent 的直接指令集）

### 7.1 施法统一格式
- **必须预填 target_id**，避免原生交互弹窗阻断：
  ```json
  {"action": {"type": "use_talent", "talent_id": "T_MOONLIGHT_RAY", "target_id": 12345}}
  ```
- **空地/坐标指向（如 Jumpgate/地面技）**：
  ```json
  {"action": {"type": "use_talent", "talent_id": "T_SEARING_LIGHT", "x": 24, "y": 18}}
  ```

### 7.2 决策前 Inspect 与 Observe
- **释放前校验**：用 `inspect(kind="talent", id="<ID>", target_id=<id>)` 检查：
  - `affordable == true`（能量充足）
  - `cooldown_remaining == 0`（未冷却）
  - `in_range == true`（在射程内）
  - 查看 `target_geometry` 确认形状，如果是 `ball` 且自身在半径内，坚决更换目标。
- **自身状态校验**：用 `inspect(kind="actor", id=player_id)` 查看 `computed` 块中的实际法术强度、法术暴击率与全抗。
- **战场感知**：用 `observe` 重点监控：
  - `player.resources.positive` / `negative`（剩余可用与 regen）
  - `actors[].distance`（若存在 `<= 2` 的敌人，禁用远程长 CD 技能）

### 7.3 维持技能与自动探索
- **维持技能开关**：统一使用 `set_sustain` 动作：
  ```json
  {"action": {"type": "set_sustain", "talent_id": "T_CHANT_OF_FORTRESS", "enabled": true}}
  ```
- **原生自动探索（`auto_explore`）规则**：
  - 发送 `{"action": {"type": "auto_explore"}}`。
  - **前置拦截**：只要 `observe` 中 `actors` 存在敌对生物且在视野内，游戏底层**必定拒绝**并返回 `enemies_in_sight`。**视野有怪时绝对禁止调用 auto_explore！**
  - **中断处理**：若返回 `needs_input` 或 `unsupported_interaction`，说明遭遇原生弹窗（如拾取特殊道具、升级确认），需切换交互模式或手工应答。
- **全图探索与换层判断**：
  - 调用 `tome.map`（参数 `{"mapfull": true}`）。
  - 当 `frontier_count == 0` 时表示本层无未探迷雾；结合地图上的 `>`（`GRASS_DOWN`）找到楼梯。
  - 站在楼梯上执行 `{"action": {"type": "change_level"}}`。

---

## 8. Agent 常见致命错误清单（Pitfalls）

1. **视野有怪却连点 auto_explore**：导致命令被连续拒绝（`enemies_in_sight`），白白浪费决策步甚至卡死。
2. **近距离释放 Shadow Blast / Starfall 自残暴毙**：这两个用 `selffire=spellFriendlyFire()`，ball 会连自己一起打；**Searing Light 不自伤**（单体 hit + 友方光域），可正常贴脸使用。
3. **空负能量时强打 Moonlight Ray**：返回 `blocked`/`not_affordable` 后仍然死循环施法；应立即使用 `T_SEARING_LIGHT` + `T_TWILIGHT` 恢复负能量。
4. **忘记开启 Chant / Hymn 裸奔**：不激活 `T_CHANT_OF_FORTRESS`，护甲与物抗为零，在 1 层被白熊或巨魔 2 拳秒杀。
5. **误用普通攻击**：贴脸后执行 `attack` 动作挥动 elm staff，伤害微乎其微且承受怪物反击。贴脸必须使用 `Sun Flare` 致盲或后撤拉开。
6. **忽略 blocked 状态重复发相同位移/施法**：收到 `blocked` 说明目标不可达或原地卡死，必须重读 `observe` 重新规划路径。
7. **试图通过 unlearn_talent 撤销加点**：游戏默认关闭实时退点（`respec_not_enabled`），加点一旦分配无法返还，务必按规划严格加点。
