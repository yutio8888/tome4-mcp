"""MCP stdio entrypoint for one local ToME game."""

from __future__ import annotations

import argparse
from contextlib import asynccontextmanager
import os
from typing import Annotated, Any, Literal

from mcp.server import MCPServer
from mcp.types import ToolAnnotations
from pydantic import BaseModel, ConfigDict, Field, model_validator

from . import __version__
from .bridge import BridgeClient, BridgeError


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class MoveAction(StrictModel):
    type: Literal["move"]
    direction: Literal[1, 2, 3, 4, 6, 7, 8, 9]


class WaitAction(StrictModel):
    type: Literal["wait"]


class ChangeLevelAction(StrictModel):
    type: Literal["change_level"]


class RestAction(StrictModel):
    type: Literal["rest"]
    max_turns: int = Field(default=1000, ge=1, le=1000)


class AttackAction(StrictModel):
    type: Literal["attack"]
    target_id: str = Field(min_length=1, max_length=128)


class TalentAction(StrictModel):
    type: Literal["use_talent"]
    talent_id: str = Field(min_length=1, max_length=128)
    target_id: str | None = Field(default=None, max_length=128)
    x: int | None = Field(default=None, ge=0, le=2147483647)
    y: int | None = Field(default=None, ge=0, le=2147483647)

    @model_validator(mode="after")
    def _validate_prefill(self) -> "TalentAction":
        if self.target_id is not None and (self.x is not None or self.y is not None):
            raise ValueError("use_talent accepts either target_id or x/y, not both")
        if (self.x is None) != (self.y is None):
            raise ValueError("use_talent requires both x and y for a position prefill")
        return self


class SustainAction(StrictModel):
    type: Literal["set_sustain"]
    talent_id: str = Field(min_length=1, max_length=128)
    enabled: bool


class ActorAnswer(StrictModel):
    type: Literal["actor"]
    target_id: str = Field(min_length=1, max_length=256)


class PositionAnswer(StrictModel):
    type: Literal["position"]
    x: int = Field(ge=0, le=2147483647)
    y: int = Field(ge=0, le=2147483647)


class DirectionAnswer(StrictModel):
    type: Literal["direction"]
    direction: Literal[1, 2, 3, 4, 6, 7, 8, 9]


class OptionAnswer(StrictModel):
    type: Literal["option"]
    option_id: str = Field(min_length=1, max_length=512)


class CancelAnswer(StrictModel):
    type: Literal["cancel"]


Answer = Annotated[ActorAnswer | PositionAnswer | DirectionAnswer | OptionAnswer | CancelAnswer,
                   Field(discriminator="type")]


class SpendStatAction(StrictModel):
    type: Literal["spend_stat"]
    stat: Literal["str", "dex", "mag", "wil", "cun", "con"]


class LearnTalentAction(StrictModel):
    type: Literal["learn_talent"]
    talent_id: str = Field(min_length=1, max_length=128)


class LearnCategoryAction(StrictModel):
    type: Literal["learn_category"]
    category_id: str = Field(min_length=1, max_length=128)


class UnlearnTalentAction(StrictModel):
    type: Literal["unlearn_talent"]
    talent_id: str = Field(min_length=1, max_length=128)


class PickupAction(StrictModel):
    type: Literal["pickup"]
    item_id: str = Field(min_length=1, max_length=128)


class EquipAction(StrictModel):
    type: Literal["equip"]
    item_id: str = Field(min_length=1, max_length=128)


class UnequipAction(StrictModel):
    type: Literal["unequip"]
    item_id: str = Field(min_length=1, max_length=128)


class UseItemAction(StrictModel):
    type: Literal["use_item"]
    item_id: str = Field(min_length=1, max_length=256)


Action = Annotated[
    MoveAction | WaitAction | AttackAction | TalentAction | SustainAction | ChangeLevelAction | RestAction
    | SpendStatAction | LearnTalentAction | LearnCategoryAction | UnlearnTalentAction | PickupAction | EquipAction | UnequipAction | UseItemAction,
    Field(discriminator="type"),
]
Identifier = Annotated[str, Field(min_length=1, max_length=128)]


class ToolReply(BaseModel):
    """Business result. Check ok before using result; errors never imply rollback."""

    ok: bool
    result: dict[str, Any] | None = None
    error: dict[str, Any] | None = None


RULES = """ToME MCP Bridge protocol 3
Protocol 3 provides a read-only talent query and one-shot target prefill. In
inspect kind="talent" also returns a query
object with range, requires_target, target_type, cooldown_remaining,
current_costs, base_costs, costs_complete, affordable, readiness and, when
target_id or x/y is supplied, distance and in_range. current_costs is the
real-time cost using the native postUseTalent formula (alterTalentCost then
cost_factor, so current fatigue and effects are included); base_costs is the
stored base value and costs_complete says whether every current cost is known.
The query is advisory (query_is_advisory is true and readiness uses
readiness_reason): it never runs preUseTalent or dynamic talent cost/info
functions, so readiness stays unknown unless a stored scalar proves a block.
A use_talent may include target_id or x/y. The prefill is consumed once at the
first native getTarget. A static talent range is checked before the
talent starts (target_out_of_range); a dynamic target range is checked at that
first getTarget, and an out-of-range or self-warning prefill falls back to the
native target request instead of firing. target.forced is never set. respond's
target.grid answers are also range-checked (position_out_of_range). If the
talent asks later questions, answer them with tome.respond.
use_item uses an owned item_id through native player item
use, including power, wear rules, cooldown, charges and consumable removal.
Do not supply a target or callback in use_item; answer its actual native questions.
An identified item's activation fields describe stored power, not guaranteed
readiness. The native entrypoint decides whether use succeeds.
Ordinary actions can also yield dialog.notice after a kill, quest update or
pickup has already happened. Answer the current Close option once, then inspect
the next interaction on the SAME command. Only the top native layer is exposed.
Never repeat the original attack, move or pickup to dismiss its notice.
A talent can produce zero, one, or several input requests. awaiting_input is a pause, not
a completed command. Call tome.respond with the SAME command_id, the current
interaction_id/revision, a unique response_id, and a typed answer. Use only the
answer_types offered by the request. Retain BOTH IDs after an uncertain response;
reconnect explicitly and query status(command_id, response_id), never start the
talent again or submit another answer ID to retry it. Option IDs belong to this
interaction; buttons' labels and native meanings must be respected.

target.grid accepts coordinates or a currently perceived actor ID (including the
player). An actor answer selects its current grid; native projection may redirect
the actual target. Unknown coordinates may be chosen without revealing hidden
contents. Candidates never guarantee a valid hit or landing spot. set_sustain
uses an explicit enabled boolean; already matching the state is a no-op.

stop during input hands the native UI to the player. A cancel answer only invokes
that prompt's native cancellation, which can still let the talent continue.
needs_input is manual handoff, and execution_released=false means the old native
invocation still occupies the game: no new action or local combat may start yet.
Disconnect never answers a prompt; an orphaned prompt may be answered after an
explicit control connection if no manual handoff/context change occurred.
Native coroutine state is never saved. A save during an invocation is deferred
until it is resolved. Unsupported native UI requires manual interaction, possibly
after partial effects. Native errors are uncertain and quarantine writes until load.

Call tome.connect(mode="observe") to watch without acquiring control or stopping
Battle Companion. Observer connections cannot act or stop. The returned
control_token is null. Call tome.connect(mode="control") (the default) explicitly
to pause Battle Companion and acquire remote control. Switching back to observe
releases remote control and cancels its unstarted action; it never restarts combat.
Snapshots include Battle Companion state/actions/pause reason when installed.
control_source="battle_companion" and phase="unavailable" mean local combat owns actions.
An older bridge rejects observer mode; never fall back to control automatically.
Use session_id, control_token, and revision returned by the game. Ordinary
keyboard/mouse input, stop, saves, and scene changes can revoke control.
Read-only calls do not acquire control or reconnect. A connection error requires
an explicit connect before further calls.

Observe uses the player's existing observations. Unknown tiles and unavailable
visibility results stay unknown. Inspect cannot reveal a hidden actor. Coordinates
are zero based, x increases right and y down. Move directions use the numeric keypad:
7 8 9 / 4 . 6 / 1 2 3. Movement follows native bump and terrain behavior.

Submit one act with a unique command_id and the observed expected_revision.
Retain that command_id: a timeout does NOT mean the action did not happen.
Reconnect and use status to recover its result. Never retry by generating a new ID.
Read result.status: queued/executing/settling are pending, completed/failed/cancelled
are terminal. awaiting_input and running_native_task are pending;
needs_input requires manual interaction and may retain the execution barrier.
Native failure can consume energy. Instant talents may leave world_tick unchanged.
The returned revision changes for instant actions and relevant UI changes too.

change_level invokes the native exit command at the player's current tile. A
completed level_changed result includes the new level_instance_id and scene.
Scene changes revoke the lease: explicitly connect again before the next action.
A native confirmation dialog returns needs_input; do not submit another exit ID
to repeat it. Inspect the visible dialog summary and resolve it manually.

rest starts native resting, including its normal recovery rules. max_turns (1 to
1000, default 1000) is a strict upper bound including the first turn. Poll status
with the original command_id; turns_executed and stop_reason explain progress.
Enemies, damage, detrimental effects, dialogs, stop or lost control interrupt it.
No reconnect or load resumes an interrupted rest. Native completion may include
cooldown recovery; it is not a command to add health directly.

Set include_map=false on observe, act or status to omit map cells from replies.
Every map reports its radius and window bounds; replace only those cells within
the same level_instance_id, never discard previously observed outside cells or
merge maps from different level instances. Act snapshots use radius 8 by default.
World-map terrain uses audited native wilderness visibility; dungeon terrain
retains its FOV and ESP guards. known means observed by this bridge session;
visible means currently seen. Native map memory is not imported. Unseen cells
do not reveal names or entrances. is_exit marks an observed entrance; name is
its visible label. block_status describes terrain only, not a promise that a
move or change_level action will succeed. Use the returned native action result.
Observe events are changes to the existing player-visible log, not a structured
combat simulator. Pass events.cursor as events_after for incremental pages, and
check events.gap/has_more. A remove event only describes log history changes.
Inventory names and base combat fields are read without identifying objects or
invoking combat calculations. Base values are not final damage or success odds.
A talent query is the same kind of advisory read; query_is_advisory
and costs_complete show whether the value is exact, and the native action still
decides the outcome.

Inspect kind="progression", id="player" for the player's available talent trees,
raw levels, point costs and audited requirements. Unknown dynamic requirements
remain unknown; the native action checks them again. spend_stat spends one stat
point, learn_talent spends one class or generic point, and learn_category spends
one category point to unlock a known locked tree or improve its mastery once.
unlearn_talent refunds one point from a recently learnt talent, inside the
native last-learnt window and out of combat; readiness is reported under
respec.unlearnable. This is native respec only: stats and unlocked categories
are not refundable outside an open native level-up dialog, and the bridge does
not fabricate one. Prodigies and evolutions are never unlearnable. These are committed native changes, not a reversible build preview. Learning a
talent does not imply this bridge supports activating it: check capabilities.

Snapshot ground.items contains currently visible ground items; pickup accepts an
item_id at the player's current tile. equip and unequip accept an owned item_id
and use native inventory rules, including callbacks, requirements and time.
Inspect kind="item" with its returned ID for current known item details. Ground
IDs belong to their session, level and location; inventory IDs belong to their
session. Re-observe after each change because stacking and equipment replacement
can change locations or IDs. No force, arbitrary destination or callback is exposed.
An uncertain failure can mean native callbacks partially changed the character;
the bridge then restricts the session to observation until a fresh load.

Check capabilities and each current interaction. The bridge automates audited
native target, confirmation, list and inventory-selection prompts from the active
talent, plus bounded native rest tasks. UI outside these providers, stat or
category respec and character creation require manual interaction. Inventory
choices reflect the
currently displayed native filter/tab. List options are paged with status
options_offset and identified by opaque IDs; never select by duplicate labels.
Use stop to cancel queued work or hand off input; it cannot undo an action.
"""


def create_server(bridge: BridgeClient) -> MCPServer:
    @asynccontextmanager
    async def lifespan(_server: MCPServer):
        try:
            yield {}
        finally:
            await bridge.close()

    server = MCPServer(
        "tome-mcp", version=__version__, lifespan=lifespan,
        instructions="Control the local ToME game through structured snapshots and one native action at a time. Read tome://rules first. Check each tool's ok field and retain command_id for recovery.",
        log_level="WARNING",
    )
    read = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
    write = ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=False, openWorldHint=False)

    async def call(op: str, args: dict[str, Any]) -> ToolReply:
        try:
            return ToolReply(ok=True, result=await bridge.request(op, args))
        except BridgeError as exc:
            return ToolReply(ok=False, error=exc.as_dict())

    @server.tool(name="tome.connect", annotations=write)
    async def connect(mode: Literal["control", "observe"] = "control") -> ToolReply:
        """Connect in observe mode to watch local combat without taking control (null control_token). Control mode, the default, pauses Battle Companion and acquires a fresh lease. Returns session_id, mode, control_token, revision, capabilities and snapshot. Never fall back from observe to control automatically."""
        try:
            return ToolReply(ok=True, result=await bridge.connect(mode))
        except BridgeError as exc:
            return ToolReply(ok=False, error=exc.as_dict())

    @server.tool(name="tome.observe", annotations=read)
    async def observe(session_id: Identifier, radius: Annotated[int, Field(ge=1, le=12)] = 8,
                      include_map: bool = True, events_after: Annotated[int, Field(ge=0)] | None = None) -> ToolReply:
        """Read player-view state, scene, progression, inventory and visible log events without advancing the game. Set include_map=false for a compact snapshot. Pass events.cursor as events_after for subsequent event pages; respect gap/has_more. Map bounds describe only this response's window."""
        args = {"session_id": session_id, "radius": radius, "include_map": include_map}
        if events_after is not None:
            args["events_after"] = events_after
        return await call("observe", args)

    @server.tool(name="tome.inspect", annotations=read)
    async def inspect(session_id: Identifier, kind: Literal["talent", "actor", "progression", "item"], id: Identifier,
                      target_id: Identifier | None = None,
                      x: Annotated[int, Field(ge=0, le=2147483647)] | None = None,
                      y: Annotated[int, Field(ge=0, le=2147483647)] | None = None) -> ToolReply:
        """Inspect a learned talent, visible actor, owned/visible item by its returned ID, or the progression tree with kind=progression and id=player. kind=talent adds a read-only query with range, costs, cooldown, affordability and readiness; pass target_id or x/y to include distance. Reads never evaluate dynamic talent descriptions or identify objects. Unavailable details remain unknown."""
        args: dict[str, Any] = {"session_id": session_id, "kind": kind, "id": id}
        if target_id is not None:
            args["target_id"] = target_id
        if x is not None:
            args["x"] = x
        if y is not None:
            args["y"] = y
        return await call("inspect", args)

    @server.tool(name="tome.act", annotations=write)
    async def act(
        session_id: Identifier,
        control_token: Identifier,
        command_id: Identifier,
        expected_revision: Annotated[int, Field(ge=0)],
        action: Action,
        wait_ms: Annotated[int, Field(ge=0, le=10000)] = 2000,
        include_map: bool = True,
    ) -> ToolReply:
        """Submit one native action with revision checking and game-side deduplication. Poll up to wait_ms for a decision boundary. If pending or uncertain, use status with the SAME command_id; never resend under a new ID. Move may bump-attack or trigger native terrain interactions. Talent support comes from capabilities."""
        args = {
            "session_id": session_id, "control_token": control_token,
            "command_id": command_id, "expected_revision": expected_revision,
            "action": action.model_dump(exclude_none=True),
            "include_map": include_map,
        }
        try:
            return ToolReply(ok=True, result=await bridge.act(args, wait_ms=wait_ms))
        except BridgeError as exc:
            return ToolReply(ok=False, error=exc.as_dict())

    @server.tool(name="tome.status", annotations=read)
    async def status(session_id: Identifier, command_id: Identifier, include_map: bool = True,
                     response_id: Identifier | None = None,
                     options_offset: Annotated[int, Field(ge=0, le=2147483647)] | None = None) -> ToolReply:
        """Read the original command result without executing it again. Use after a pending act or after explicitly reconnecting following an uncertain result."""
        args = {"session_id": session_id, "command_id": command_id, "include_map": include_map}
        if response_id is not None:
            args["response_id"] = response_id
        if options_offset is not None:
            args["options_offset"] = options_offset
        return await call("status", args)

    @server.tool(name="tome.respond", annotations=write)
    async def respond(session_id: Identifier, control_token: Identifier, command_id: Identifier,
                      interaction_id: Identifier, response_id: Identifier,
                      expected_revision: Annotated[int, Field(ge=1)], answer: Answer,
                      wait_ms: Annotated[int, Field(ge=0, le=10000)] = 2000,
                      include_map: bool = True) -> ToolReply:
        """Answer the current native interaction exactly once. Keep the original command_id and a unique response_id. Wait for the next input or command result; on uncertainty query those IDs, never repeat the talent. Cancel preserves native cancellation semantics and can produce further effects or questions."""
        args = {"session_id": session_id, "control_token": control_token, "command_id": command_id,
                "interaction_id": interaction_id, "response_id": response_id,
                "expected_revision": expected_revision, "answer": answer.model_dump(), "include_map": include_map}
        try:
            return ToolReply(ok=True, result=await bridge.respond(args, wait_ms=wait_ms))
        except BridgeError as exc:
            return ToolReply(ok=False, error=exc.as_dict())

    @server.tool(name="tome.stop", annotations=write)
    async def stop(session_id: Identifier, control_token: Identifier) -> ToolReply:
        """Revoke remote control and cancel unstarted work. Already executed actions and native world settlement are not undone."""
        return await call("stop", {"session_id": session_id, "control_token": control_token})

    @server.resource("tome://rules", mime_type="text/plain")
    def rules() -> str:
        """Read the control, observation, action, and recovery rules."""
        return RULES

    return server


def main() -> None:
    parser = argparse.ArgumentParser(description="ToME MCP stdio server (local TCP bridge)")
    parser.add_argument("--port", type=int, default=None, help="Game addon port; default TOME_MCP_PORT or 17646")
    parser.add_argument("--timeout", type=float, default=5.0, help="Per-request bridge timeout in seconds (default 5)")
    args = parser.parse_args()
    try:
        port = args.port if args.port is not None else int(os.environ.get("TOME_MCP_PORT", "17646"))
        bridge = BridgeClient(token=os.environ.get("TOME_MCP_TOKEN", ""), port=port, timeout=args.timeout)
    except ValueError as exc:
        parser.error(str(exc))
    try:
        create_server(bridge).run(transport="stdio")
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
