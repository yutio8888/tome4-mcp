# P3 first slice — legacy assistant adapter (generation only)

Date: 2026-09-17 · branch `feat/p3-assistant-adapter` · design
[tome-mcp-auto-combat-plugin-design.md](tome-mcp-auto-combat-plugin-design.md) v1.3
§15 row 4 ("fixed-version assistant config adapter — generate only, human
confirms").

**P3 is generation-only and long-term maintenance.** It translates a pinned
assistant configuration into an auto-combat **policy draft**. It never executes
assistant logic, never calls the assistant at runtime, and never
approves/activates/starts a run. A human confirms the draft before
`approve`/`activate`. Execution stays behind
`allow_auto_combat_execution` (default **off**) and `change_level` stays opt-in
(default **off**).

## 1. Pinned version

| | |
| --- | --- |
| Addon | `tome-auto_talent_assistant` (`game/addons/tome-auto_talent_assistant`) |
| Addon version | **2.3.9** (`addon_version = {2,3,9}`) |
| Game | ToME **1.7.4** (`version = {1,7,4}`) |
| Export format | **`tome-auto-combat-assistant-export/v1`** |

`AssistantAdapter.detect(config)` pins the addon id, `addon_version` and the
export format. Any mismatch is refused with `assistant_version_mismatch` /
`unsupported_format` / `unknown_addon` / `missing_assistant`, reporting the
expected and got values.

## 2. Why a normalized export, not `.tata` / `actor.Assistant`

The assistant does **not** expose a stable ABI. Its persisted form is a
pointer-rebuilt `.tata` text format (`_and`/`_or`/`_orAnd` renumbered by
`saveNum`) and its runtime state is a 10k-line dialog module's
`actor.Assistant` table whose conditions are numeric `conditionType` indices
with per-type parameter layouts. Parsing that would mean guessing
version-specific internals, which the design forbids.

Instead the adapter targets the explicit, documented **normalized export**
below. A generator/human maps the assistant config to it; the adapter then does
a field-by-field mapping and reports anything it does not understand. Unknown
top-level/`settings`/entry keys are reported as `unsupported_field`.

## 3. Field mapping

| Export field | Policy | Notes |
| --- | --- | --- |
| `settings.max_actions_per_tick` | `limits.max_actions_per_tick` | default 1 |
| `settings.min_hp_pct` | `safety.min_hp_pct` | |
| `settings.flee_below_hp_pct` | `safety.flee_below_hp_pct` | clamped to `min_hp_pct` + warning `flee_above_min_hp` |
| `settings.pause_on_new_enemy` | `safety.pause_on_new_enemy` | |
| `settings.pause_on_unknown_safety` | `safety.pause_on_unknown_safety` | |
| `settings.max_selffire_risk` | `safety.max_selffire_risk` | |
| `settings.default_target` | `targeting.default` | invalid selector → warning + `nearest_hostile` |
| `sustains[].talent` | `sustains[].talent` | only `Schema.SUSTAINS`; else `unsupported_sustain` |
| `sustains[].priority` / `min_resource_pct` | same | |
| `talents[].talent` / `when` / `priority` / `id` | rule `id`/`priority`/`when` | |
| `talents[].action` | `then.action` | default `use_talent`, except `T_ATTACK` → `attack` |
| `talents[].target` | `then.target` | default from the catalogue (`self` vs `nearest_hostile`) |
| `talents[].emergency` | rule `emergency:true` | dropped + warning for a non-self talent |

Condition trees (`always`/`all`/`any`/`not` + predicate leaves) are passed
through only when every leaf is a `PolicySchema` predicate. If any leaf is
unsupported the whole rule is dropped and reported (`unsupported_condition`)
rather than silently weakening the condition.

## 4. Unsupported / excluded (recorded, never guessed)

- **Native activities**: `rest`, `auto_explore` and `change_level` are never
  generated (`action_not_generated`); assistant "Z"/rest automation is not a
  policy rule.
- **Assistant-only talents/actions**: any talent not in `Schema.TALENTS` or any
  action not in `Schema.ACTIONS` is reported (`unsupported_talent` /
  `unsupported_action`) and dropped.
- **Sustain talents listed as active talents**: reported (`talent_is_sustain`)
  and dropped; declare them under `sustains`.
- **`has_effect` / `computed`**: accepted as data (the draft still validates)
  but warned `condition_unknown_at_runtime`, because the current auto-combat
  host answers them `unknown`. (Per the maintainer's getter policy, values a
  player can see on the character panel or in a hover/tooltip are considered
  auditable; wiring those host getters is a separate, future enablement and
  out of this generation-only slice.)
- **Unknown export keys**: reported `unsupported_field`.
- If no supported rule remains, the adapter returns `no_supported_rules`
  together with the warnings/unsupported report (no empty draft).

## 5. MCP path (draft only)

`tome.policy policy_op="import_assistant"` accepts `document` (a JSON string)
or `config` (an object), plus optional `store` (default **false**):

- generation only → returns `{imported, draft, hash, warnings, unsupported,
  version}` and stores nothing; allowed on an **observe** connection because it
  is a pure translation/read;
- `store=true` → additionally writes the draft via `set_draft` and persists it
  on the character (control-only; refused with `read_only_connection` in
  observe mode);
- it never calls `approve`, `activate`, `start`, `pause` or `resume`.

Human flow: `import_assistant` → review `draft` + `warnings`/`unsupported` →
`set_draft` (or `store=true`) → human `approve` → `activate` (local
authorization) → `start`.

## 6. Validation

- Adapter unit tests (`tests/test_auto_combat_assistant.lua`): **44 checks** —
  pinned accept, wrong version/format refuse, unsupported talent/action/sustain
  and field reporting, `condition_unknown_at_runtime`, safety clamps,
  determinism, `change_level` never generated, and the service draft-only path.
- Checked-in fixtures: `tests/fixtures/assistant/{anorithil_pinned,wrong_version,
  wrong_format,unsupported_only}.json`.
- Native probe: **27/27** on source and `dist/*.teaa`, including
  `assistant-import` (generate + validate + unsupported report + draft-only
  store + wrong-version refusal).
- Lua 32 suites / 101,901 checks; Python 33 tests; both `--check` generators
  green; `dist/tome-mcp-bridge.teaa` 59 files, SHA-256
  `d16433cbc93b38fa20df37da8e0b6d232473c06b17e9e2e838caf0579bc66bfb`.
