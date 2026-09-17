# Movement test fixtures — S3 (Shadowblade + dummy) and S4 (Temporal Warden swap)

Status: **design proposal** (0.9.0). These fixtures are used by the per-slice live
tests in `docs/tome-mcp-0.9.0-movement-adapter-factory-design.md` §13.1. They are
**test-only addons** (never shipped in the production addon) and are built when
their slice is ready to test.

## 1. Existing mechanism (reuse, do not reinvent)

The harness already creates a configured character through a **birth addon**:

- `tmp/mcp-play-support/agent-play.py` loads `tmp/mcp-play-support/tome-<TOME_BIRTH_ADDON>`
  as an extra addon (default `mcp-play-birth-ham`) and runs the game with
  `-Eset_addons={'mcp-bridge','<birth>'}`, `no_birth_popup=true`,
  `allow_auto_combat_execution=true` (session settings only).
- The birth addon binds `ToME:birthDone` and force-learns talents with
  `p:learnTalent(id, true[, level])` (e.g. `tome-mcp-play-birth-hai2/hooks/load.lua`),
  then prints a `[MCPPlayBirth]` JSON status line (name, level, life, zone,
  descriptor, which talents are known, `cheat=false`).
- Character race/class/difficulty are selected through the birth descriptor /
  runtime metadata; cheat mode stays `false` (`assert(not config.settings.cheat)`).

The fixtures below follow exactly that pattern; only the class, the force-learned
talents (with levels), and one **deterministic on-level spawn** differ.

## 2. S3 fixture — `mcp-play-birth-sb` (Shadowblade + training dummy)

Purpose: exercise the **movement + effect** path with `T_SHADOWSTEP` (a movement
talent whose landing also attacks), attacking a **puppet**.

- **Character**: race Halfling (or Cornac), class **Shadowblade** (`rogue.lua:100`;
  the Rogue subclass that owns `cunning/shadow-magic`, `rogue.lua:135`). Equip the
  starting daggers so the Shadowstep attack can resolve (Shadowblade is an
  offhand-dagger class).
- **Force-learn**: `T_SHADOWSTEP` at level 1 (`learnTalent('T_SHADOWSTEP', true, 1)`);
  optionally `T_DUAL_WEAPON_TRAINING`/a basic attack if the class does not start
  with it. Keep `cheat=false`.
- **Spawn a training dummy**: a **test-only NPC** added to the starting level,
  placed deterministically a few tiles from the player and **visible**:
  - an `Actor` (`type="humanoid"`, `subtype="dummy"`, a distinct name such as
    `Training Dummy`), **very high `max_life`** (effectively unkillable within the
    test), `ai="none"` (does not act), no retaliation, and an **enemy faction**
    so movement talents treat it as a target (Shadowstep requires a visible actor).
  - placed ~4–5 tiles away so Shadowstep must relocate the player to attack, and
    the dummy must be in the player's field of view.
  - spawn once, via a `Game:loaded`/`ToME:loaded` (or first `onTickEnd`) hook that
    adds it to `game.level` near `game.player` and then removes itself; the hook must
    be idempotent and must not spawn on reload.
- **Evidence/verification**: the play agent starts the preset, positions so the
  dummy is the nearest visible hostile at range, and uses the plugin; the report
  must show `T_SHADOWSTEP` executed with a settled postcondition (final adjacency
  to the dummy + the attack component), and that the **effect was guarded**
  (S3 composition) rather than silently skipped. Then stop.

## 3. S4 fixture — `mcp-play-birth-tw` (Temporal Warden swap)

Purpose: exercise the **two-subject `swap`** with `T_DIMENSIONAL_STEP` at
effective talent level 5 (the actor-target swap branch).

- **Character**: race Halfling (or Cornac), class **Temporal Warden**
  (`chronomancer.lua:150`; owns `chronomancy/spacetime-weaving`, `:197`).
- **Force-learn**: `T_DIMENSIONAL_STEP` and set it to **level 5**
  (`learnTalent('T_DIMENSIONAL_STEP', true, 5)`), so the TL5 actor/swap branch is
  available. Keep `cheat=false`.
- **Spawn a swap target**: a normal **enemy monster** (e.g. a low-damage,
  high-life test NPC) placed a few tiles away and visible, so the player can target
  it with Dimensional Step and **successfully swap positions**.
- **Evidence/verification**: the play agent targets the monster with
  `T_DIMENSIONAL_STEP`; the report must show a **successful swap** — the player's
  and the monster's post-positions exchanged (plus any effect on the monster) —
  and that both actors' postconditions are recorded. Then stop. If the swap fizzles
  (resistance), retry until one success or record the fizzle with evidence.

## 4. Shared implementation checklist (when each slice is ready)

1. Addon skeleton `tmp/mcp-play-support/tome-mcp-play-birth-<x>/{init.lua,hooks/load.lua}`
   with `for_module='tome'`, `version={1,7,6}`, `weight=100100`, `hooks=true`,
   `superload=true` (mirror `tome-mcp-play-birth-hai2`).
2. `hooks/load.lua`: bind `ToME:birthDone` to select the class, force-learn the
   talents at the required levels, and print the `[MCPPlayBirth]` JSON status.
3. One deterministic, idempotent spawn hook for the dummy/monster (S3/S4), placed
   near the player and player-visible; it must not depend on hidden state.
4. `agent-play.py` run with `TOME_BIRTH_ADDON=mcp-play-birth-<x>`; session-only
   `allow_auto_combat_execution=true`; use the session wrappers.
5. Declared metrics per the slice (S3: Shadowstep used + attack postcondition + the
   effect guarded and its footprint composed; S4: swap post-positions + any effect);
   raw evidence under `tmp/`, summary + sha256 committed.
6. The fixtures are **test-only**; they never enter the production addon or `dist`.

## 5. Open uncertainties

- Whether the Shadowstep attack resolves with the starting equipment at level 1, or
  a specific dagger/offhand setup is required in the fixture.
- Whether a `ai="none"` enemy dummy is attacked by the talent's adjacency branch
  (it should be, since it is a visible hostile actor); confirm in the fixture run.
- Dimensional Step's TL5 swap has resistance/fizzle branches; the fixture must
  record a fizzle as `NOT_OBSERVED` and retry rather than claiming a swap.
- Exact dummy/monster definitions (faction, AI flags, immunities) may need tuning so
  the dummy neither dies nor acts.

## 6. Post-acceptance plan (maintainer)

After **all four slices (S1–S4) are accepted and merged**, resume the **regular
test subagent** (the ordinary play-test loop) with a **Halfling / Celestial-Anorithil
(星月术士)** Insane/Roguelike run on the merged build, using the standard metrics,
to re-validate the whole plugin on the pilot build after the movement work.
