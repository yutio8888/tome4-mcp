import asyncio
import unittest

from tome_mcp.bridge import BridgeClient, BridgeError
from support import FakeGame, action_args


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.game = await FakeGame().__aenter__()
        self.bridge = BridgeClient(token=self.game.token, port=self.game.port, timeout=0.2)

    async def asyncTearDown(self):
        await self.bridge.close()
        await self.game.__aexit__()

    async def test_read_does_not_connect_or_acquire_control(self):
        with self.assertRaises(BridgeError) as raised:
            await self.bridge.request("observe", {"session_id": "s1"})
        self.assertEqual(raised.exception.code, "not_connected")
        self.assertEqual(self.game.connections, 0)

    async def test_fragmented_responses_and_concurrent_requests(self):
        self.game.fragment = True
        await self.bridge.connect()
        results = await asyncio.gather(*[
            self.bridge.request("observe", {"session_id": "s1"}) for _ in range(6)
        ])
        self.assertEqual([r["revision"] for r in results], [7] * 6)
        self.assertEqual(self.game.connections, 1)

    async def test_explicit_connect_reuses_connection(self):
        await self.bridge.connect()
        await self.bridge.connect()
        self.assertEqual(self.game.connections, 1)

    async def test_explicit_connect_replaces_peer_closed_socket(self):
        await self.bridge.connect()
        for peer in list(self.game.clients):
            peer.close()
        await asyncio.sleep(0.02)
        connected = await self.bridge.connect()
        self.assertEqual(connected["session_id"], "s1")
        self.assertEqual(self.game.connections, 2)

    async def test_native_polling_submits_exactly_once(self):
        await self.bridge.connect()
        result = await self.bridge.act(action_args(), wait_ms=200)
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["energy_spent"], 1000)
        self.assertEqual(sum(r["op"] == "act" for r in self.game.requests), 1)

    async def test_pending_action_is_returned_without_retry(self):
        await self.bridge.connect()
        self.game.pending = True
        result = await self.bridge.act(action_args(), wait_ms=70)
        self.assertEqual(result["status"], "queued")
        self.assertTrue(result["wait_expired"])
        self.assertEqual(sum(r["op"] == "act" for r in self.game.requests), 1)

    async def test_stop_can_interleave_with_status_polling(self):
        await self.bridge.connect()
        self.game.pending = True
        task = asyncio.create_task(self.bridge.act(action_args(), wait_ms=500))
        await asyncio.sleep(0.03)
        await self.bridge.request("stop", {"session_id": "s1", "control_token": "c1"})
        self.assertEqual((await task)["status"], "cancelled")

    async def test_timeout_marks_uncertainty_and_never_resubmits(self):
        await self.bridge.connect()
        self.game.drop_act_reply = True
        with self.assertRaises(BridgeError) as raised:
            await self.bridge.act(action_args())
        error = raised.exception
        self.assertEqual(error.code, "bridge_timeout")
        self.assertTrue(error.uncertain)
        self.assertEqual(error.command_id, "cmd1")
        with self.assertRaises(BridgeError):
            await self.bridge.request("status", {"session_id": "s1", "command_id": "cmd1"})
        await self.bridge.connect()
        record = await self.bridge.request("status", {"session_id": "s1", "command_id": "cmd1"})
        self.assertEqual(record["status"], "completed")
        self.assertEqual(sum(r["op"] == "act" for r in self.game.requests), 1)

    async def test_mismatched_response_closes_connection(self):
        await self.bridge.connect()
        self.game.wrong_id = True
        with self.assertRaises(BridgeError) as raised:
            await self.bridge.request("observe", {"session_id": "s1"})
        self.assertEqual(raised.exception.code, "bridge_disconnected")
        self.assertFalse(raised.exception.uncertain)

    async def test_cancelled_request_drops_late_response_channel(self):
        await self.bridge.connect()
        self.game.drop_act_reply = True
        pending = asyncio.create_task(self.bridge.request("act", action_args()))
        await asyncio.sleep(0.02)
        pending.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await pending
        with self.assertRaises(BridgeError) as raised:
            await self.bridge.request("observe", {"session_id": "s1"})
        self.assertEqual(raised.exception.code, "not_connected")
        self.assertEqual(sum(r["op"] == "act" for r in self.game.requests), 1)

    async def test_bad_auth_is_reported_without_token(self):
        self.bridge._token = "secret-wrong-token"
        with self.assertRaises(BridgeError) as raised:
            await self.bridge.connect()
        self.assertEqual(raised.exception.code, "unauthorized")
        self.assertNotIn("secret-wrong-token", str(raised.exception.as_dict()))

    async def test_interaction_returns_without_waiting_for_terminal(self):
        self.game.interaction_steps=2
        await self.bridge.connect()
        record=await self.bridge.act(action_args(),wait_ms=1000)
        self.assertEqual(record['status'],'awaiting_input')
        self.assertNotIn('wait_expired',record)
        self.assertEqual(sum(r['op']=='status' for r in self.game.requests),0)
        args={**action_args(), 'interaction_id':'i1','response_id':'answer1',
              'answer':{'type':'position','x':3,'y':4}}
        args.pop('action')
        result=await self.bridge.respond(args,wait_ms=500)
        self.assertEqual(result['interaction']['interaction_id'],'i2')
        self.assertEqual(result['response_receipt']['state'],'applied')
        self.assertEqual(sum(r['op']=='respond' for r in self.game.requests),1)
        self.assertTrue(all(r["v"]==3 for r in self.game.requests))
        self.assertEqual(self.game.requests[-1]['args']['response_id'],'answer1')

    async def test_response_timeout_preserves_both_ids_and_does_not_retry(self):
        self.game.interaction_steps=1
        await self.bridge.connect()
        await self.bridge.act(action_args())
        self.game.drop_response_reply=True
        args={**action_args(),'interaction_id':'i1','response_id':'answer1',
              'answer':{'type':'cancel'}}
        args.pop('action')
        with self.assertRaises(BridgeError) as raised:
            await self.bridge.respond(args)
        error=raised.exception
        self.assertTrue(error.uncertain)
        self.assertEqual((error.command_id,error.response_id),('cmd1','answer1'))
        self.assertEqual(error.as_dict()['response_id'],'answer1')
        await self.bridge.connect()
        result=await self.bridge.request('status',{'session_id':'s1','command_id':'cmd1','response_id':'answer1'})
        self.assertEqual(result['status'],'completed')
        self.assertEqual(sum(r['op']=='respond' for r in self.game.requests),1)

    async def test_old_bridge_rejection_never_falls_back(self):
        self.game.legacy_bridge=True
        with self.assertRaises(BridgeError):
            await self.bridge.connect()
        self.assertEqual(len(self.game.requests),1)
        self.assertEqual(self.game.requests[0]['v'],3)


if __name__ == "__main__":
    unittest.main()
