# ToME MCP server 0.9.0

ToME MCP Bridge 的本地 stdio 服务，使用官方 Python SDK `mcp==2.2.0`。

完整游戏安装、客户端配置和工具使用说明见 [addon README](../README.md)。

从仓库根目录安装并启动：

```sh
python3 -m venv server/.venv
server/.venv/bin/python -m pip install -e server
TOME_MCP_TOKEN='与你的游戏设置相同的凭据' server/.venv/bin/python -m tome_mcp
```

环境变量：`TOME_MCP_TOKEN` 必填；`TOME_MCP_PORT` 默认 `17646`。桥接地址固定为 `127.0.0.1`。可用 `--port` 和 `--timeout` 覆盖端口和单次网络请求超时。

服务不会自动控制游戏。`tome.connect(mode="observe")` 只读旁观，适合观察 Battle Companion；`mode="control"`（缺省）暂停助手并获取远程控制。旁观模式不会在旧版 addon 上自动回退到控制模式，请同时更新游戏 addon 与 Python 服务到 0.9.0。

0.9.0 起协议 **4** 是唯一版本（v1/v2/v3 已移除）：写入使用规范序号 `cmd-<seq>` 与有界命令账本，`connect`/`observe`/`status` 返回 `history`，旧协议请求返回 `protocol_mismatch`。只读技能查询与一次性目标预填：`tome.inspect(kind="talent", id=..., target_id=...)`（或传 `x`/`y`）额外返回 `query`，含 `range`、`requires_target`、`target_type`、`cooldown_remaining`、`current_costs`、`base_costs`、`costs_complete`、`affordable`、`readiness`、逐资源 `resource_checks` 以及可选 `distance`/`in_range`；当前费用未知时 `affordable` 返回 `unknown`，不用基础费用猜测。查询**不提交任何游戏动作**、不泄露玩家未获知信息；除此之外可调用当前实时的动态技能 getter/builder，也**不承诺**零副作用或零 RNG（动态求值报错/缺失/返回 `nil` 时保留 `unknown`）。`use_talent` 可带 `target_id` 或 `x`/`y`，在第一次原生 `getTarget` 消费一次后交还原生目标流程，并按静态/动态射程拒绝越程或回退原生提示。

0.6.0 增加 `dialog.notice` 和 `use_item`。击杀、剧情、拾取后的说明窗口逐层关闭，同一命令保留原有副作用和执行占用；物品使用走原生协程、充能与消耗清理，不按物品名称登记脚本。使用 `{"type":"use_item","item_id":"当前拥有的物品ID"}`，按返回的实际交互回答，禁止重放原始动作来关闭窗口。

0.5.0 增加 `tome.respond`、连续原生交互和 `set_sustain`。目标、方向、确认、分页列表和物品选择来自实际原生界面；技能中的原生休息受生命周期和回合预算跟踪。在 `awaiting_input` 时回答，并在不确定结果后保留 command_id / response_id 查询。详见 [v3 契约](../docs/tome-mcp-v3-talent-query.md)。

0.4.0 增加 `spend_stat`、`learn_talent`、`learn_category` 单点成长与 `pickup`、`equip`、`unequip` 物品动作；inspect 支持 `progression`（id 为 `player`）和 `item`，快照报告当前可见地面物品。所有写入保留既有 command_id 去重、控制租约、原生条件和结算语义。该版本的特殊物品流程、任意对话、洗点和未适配技能仍需原生界面。

0.3.0 增加 `change_level`、有 1–1000 回合上限的原生 `rest`，以及普通 Berserker 的 Stunning Blow、Warshout 和 Healing / Regeneration / Wild 纹身适配。observe / act / status 支持 `include_map=false`，observe 支持 `events_after` 日志游标。快照增加场景、成长、装备背包和对话摘要。换层后须显式重新 connect；休息的重复查询使用原 command_id，不会恢复已中断任务。

当前结果见 [验收记录](../VALIDATION.md)；此前普通战斗恢复闭环见 [0.3.0 历史交付](../docs/tome-mcp-campaign-improvements.md)。

协议错误／网络超时不会重发动作。需要恢复时显式 connect，再使用原命令 ID 查询 status；只查询结果可使用旁观模式。

本地回归：

```sh
PYTHONPATH=server/src server/.venv/bin/python -m unittest discover -s server/tests -v
```

这些测试包含真实 MCP stdio 与假 TCP 对端；真实游戏端到端验收见 addon 的测试说明和验收记录。

0.6.1 修复世界地图可见地形与入口漏报；只使用经校验的原生世界地图可见缓存，保留地牢 ESP、失明及未知格保护。地图记忆限于桥接会话实际观察过的格子，通行标记只描述地形，进入操作仍由原生命令判定。

0.7.0 增加原生 Chat 选项、奖励和告别页（`dialog.choice` / `native_ui="Chat"`）。分页、去重和回执继续使用现有接口；读取不执行对话条件。换层触发 Chat 时显式 connect 后查询原 command_id，再逐页 respond；不要再次移动或换层。自动保存延后到交互结束，原生 Chat 没有取消选项时不声明 cancel。
