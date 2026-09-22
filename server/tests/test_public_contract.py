"""Public v4 schema/tool regressions through actual MCP request serialization."""
import json
from pathlib import Path
import re
import subprocess
import unittest

from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from mcp import Client
from pydantic import TypeAdapter, ValidationError
from tome_mcp.bridge import BridgeClient
from tome_mcp.server import Answer, create_server
from support import FakeGame, action_args

ROOT = Path(__file__).resolve().parents[2]
PROTOCOL = ROOT / 'protocol/v4'


def validator():
    documents = [json.loads(p.read_text()) for p in PROTOCOL.glob('*.schema.json')]
    registry = Registry().with_resources(
        (key, Resource.from_contents(d)) for d in documents
        for key in (d['$id'], d['$id'].rsplit('/', 1)[-1]))
    schema = json.loads((PROTOCOL / 'requests.schema.json').read_text())
    return Draft202012Validator(schema, registry=registry)


class PublicSchemaTests(unittest.TestCase):
    def test_operation_binding_and_closed_public_actions(self):
        schema = validator()
        for op in ('stop', 'abandon'):
            request = {'v': 4, 'id': 'r', 'op': op,
                       'args': {'session_id': 's', 'control_token': 'c'}}
            schema.validate(request)
            request['args']['extra'] = True
            self.assertFalse(schema.is_valid(request))
        base = {'v': 4, 'id': 'r', 'op': 'act', 'args': action_args()}
        for name in ('force_actor', 'force_grid', 'authoritative_target', 'sequence', 'internal',
                     'run_id', 'submission_id', 'generation'):
            candidate = {**base, 'args': {**base['args'], 'action': {
                'type': 'use_talent', 'talent_id': 'T_DYNAMIC', name: True}}}
            self.assertFalse(schema.is_valid(candidate), name)
        for sections in ({}, {'player': True}, ['player', 'player'], ['unknown'], [None], [1]):
            self.assertFalse(schema.is_valid({'v': 4, 'id': 'r', 'op': 'observe',
                'args': {'session_id': 's', 'sections': sections}}), sections)
        for sections in ([], ['player'], ['scene', 'effects', 'sustains', 'resources', 'stats', 'ground_effects']):
            schema.validate({'v': 4, 'id': 'r', 'op': 'observe',
                             'args': {'session_id': 's', 'sections': sections}})

    def test_generated_runtime_request_schema_is_current(self):
        proc = subprocess.run(['python3', str(ROOT/'tools/generate_protocol.py'), '--check'],
                              cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout+proc.stderr)


class PublicToolTests(unittest.IsolatedAsyncioTestCase):
    async def test_all_tools_emit_schema_valid_tcp_requests(self):
        async with FakeGame() as game:
            app = create_server(BridgeClient(token=game.token, port=game.port))
            async with Client(app) as client:
                tools = (await client.list_tools()).tools
                readme = (ROOT/'README.md').read_text()
                for tool in tools:
                    self.assertIn(f'| `{tool.name}` |', readme)
                await client.call_tool('tome.connect', {'mode': 'observe'})
                await client.call_tool('tome.connect', {'mode': 'control'})
                calls = [
                    ('tome.observe', {'session_id': 's1', 'sections': ['player'], 'detail': 'full'}),
                    ('tome.inspect', {'session_id': 's1', 'kind': 'character', 'id': 'player', 'computed': False}),
                    ('tome.act', {**action_args(), 'wait_ms': 0}),
                    ('tome.status', {'session_id': 's1', 'command_id': 'cmd-1', 'compact': True}),
                    ('tome.respond', {'session_id': 's1', 'control_token': 'c1', 'command_id': 'cmd-1',
                        'interaction_id': 'i1', 'response_id': 'response1', 'expected_revision': 7,
                        'answer': {'type': 'option', 'option_id': 'i1:1'}, 'wait_ms': 0}),
                    ('tome.dismiss', {'session_id': 's1', 'control_token': 'c1', 'answer': {'type': 'cancel'}}),
                    ('tome.abandon', {'session_id': 's1', 'control_token': 'c1'}),
                    ('tome.list', {'session_id': 's1', 'request': {'type': 'first', 'collection': 'inventory'}}),
                    ('tome.map', {'session_id': 's1', 'format': 'region',
                        'region': {'x': 0, 'y': 0, 'width': 2, 'height': 2}}),
                    ('tome.policy', {'session_id': 's1', 'policy_op': 'get'}),
                    ('tome.policy_log', {'session_id': 's1', 'limit': 3}),
                    ('tome.stop', {'session_id': 's1', 'control_token': 'c1'}),
                ]
                for name, args in calls:
                    before = len(game.requests)
                    await client.call_tool(name, args)
                    self.assertGreater(len(game.requests), before, name)
                validate = validator()
                self.assertEqual({r['op'] for r in game.requests},
                    {'connect', 'connect_observer', 'observe', 'inspect', 'act', 'status', 'respond',
                     'dismiss', 'abandon', 'list_collection', 'level_map', 'policy', 'policy_log', 'stop'})
                for request in game.requests:
                    validate.validate(request)

    async def test_sections_and_internal_fields_reject_before_bridge(self):
        async with FakeGame() as game:
            async with Client(create_server(BridgeClient(token=game.token, port=game.port))) as client:
                await client.call_tool('tome.connect')
                before = len(game.requests)
                for sections in ({}, [1], ['unknown'], ['player', 'player']):
                    reply = await client.call_tool('tome.observe', {'session_id': 's1', 'sections': sections})
                    self.assertTrue(reply.is_error)
                for key in ('force_actor', 'force_grid', 'authoritative_target', 'sequence'):
                    reply = await client.call_tool('tome.act', {**action_args(), 'action': {
                        'type': 'use_talent', 'talent_id': 'T_DYNAMIC', key: True}})
                    self.assertTrue(reply.is_error)
                self.assertEqual(len(game.requests), before)

    async def test_dismiss_description_examples_are_real_answers(self):
        async with FakeGame() as game:
            async with Client(create_server(BridgeClient(token=game.token, port=game.port))) as client:
                tool = next(t for t in (await client.list_tools()).tools if t.name == 'tome.dismiss')
                examples = re.findall(r'\{"type":.*?\}', tool.description)
                self.assertEqual(len(examples), 2)
                adapter = TypeAdapter(Answer)
                for text in examples:
                    adapter.validate_json(text)
                self.assertNotIn('"type":"confirm"', tool.description)
                with self.assertRaises(ValidationError):
                    adapter.validate_python({'type': 'confirm', 'value': True})
