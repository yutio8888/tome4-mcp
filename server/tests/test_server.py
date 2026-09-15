import os
from pathlib import Path
import sys
import unittest

from mcp import Client, StdioServerParameters
from tome_mcp.bridge import BridgeClient
from tome_mcp.server import create_server
from support import FakeGame, action_args


class MCPTests(unittest.IsolatedAsyncioTestCase):
    async def test_v3_prefill_and_query(self):
        app=create_server(BridgeClient(token=self.game.token,port=self.game.port))
        async with Client(app) as client:
            connected=(await client.call_tool('tome.connect')).structured_content
            self.assertTrue(connected['ok'])
            self.assertEqual(self.game.requests[-1]['v'],3)
            actor=action_args()
            actor['action']={'type':'use_talent','talent_id':'T_RUSH','target_id':'s1:level-1:actor-2'}
            result=(await client.call_tool('tome.act',actor)).structured_content
            self.assertTrue(result['ok'])
            submitted=[r for r in self.game.requests if r['op']=='act'][-1]
            self.assertEqual(submitted['v'],3)
            self.assertEqual(submitted['args']['action']['target_id'],'s1:level-1:actor-2')
            position=action_args(command_id='cmd-position')
            position['action']={'type':'use_talent','talent_id':'T_RUSH','x':3,'y':4}
            await client.call_tool('tome.act',position)
            submitted=[r for r in self.game.requests if r['op']=='act'][-1]
            self.assertEqual(submitted['args']['action'],{'type':'use_talent','talent_id':'T_RUSH','x':3,'y':4})
            for bad in ({'type':'use_talent','talent_id':'T_RUSH','target_id':'a','x':1,'y':2},
                        {'type':'use_talent','talent_id':'T_RUSH','x':1},
                        {'type':'use_talent','talent_id':'T_RUSH','callback':'arbitrary'}):
                before=len(self.game.requests)
                rejected=await client.call_tool('tome.act',{**action_args(command_id='bad'),'action':bad})
                self.assertTrue(rejected.is_error,bad)
                self.assertEqual(len(self.game.requests),before)
            await client.call_tool('tome.inspect',{'session_id':'s1','kind':'talent','id':'T_RUSH','target_id':'s1:level-1:actor-2'})
            self.assertEqual(self.game.requests[-1]['args'],
                             {'session_id':'s1','kind':'talent','id':'T_RUSH','target_id':'s1:level-1:actor-2'})
            await client.call_tool('tome.inspect',{'session_id':'s1','kind':'talent','id':'T_RUSH','x':3,'y':4})
            self.assertEqual(self.game.requests[-1]['args'],
                             {'session_id':'s1','kind':'talent','id':'T_RUSH','x':3,'y':4})

    async def test_v3_respond_is_allowed(self):
        self.game.interaction_steps=1
        app=create_server(BridgeClient(token=self.game.token,port=self.game.port))
        async with Client(app) as client:
            await client.call_tool('tome.connect')
            result=(await client.call_tool('tome.act',action_args())).structured_content
            self.assertEqual(result['result']['status'],'awaiting_input')
            answer={'session_id':'s1','control_token':'c1','command_id':'cmd1','interaction_id':'i1',
                    'response_id':'answer1','expected_revision':7,'answer':{'type':'position','x':3,'y':4}}
            result=(await client.call_tool('tome.respond',answer)).structured_content
            self.assertTrue(result['ok'],result)
            submitted=[r for r in self.game.requests if r['op']=='respond']
            self.assertEqual(len(submitted),1)
            self.assertEqual(submitted[0]['v'],3)

    async def test_use_item_schema_accepts_owned_id_and_rejects_extra_controls(self):
        app=create_server(BridgeClient(token=self.game.token,port=self.game.port))
        async with Client(app) as client:
            await client.call_tool('tome.connect')
            for action in ({'type':'use_item','item_id':''},
                           {'type':'use_item','item_id':'owned','target_id':'enemy'},
                           {'type':'use_item','item_id':'owned','callback':'arbitrary'}):
                before=len(self.game.requests)
                result=await client.call_tool('tome.act',{**action_args(),'action':action})
                self.assertTrue(result.is_error)
                self.assertEqual(len(self.game.requests),before)
            args={**action_args(),'action':{'type':'use_item','item_id':'owned'}}
            result=(await client.call_tool('tome.act',args)).structured_content
            self.assertTrue(result['ok'])
            writes=[r for r in self.game.requests if r['op']=='act']
            self.assertEqual(len(writes),1)
            self.assertEqual(writes[0]['v'],3)
            self.assertEqual(writes[0]['args']['action'],args['action'])

    async def asyncSetUp(self):
        self.game = await FakeGame().__aenter__()

    async def asyncTearDown(self):
        await self.game.__aexit__()

    async def test_schema_validation_and_structured_output(self):
        app = create_server(BridgeClient(token=self.game.token, port=self.game.port))
        async with Client(app) as client:
            tools = (await client.list_tools()).tools
            self.assertEqual(len(tools), 7)
            self.assertTrue(all(tool.output_schema for tool in tools))
            self.assertNotIn("token", next(t for t in tools if t.name == "tome.connect").input_schema["properties"])
            result = (await client.call_tool("tome.connect")).structured_content
            self.assertTrue(result["ok"])
            self.assertEqual(result["result"]["session_id"], "s1")
            count = len(self.game.requests)
            invalid = action_args()
            invalid["action"] = {"type": "move", "direction": 5}
            rejected = await client.call_tool("tome.act", invalid)
            self.assertTrue(rejected.is_error)
            self.assertEqual(len(self.game.requests), count)
            bad_radius = await client.call_tool("tome.observe", {"session_id": "s1", "radius": 13})
            self.assertTrue(bad_radius.is_error)

    async def test_answers_are_strict_and_reach_native_protocol_once(self):
        self.game.interaction_steps=2
        app=create_server(BridgeClient(token=self.game.token,port=self.game.port))
        async with Client(app) as client:
            await client.call_tool("tome.connect")
            result=(await client.call_tool("tome.act",action_args())).structured_content
            self.assertEqual(result["result"]["status"],"awaiting_input")
            args={"session_id":"s1","control_token":"c1","command_id":"cmd1",
                  "interaction_id":"i1","response_id":"answer1","expected_revision":7}
            for answer in ({"type":"cancel","callback":"arbitrary"},
                           {"type":"direction","direction":5},
                           {"type":"position","x":True,"y":1},
                           {"type":"option","option_id":""},
                           {"type":"actor","target_id":"a","x":1}):
                before=len(self.game.requests)
                result=await client.call_tool("tome.respond",{**args,"answer":answer})
                self.assertTrue(result.is_error,answer)
                self.assertEqual(len(self.game.requests),before)
            result=(await client.call_tool("tome.respond",{**args,"answer":{"type":"position","x":3,"y":4}})).structured_content
            self.assertTrue(result["ok"],result)
            self.assertEqual(result["result"]["interaction"]["interaction_id"],"i2")
            submitted=[r for r in self.game.requests if r["op"]=="respond"]
            self.assertEqual(len(submitted),1)
            self.assertEqual(submitted[0]["v"],3)

    async def test_real_stdio_transport_through_tcp(self):
        source = Path(__file__).resolve().parents[1] / "src"
        params = StdioServerParameters(
            command=sys.executable, args=["-m", "tome_mcp"],
            env={**os.environ, "PYTHONPATH": str(source), "TOME_MCP_PORT": str(self.game.port), "TOME_MCP_TOKEN": self.game.token},
        )
        async with Client(params) as client:
            self.assertEqual(len((await client.list_tools()).tools), 7)
            connected = await client.call_tool("tome.connect", {})
            self.assertTrue(connected.structured_content["ok"])
            observed = await client.call_tool("tome.observe", {"session_id": "s1"})
            self.assertEqual(observed.structured_content["result"]["revision"], 7)
            result = await client.call_tool("tome.act", action_args())
            self.assertEqual(result.structured_content["result"]["status"], "completed")
            resources = await client.read_resource("tome://rules")
            self.assertIn("command_id", resources.contents[0].text)
        self.assertEqual(sum(r["op"] == "act" for r in self.game.requests), 1)

    async def test_campaign_actions_and_compact_polling(self):
        app = create_server(BridgeClient(token=self.game.token, port=self.game.port))
        async with Client(app) as client:
            await client.call_tool("tome.connect")
            for action in ({"type": "rest", "max_turns": 0}, {"type": "rest", "max_turns": 1001},
                           {"type": "change_level", "level": 2}):
                count = len(self.game.requests)
                args = action_args()
                args["action"] = action
                rejected = await client.call_tool("tome.act", args)
                self.assertTrue(rejected.is_error)
                self.assertEqual(len(self.game.requests), count)
            for i, action in enumerate(({"type": "change_level"}, {"type": "rest", "max_turns": 3})):
                args = action_args()
                args.update(action=action, command_id=f"campaign-{i}", include_map=False)
                result = (await client.call_tool("tome.act", args)).structured_content
                self.assertTrue(result["ok"])
                self.assertEqual(result["result"]["status"], "completed")
            submitted = [r for r in self.game.requests if r["op"] == "act"]
            self.assertEqual([r["args"]["action"]["type"] for r in submitted], ["change_level", "rest"])
            self.assertTrue(all(r["args"]["include_map"] is False for r in submitted))
            polls = [r for r in self.game.requests if r["op"] == "status"]
            self.assertTrue(polls)
            self.assertTrue(all(r["args"]["include_map"] is False for r in polls))

    async def test_legacy_stdio_client(self):
        """Verify initialize-based clients as well as the SDK's current protocol."""
        source = Path(__file__).resolve().parents[1] / "src"
        params = StdioServerParameters(
            command=sys.executable, args=["-m", "tome_mcp"],
            env={**os.environ, "PYTHONPATH": str(source), "TOME_MCP_PORT": str(self.game.port), "TOME_MCP_TOKEN": self.game.token},
        )
        async with Client(params, mode="legacy") as client:
            self.assertEqual(len((await client.list_tools()).tools), 7)
            connected = await client.call_tool("tome.connect", {})
            self.assertTrue(connected.structured_content["ok"])
            result = await client.call_tool("tome.act", action_args())
            self.assertEqual(result.structured_content["result"]["status"], "completed")

    async def test_growth_and_item_actions_are_specific_and_single_step(self):
        app = create_server(BridgeClient(token=self.game.token, port=self.game.port))
        actions = [
            {"type": "spend_stat", "stat": "str"},
            {"type": "learn_talent", "talent_id": "T_WEAPONS_MASTERY"},
            {"type": "learn_category", "category_id": "technique/conditioning"},
            {"type": "unlearn_talent", "talent_id": "T_RUSH"},
            {"type": "pickup", "item_id": "s1:level-1:ground-1,2:object-3"},
            {"type": "equip", "item_id": "s1:object-3"},
            {"type": "unequip", "item_id": "s1:object-3"},
        ]
        invalid = [
            {"type": "spend_stat", "stat": "luck"},
            {"type": "spend_stat", "stat": "str", "count": 9},
            {"type": "learn_talent", "talent_id": "T_WEAPONS_MASTERY", "force": True},
            {"type": "learn_category", "category_id": "technique/conditioning", "points": -1},
            {"type": "unlearn_talent"},
            {"type": "unlearn_talent", "talent_id": "T_RUSH", "points": 1},
            {"type": "pickup", "item_id": ""},
            {"type": "equip", "item_id": "s1:object-3", "slot": "MAINHAND"},
            {"type": "unequip", "item_id": "s1:object-3", "callback": "anything"},
        ]
        async with Client(app) as client:
            await client.call_tool("tome.connect")
            for action in invalid:
                before = len(self.game.requests)
                args = action_args()
                args["action"] = action
                result = await client.call_tool("tome.act", args)
                self.assertTrue(result.is_error, action)
                self.assertEqual(len(self.game.requests), before)
            for i, action in enumerate(actions):
                args = action_args()
                args.update(action=action, command_id=f"growth-{i}", include_map=False)
                result = (await client.call_tool("tome.act", args)).structured_content
                self.assertTrue(result["ok"], result)
                self.assertEqual(result["result"]["status"], "completed")
            submitted = [r["args"]["action"] for r in self.game.requests if r["op"] == "act"]
            self.assertEqual(submitted, actions)

    async def test_growth_and_item_inspection_remain_read_only(self):
        app = create_server(BridgeClient(token=self.game.token, port=self.game.port))
        async with Client(app) as client:
            tools = (await client.list_tools()).tools
            inspect = next(t for t in tools if t.name == "tome.inspect")
            self.assertTrue(inspect.annotations.read_only_hint)
            await client.call_tool("tome.connect", {"mode": "observe"})
            for kind, identifier in [("progression", "player"), ("item", "s1:object-3")]:
                await client.call_tool("tome.inspect", {"session_id": "s1", "kind": kind, "id": identifier})
                self.assertEqual(self.game.requests[-1]["op"], "inspect")
                self.assertEqual(self.game.requests[-1]["args"], {"session_id": "s1", "kind": kind, "id": identifier})
            self.assertFalse(any(r["op"] == "act" for r in self.game.requests))

    async def test_observer_mode_and_explicit_upgrade(self):
        app = create_server(BridgeClient(token=self.game.token, port=self.game.port))
        async with Client(app) as client:
            observed = (await client.call_tool("tome.connect", {"mode": "observe"})).structured_content
            self.assertTrue(observed["ok"])
            self.assertIsNone(observed["result"]["control_token"])
            self.assertEqual(self.game.requests[-1]["op"], "connect_observer")
            count = len(self.game.requests)
            rejected = await client.call_tool("tome.connect", {"mode": "automatic"})
            self.assertTrue(rejected.is_error)
            self.assertEqual(len(self.game.requests), count)
            controlled = (await client.call_tool("tome.connect", {"mode": "control"})).structured_content
            self.assertEqual(controlled["result"]["control_token"], "c1")
            self.assertEqual(self.game.requests[-1]["op"], "connect")

    async def test_older_bridge_never_silently_acquires_control_for_observer(self):
        self.game.legacy_bridge = True
        app = create_server(BridgeClient(token=self.game.token, port=self.game.port))
        async with Client(app) as client:
            reply = (await client.call_tool("tome.connect", {"mode": "observe"})).structured_content
            self.assertFalse(reply["ok"])
        self.assertEqual([r["op"] for r in self.game.requests], ["connect_observer"])


if __name__ == "__main__":
    unittest.main()
