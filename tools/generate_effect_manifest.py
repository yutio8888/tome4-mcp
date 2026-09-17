#!/usr/bin/env python3
"""Generate the v2 effect-manifest source pins (hashes + definition lines).

The v2 auto-combat guard is a *version-pinned* effect manifest: each talent
adapter names the native source files it was audited from, and the engine
semantics files its footprint/filter model depends on.  Those hashes and
definition lines must be regenerated from the game checkout, never typed by
hand, so a source drift fails closed instead of silently using stale metadata.

`overload/mod/auto_combat/EffectManifest.lua` is the curated semantic model;
this generator only emits the mechanical source identity table it references.

    python3 tools/generate_effect_manifest.py [--check] [--game-root DIR]
"""
from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parents[2]
GAME_MODULE = Path("game/modules/tome")
ENGINE = Path("game/engines/default/engine")

# Talent id -> (module-relative source file, exact `name = "..."` literal).
# The id is what ActorTalents:loadDefinition derives from the name; pinning the
# name literal makes the line lookup independent of load order.
TALENTS = {
    "T_CHANT_OF_FORTRESS": ("data/talents/celestial/chants.lua", "Chant of Fortress"),
    "T_HYMN_OF_SHADOWS": ("data/talents/celestial/hymns.lua", "Hymn of Shadows"),
    "T_HEALING_LIGHT": ("data/talents/celestial/light.lua", "Healing Light"),
    "T_BARRIER": ("data/talents/celestial/light.lua", "Barrier"),
    "T_TWILIGHT": ("data/talents/celestial/twilight.lua", "Twilight"),
    "T_MOONLIGHT_RAY": ("data/talents/celestial/star-fury.lua", "Moonlight Ray"),
    "T_SEARING_LIGHT": ("data/talents/celestial/sunlight.lua", "Searing Light"),
    "T_SUN_BEAM": ("data/talents/celestial/sun.lua", "Sun Ray"),
    "T_WEAPON_OF_LIGHT": ("data/talents/celestial/combat.lua", "Weapon of Light"),
    "T_FLAME": ("data/talents/spells/fire.lua", "Flame"),
    "T_HEAL": ("data/talents/spells/aegis.lua", "Arcane Reconstruction"),
    "T_ARCANE_POWER": ("data/talents/spells/arcane.lua", "Arcane Power"),
    "T_SHIELDING": ("data/talents/spells/aegis.lua", "Shielding"),
    "T_SOUL_ROT": ("data/talents/corruptions/vim.lua", "Soul Rot"),
    "T_BLOOD_GRASP": ("data/talents/corruptions/blood.lua", "Blood Grasp"),
    "T_DARK_RITUAL": ("data/talents/corruptions/blight.lua", "Dark Ritual"),
    "T_SHATTERING_BLOW": ("data/talents/techniques/strength-of-the-berserker.lua", "Shattering Blow"),
    "T_BERSERKER_RAGE": ("data/talents/techniques/strength-of-the-berserker.lua", "Berserker Rage"),
    "T_DAUNTING_PRESENCE": ("data/talents/techniques/conditioning.lua", "Daunting Presence"),
    "T_ADRENALINE_SURGE": ("data/talents/techniques/conditioning.lua", "Adrenaline Surge"),
    "T_ATTACK": ("data/talents/misc/misc.lua", "Attack"),
    # Re-admitted dynamic talents (TODO #55).
    "T_FLAMESHOCK": ("data/talents/spells/fire.lua", "Flameshock"),
    "T_FIREFLASH": ("data/talents/spells/fire.lua", "Fireflash"),
    "T_SHADOW_BLAST": ("data/talents/celestial/star-fury.lua", "Shadow Blast"),
    "T_STARFALL": ("data/talents/celestial/star-fury.lua", "Starfall"),
    # Movement tranche (v1.6): ordinary movement/teleport actions.
    "T_RUSH": ("data/talents/techniques/combat-techniques.lua", "Rush"),
    "T_SKIRMISHER_CUNNING_ROLL": ("data/talents/techniques/acrobatics.lua", "Tumble"),
    "T_PHASE_DOOR": ("data/talents/spells/conveyance.lua", "Phase Door"),
}

# Talents whose `t.target` builder the guard reads. The generator pins the exact
# `target = function` line so runtime identity can reject a same-type
# replacement loaded from another source/line.
BUILDER_TALENTS = {
    "T_MOONLIGHT_RAY", "T_SUN_BEAM", "T_FLAME", "T_BLOOD_GRASP",
    "T_SHATTERING_BLOW", "T_ATTACK",
    "T_FLAMESHOCK", "T_FIREFLASH", "T_SHADOW_BLAST", "T_STARFALL",
    "T_RUSH", "T_SKIRMISHER_CUNNING_ROLL",
}

# Engine / module semantics files the filter and footprint model is pinned to.
# These are the exact Lua files whose bodies the guard's semantics depend on;
# a mismatch disables the adapter rather than trusting stale metadata.
ENGINE_FILES = {
    "target": ("engine/Target.lua", "game/engines/default/engine/Target.lua"),
    "actor_project": ("engine/interface/ActorProject.lua", "game/engines/default/engine/interface/ActorProject.lua"),
    "map": ("engine/Map.lua", "game/engines/default/engine/Map.lua"),
    "utils": ("engine/utils.lua", "game/engines/default/engine/utils.lua"),
    "actor": ("mod/class/Actor.lua", "game/modules/tome/class/Actor.lua"),
    "actor_talents": ("engine/interface/ActorTalents.lua", "game/engines/default/engine/interface/ActorTalents.lua"),
    "combat": ("mod/class/interface/Combat.lua", "game/modules/tome/class/interface/Combat.lua"),
}


def _md5(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def _definition_line(text: str, name: str) -> int:
    pattern = re.compile(r'name\s*=\s*"' + re.escape(name) + r'"')
    lines = text.splitlines()
    for index, line in enumerate(lines, start=1):
        if pattern.search(line):
            return index
    raise SystemExit(f"talent name literal not found for {name!r}")


def _builder_line(text: str, definition_line: int) -> int:
    """First `target = function` line at/after the talent definition line."""
    lines = text.splitlines()
    pattern = re.compile(r'^\s*target\s*=\s*function')
    for index in range(definition_line - 1, len(lines)):
        if pattern.search(lines[index]):
            return index + 1
    raise SystemExit("target builder line not found after the definition line")


def generate(game_root: Path | None = None) -> str:
    workspace = Path(game_root).resolve() if game_root else ROOT.parents[2]
    module = workspace / GAME_MODULE
    if not (module / "data/talents.lua").is_file():
        raise SystemExit(f"ToME module source not found under {workspace}")
    engine_root = workspace / "game/engines/default/engine"

    lines = [
        "-- GENERATED by tools/generate_effect_manifest.py; do not edit by hand.",
        "-- MD5 is the audited source identity for the v2 effect manifest.",
        "return {",
        "    schema='tome-effect-manifest-sources/v1',",
        "    game_version='1.7.6',",
        "    engine={",
    ]
    for key, (virtual, relative) in ENGINE_FILES.items():
        path = workspace / relative
        data = path.read_bytes()
        lines.append(f"        {key}={{path='/{virtual}',md5='{_md5(data)}'}},")
    lines.append("    },")
    lines.append("    talents={")
    for talent, (relative, name) in TALENTS.items():
        path = module / relative
        text = path.read_text()
        data = path.read_bytes()
        line = _definition_line(text, name)
        builder = ''
        if talent in BUILDER_TALENTS:
            builder_line = _builder_line(text, line)
            builder = f",builder={{path='/{relative}',line={builder_line}}}"
        lines.append(
            f"        {talent}={{files={{{{path='/{relative}',md5='{_md5(data)}'}}}},"
            f"line={line}{builder}}},")
    lines.append("    },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--game-root", default=None,
                        help="ToME source root with game/ (defaults to the enclosing checkout)")
    args = parser.parse_args()
    text = generate(args.game_root)
    target = ROOT / "overload/mod/auto_combat/EffectManifestSources.lua"
    if args.check:
        assert target.is_file() and target.read_text() == text, \
            f"effect manifest sources out of date: {target}"
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    print(target.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
