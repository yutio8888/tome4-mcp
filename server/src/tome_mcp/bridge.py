"""Bounded JSON-over-TCP transport. Writes are never automatically retried."""

from __future__ import annotations

import asyncio
import json
import uuid
from typing import Any

from . import error_registry

PROTOCOL_VERSION = 4
MAX_MESSAGE = 1024 * 1024
TERMINAL = frozenset({"completed", "failed", "cancelled", "needs_input"})


class BridgeError(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        uncertain: bool = False,
        accepted: bool | None = None,
        acceptance_scope: str | None = None,
        recovery: str | None = None,
        details: dict[str, Any] | None = None,
        command_id: str | None = None,
        response_id: str | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.uncertain = uncertain
        self.accepted = accepted
        self.acceptance_scope = acceptance_scope
        self.recovery = recovery
        self.details = details
        self.command_id = command_id
        self.response_id = response_id

    def as_dict(self) -> dict[str, Any]:
        # INT-02: build the complete envelope from the generated registry so a
        # Python-side error carries category/scope/recovery too.
        result: dict[str, Any] = dict(error_registry.defaults(self.code))
        result["code"] = self.code
        result["message"] = self.message
        if self.accepted is not None or "accepted" not in result:
            result["accepted"] = self.accepted
        result["uncertain"] = bool(self.uncertain or result.get("uncertain", False))
        if self.acceptance_scope is not None:
            result["acceptance_scope"] = self.acceptance_scope
        if self.recovery is not None:
            result["recovery"] = self.recovery
        if self.details is not None:
            result["details"] = self.details
        if self.command_id is not None:
            result["command_id"] = self.command_id
        if self.response_id is not None:
            result["response_id"] = self.response_id
        return result


def _invalid_constant(value: str) -> None:
    raise ValueError("Non-finite JSON number")


class BridgeClient:
    """One configured game, one connection, serialized request/response pairs.

    Only connect() opens a socket. In particular, observe/status do not reclaim
    control after manual input or a broken connection. The game owns session IDs,
    control leases, revision checks, and command deduplication.
    """

    def __init__(self, *, token: str, port: int = 17646, timeout: float = 5.0) -> None:
        if not token:
            raise ValueError("TOME_MCP_TOKEN is required")
        if not 1 <= port <= 65535:
            raise ValueError("TOME_MCP_PORT must be between 1 and 65535")
        if not 0 < timeout <= 30:
            raise ValueError("Bridge timeout must be greater than 0 and at most 30 seconds")
        self.host = "127.0.0.1"
        self.port = port
        self._token = token
        self.timeout = timeout
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._lock = asyncio.Lock()
        self.protocol_version = PROTOCOL_VERSION

    async def _close(self) -> None:
        writer, self._writer = self._writer, None
        self._reader = None
        if writer is not None:
            writer.close()
            try:
                await asyncio.wait_for(writer.wait_closed(), timeout=0.5)
            except (OSError, TimeoutError):
                pass

    async def close(self) -> None:
        async with self._lock:
            await self._close()

    async def connect(self, mode: str = "control") -> dict[str, Any]:
        """Authenticate as an observer or explicitly acquire a control lease."""
        if mode not in {"control", "observe"}:
            raise BridgeError("invalid_connection_mode", "Choose control or observe.")
        async with self._lock:
            # Reuse a healthy socket so a second explicit connect does not race
            # the game processing the old socket's disconnect.
            if (
                self._writer is None or self._writer.is_closing()
                or self._reader is None or self._reader.at_eof()
            ):
                await self._close()
                try:
                    self._reader, self._writer = await asyncio.wait_for(
                        asyncio.open_connection(self.host, self.port, limit=MAX_MESSAGE),
                        timeout=self.timeout,
                    )
                except (OSError, TimeoutError) as exc:
                    raise BridgeError(
                        "game_unavailable",
                        "Cannot connect to the local game. Load an enabled character and check the addon port.",
                    ) from exc
            try:
                # A distinct operation is deliberate: an older addon must
                # reject observer mode, never ignore a field and take control.
                op = "connect_observer" if mode == "observe" else "connect"
                self.protocol_version = PROTOCOL_VERSION
                return await self._request(op, {"token": self._token})
            except BaseException:
                await self._close()
                raise

    async def request(self, op: str, args: dict[str, Any]) -> dict[str, Any]:
        async with self._lock:
            return await self._request(op, args)

    async def _request(self, op: str, args: dict[str, Any]) -> dict[str, Any]:
        if self._writer is None or self._reader is None or self._writer.is_closing():
            raise BridgeError("not_connected", "Call tome.connect explicitly before using the game.")
        request_id = uuid.uuid4().hex
        body = json.dumps(
            {"v": self.protocol_version, "id": request_id, "op": op, "args": args},
            ensure_ascii=True,
            allow_nan=False,
            separators=(",", ":"),
        ).encode("utf-8") + b"\n"
        if len(body) > MAX_MESSAGE:
            raise BridgeError("request_too_large", "The bridge request exceeds its size limit.")
        sent = False
        try:
            async with asyncio.timeout(self.timeout):
                self._writer.write(body)
                sent = True
                await self._writer.drain()
                line = await self._reader.readline()
                if not line:
                    raise ConnectionError("Game closed the connection")
                if not line.endswith(b"\n") or len(line) > MAX_MESSAGE:
                    raise ValueError("Incomplete or oversized response")
                reply = json.loads(line, parse_constant=_invalid_constant)
                if (
                    not isinstance(reply, dict)
                    or type(reply.get("v")) is not int
                    or reply["v"] != self.protocol_version
                    or reply.get("id") != request_id
                    or type(reply.get("ok")) is not bool
                ):
                    raise ValueError("Unexpected response envelope")
                if reply["ok"]:
                    if not isinstance(reply.get("result"), dict):
                        raise ValueError("Result must be an object")
                    return reply["result"]
                error = reply.get("error")
                if not isinstance(error, dict) or not isinstance(error.get("code"), str):
                    raise ValueError("Invalid error envelope")
                accepted = error.get("accepted")
                acceptance_scope = error.get("acceptance_scope")
                recovery = error.get("recovery")
                details = error.get("details")
                raise BridgeError(
                    error["code"], str(error.get("message", error["code"])),
                    uncertain=bool(error.get("uncertain", False)),
                    accepted=accepted if isinstance(accepted, bool) else None,
                    acceptance_scope=acceptance_scope if isinstance(acceptance_scope, str) else None,
                    recovery=recovery if isinstance(recovery, str) else None,
                    details=details if isinstance(details, dict) else None,
                    command_id=args.get("command_id"),
                    response_id=args.get("response_id"),
                )
        except BridgeError:
            raise
        except asyncio.CancelledError:
            # The in-flight action may already have happened. Drop the socket
            # so a late response cannot be mistaken for the next request.
            await self._close()
            raise
        except (OSError, TimeoutError, ValueError, UnicodeError, RecursionError) as exc:
            await self._close()
            uncertain = sent and op in {"act", "respond", "stop", "connect", "connect_observer"}
            message = "The game reply was not confirmed. Reconnect explicitly and query tome.status for the same command_id; do not submit a new action to retry it."
            if op in {"connect", "connect_observer"}:
                message = "The game connection was not confirmed. The bridge permits one TCP client at a time; check whether another MCP server/client is still connected and disconnect it before connecting again. Other causes include a stopped game or a protocol/transport failure."
            raise BridgeError(
                "bridge_timeout" if isinstance(exc, TimeoutError) else "bridge_disconnected",
                message,
                uncertain=uncertain,
                accepted=None,
                recovery="query_original_after_reconnect" if uncertain else None,
                command_id=args.get("command_id"),
                response_id=args.get("response_id"),
            ) from exc

    async def act(self, args: dict[str, Any], *, wait_ms: int = 2000) -> dict[str, Any]:
        """Submit once, then poll read-only command status for a bounded interval."""
        record = await self.request("act", args)
        return await self._poll(record, args, wait_ms=wait_ms)

    async def respond(self, args: dict[str, Any], *, wait_ms: int = 2000) -> dict[str, Any]:
        """Apply one answer to the original command; never retry a lost answer."""
        record = await self.request("respond", args)
        return await self._poll(record, args, wait_ms=wait_ms)

    async def _poll(self, record: dict[str, Any], args: dict[str, Any], *, wait_ms: int) -> dict[str, Any]:
        deadline = asyncio.get_running_loop().time() + wait_ms / 1000
        while record.get("status") not in TERMINAL:
            if record.get("status") == "awaiting_input":
                receipt = record.get("response_receipt") or {}
                if "response_id" not in args or receipt.get("state") in {"applied", "rejected"}:
                    return record
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                return {**record, "wait_expired": True}
            await asyncio.sleep(min(0.05, remaining))
            try:
                query = {"session_id": args["session_id"], "command_id": args["command_id"],
                         "include_map": args.get("include_map", True)}
                if "response_id" in args:
                    query["response_id"] = args["response_id"]
                record = await self.request("status", query)
            except BridgeError as exc:
                # Even a read-only status failure leaves the earlier accepted
                # action unresolved from this client's perspective. Keep the
                # game's recovery metadata instead of flattening it (F2).
                raise BridgeError(
                    exc.code, exc.message, uncertain=True,
                    accepted=exc.accepted, acceptance_scope=exc.acceptance_scope,
                    recovery=exc.recovery, details=exc.details,
                    command_id=args["command_id"],
                    response_id=args.get("response_id"),
                ) from exc
        return record
