# Auto-combat class pilots (round 4): Archmage, Corruptor, Berserker

P2 roadmap continuation: the auto-combat plugin now ships three additional
class/build pilots beyond Anorithil and Sun Paladin. Data-only policies; no
arbitrary Lua in a policy; `allow_auto_combat_execution` still defaults to
`false`.

Each talent below was source-verified from the ToME 1.7.6 talent data
(`game/modules/tome/data/talents/...`) for its id, `mode`, target/geometry,
range, resource and `no_energy` before being added to the whitelist.

## Chosen pilots and talent whitelists

### 1. Archmage — Arcane/Fire (`archmage_arcane_p2`, class `mage/archmage`)

| Talent | Source | mode | target / shape | range | resource |
| --- | --- | --- | --- | --- | --- |
| `T_FLAME` | `spells/fire.lua` (Flame) | activated | hostile, bolt→beam | 10 | mana 12 |
| `T_HEAL` | `spells/aegis.lua` (Arcane Reconstruction, `short_name="HEAL"`) | activated | self heal | – | mana 25 |
| `T_ARCANE_POWER` | `spells/arcane.lua` | sustained | self buff | – | sustain mana 25 |
| `T_SHIELDING` | `spells/aegis.lua` | sustained | self buff | – | sustain mana 40 |

Preset: emergency `T_HEAL` (hp<50), `T_FLAME` damage, `T_ARCANE_POWER` +
`T_SHIELDING` sustains, `recover` wait on Flame cooldown or mana<12, melee
`attack` fallback. `T_FLAME` is a bolt below talent level 5 and a beam at/above
it, so the descriptor is the conservative `shape='beam'` with
`friendlyfire_risk='line'` (the guard checks the line either way).

### 2. Corruptor — Blight/Sanguisuge (`corruptor_blight_p2`, class `corrupted/corruptor`)

| Talent | Source | mode | target / shape | range | resource |
| --- | --- | --- | --- | --- | --- |
| `T_SOUL_ROT` | `corruptions/vim.lua` | activated | hostile, bolt | 10 | vim 10 |
| `T_BLOOD_GRASP` | `corruptions/blood.lua` | activated | hostile, bolt (`friendlyfire=false`, heals caster) | 10 | vim 20 |
| `T_DARK_RITUAL` | `corruptions/blight.lua` | sustained | self buff | – | sustain vim 20 |

Preset: emergency `T_BLOOD_GRASP` (hp<50, damage + self-heal), `T_SOUL_ROT`
damage, `T_DARK_RITUAL` sustain, `recover` wait on Soul Rot cooldown or vim<10,
melee fallback.

### 3. Berserker — Technique (`berserker_p2`, class `warrior/berserker`)

| Talent | Source | mode | target / shape | range | resource |
| --- | --- | --- | --- | --- | --- |
| `T_SHATTERING_BLOW` | `techniques/strength-of-the-berserker.lua` | activated | hostile, hit | 1 | stamina 12 |
| `T_BERSERKER_RAGE` | `techniques/strength-of-the-berserker.lua` | sustained | self buff | – | sustain stamina 20 |
| `T_DAUNTING_PRESENCE` | `techniques/conditioning.lua` | sustained | self buff | – | sustain stamina 20 |
| `T_ADRENALINE_SURGE` | `techniques/conditioning.lua` | activated, `no_energy` | self buff | – | – |

Preset: emergency `T_ADRENALINE_SURGE` (hp<50; the tree has no heal, so the
emergency layer is an instant self-buff, a valid self-preservation shape covered
by the self-target guard), `T_SHATTERING_BLOW` in melee, native `attack`
fallback, `close` wait when a visible foe is not yet adjacent, and the two
sustains.

## Candidates considered and dropped / narrowed

- **Corruptor `T_HEALING_INVERSION` (`corruption/vile-life`)**: a ball with
  `friendlyfire=false`, but it inverts healing rather than dealing damage and is
  a Defiler tree (not Corruptor); dropped as a damage adapter.
- **Corruptor `T_DRAIN` (`corruption/sanguisuge`)**: a clean vim-generating bolt
  with `friendlyblock=false`, but its range is a level function (6→10); left as a
  future resource-recovery rule rather than a second damage adapter.
- **Archmage `T_FIREFLASH` (`spells/fire.lua`) / `T_FLAMESHOCK`**: Fireflash is a
  self-fire ball (`player_selffire=true`) that the `max_selffire_risk=0` guard
  rejects, and Flameshock is a range-0 cone without an explicit `selffire`
  setting; both dropped to keep the pilot deterministic and self-safe.
- **Bulwark (`T_LAST_STAND`/`T_SHIELD_WALL`)**: defensively strong but the useful
  defensive talents are sustains, and `T_REPULSION` (the only activated defensive
  option) is a range-0 target-required area that would open a native targeting
  prompt; dropped in favour of Berserker's instant self-buff.
- **Summoner/Necromancer/Alchemist**: depend on summons/multi-select dialogs,
  outside the supported action model.

## Verification

- Lua suites all pass, including the new `test_auto_combat_pilots.lua`
  (57 checks: whitelist/catalogue, preset schema + catalogue, and crafted
  evaluator cases for emergency / damage / recover per pilot).
- Python 39/39; both `--check` generators OK.
- Native auto-combat probe **52/52** from source and `dist/*.teaa`, with
  `pilot-presets` force-learning each kit, checking `Actions.admit`, running a
  real-snapshot `dry_run` per pilot, and casting `T_FLAME` through the production
  host (`status=ok`, `energy_spent=true`).
- Native acceptance suite **100/100** from source and `dist/*.teaa`.
- Repackaged `dist/tome-mcp-bridge.teaa` sha256
  `6b86d296bbc3eaa6969c232f078cec81212fdd05bf27e024498701903572c459`.

Raw evidence stays under `tmp/tome-mcp-validation/sessions/`.

## Build / review

Branch `feat/auto-combat-class-pilots`, PR #11
(https://github.com/yutio8888/tome4-mcp/pull/11).
