"""A controllable TCP peer for client/protocol tests, not native game acceptance."""

import asyncio
import json


class FakeGame:
    def __init__(self):
        self.requests = []
        self.commands = {}
        self.clients = set()
        self.tasks = set()
        self.connections = 0
        self.fragment = False
        self.wrong_id = False
        self.drop_act_reply = False
        self.drop_response_reply = False
        self.interaction_steps = 0
        self.pending = False
        self.legacy_bridge = False
        self.status_error = None
        self.token = "test-token"
        self.snapshot = {"session_id": "s1", "revision": 7, "phase": "ready", "world_tick": 0}

    async def __aenter__(self):
        self.server = await asyncio.start_server(self.handle, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, *_):
        self.server.close()
        await self.server.wait_closed()
        for writer in list(self.clients):
            writer.close()
        if self.tasks:
            await asyncio.gather(*self.tasks, return_exceptions=True)

    async def handle(self, reader, writer):
        task = asyncio.current_task()
        self.tasks.add(task)
        self.clients.add(writer)
        self.connections += 1
        try:
            while line := await reader.readline():
                request = json.loads(line)
                self.requests.append(request)
                op, args = request["op"], request["args"]
                reply = {"v": request["v"], "id": "wrong" if self.wrong_id else request["id"], "ok": True}
                if op in {"connect", "connect_observer"}:
                    if self.legacy_bridge:
                        reply.update(ok=False, error={"code": "protocol_mismatch", "message": "Old bridge"})
                    elif args["token"] != self.token:
                        reply.update(ok=False, error={"code": "unauthorized", "message": "Authentication failed"})
                    else:
                        reply["result"] = {
                            "session_id": "s1", "control_token": None if op == "connect_observer" else "c1", "revision": 7,
                            "mode": "observe" if op == "connect_observer" else "control",
                            "protocol_version": request["v"],
                            "capabilities": {"actions": ["wait", "move"]}, "snapshot": self.snapshot,
                        }
                elif op == "act":
                    record = {"command_id": args["command_id"], "status": "queued"}
                    self.commands[args["command_id"]] = record
                    if self.interaction_steps:
                        record.update(status='awaiting_input',revision=8,
                                      interaction={'interaction_id':'i1','kind':'target.grid'})
                    reply["result"] = record
                    if self.drop_act_reply:
                        continue
                elif op == "respond":
                    record=self.commands[args['command_id']]
                    record['response_receipt']={'response_id':args['response_id'],'state':'queued'}
                    reply['result']=record
                    if self.drop_response_reply:
                        continue
                elif op == "status":
                    if self.status_error is not None:
                        reply.update(ok=False, error=self.status_error)
                    else:
                        record = self.commands[args["command_id"]]
                        if record.get('response_receipt',{}).get('state')=='queued':
                            record['response_receipt']['state']='applied'
                            self.interaction_steps-=1
                            if self.interaction_steps:
                                record['interaction']={'interaction_id':'i2','kind':'target.grid'}
                                record['revision']=9
                            else:
                                record['status']='completed'
                        elif not self.pending and not self.interaction_steps:
                            record.update(status="completed", energy_spent=1000, snapshot=self.snapshot)
                        reply["result"] = record
                elif op == "list_collection":
                    req = args["request"]
                    reply["result"] = {
                        "view_id": "view-1", "session_id": "s1", "level_instance_id": "l1",
                        "captured_revision": 7, "current_revision": 7, "historical": False,
                        "collection": req.get("collection", "inventory"), "items": [],
                        "returned_count": 0, "total_count": 0, "capture_complete": True,
                        "has_more": False, "next_cursor": None, "expires_in_ms": 120000,
                    }
                elif op == "stop":
                    for record in self.commands.values():
                        if record["status"] == "queued":
                            record["status"] = "cancelled"
                    reply["result"] = {"stopped": True, "snapshot": self.snapshot}
                else:
                    reply["result"] = self.snapshot
                wire = (json.dumps(reply) + "\n").encode()
                if self.fragment:
                    writer.write(wire[:11])
                    await writer.drain()
                    await asyncio.sleep(0.002)
                    writer.write(wire[11:])
                else:
                    writer.write(wire)
                await writer.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            self.clients.discard(writer)
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass
            self.tasks.discard(task)


def action_args(command_id="cmd-1"):
    return {
        "session_id": "s1", "control_token": "c1", "command_id": command_id,
        "expected_revision": 7, "action": {"type": "wait"},
    }
