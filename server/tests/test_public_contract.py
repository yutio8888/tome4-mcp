"""Public v4 schema/tool regressions through actual MCP request serialization."""
import json
from pathlib import Path
import re
import subprocess
import unittest

from jsonschema import Draft202012Validator, ValidationError as SchemaError
from jsonschema.validators import extend
from referencing import Registry, Resource
from mcp import Client
from pydantic import TypeAdapter, ValidationError
from tome_mcp.bridge import BridgeClient
from tome_mcp.server import Answer, create_server
from support import FakeGame, action_args

ROOT = Path(__file__).resolve().parents[2]
PROTOCOL = ROOT / 'protocol/v4'


def _utf8_bytes(_validator, limit, value, _schema):
    if isinstance(value, str) and len(value.encode('utf-8')) > limit:
        yield SchemaError('string exceeds the v4 UTF-8 byte limit')


def _command_sequence(_validator, limit, value, _schema):
    if isinstance(value, str) and re.fullmatch(r'cmd-[1-9][0-9]*', value):
        digits = value[4:]
        bound = str(limit)
        if len(digits) > len(bound) or (len(digits) == len(bound) and digits > bound):
            yield SchemaError('command sequence exceeds the v4 limit')


def _wire_pattern(_validator, pattern, value, _schema):
    # All declared v4 patterns are anchored. Match the Lua wire validator's
    # strict end-of-string semantics, rather than Python "$" before a final LF.
    if isinstance(value, str) and re.fullmatch(pattern, value) is None:
        yield SchemaError('string does not match the complete v4 wire pattern')


ProtocolValidator = extend(Draft202012Validator, {
    'x-max-utf8-bytes': _utf8_bytes, 'x-max-sequence': _command_sequence,
    'pattern': _wire_pattern,
})


def validator():
    documents = [json.loads(p.read_text()) for p in PROTOCOL.glob('*.schema.json')]
    registry = Registry().with_resources(
        (key, Resource.from_contents(d)) for d in documents
        for key in (d['$id'], d['$id'].rsplit('/', 1)[-1]))
    schema = json.loads((PROTOCOL / 'requests.schema.json').read_text())
    return ProtocolValidator(schema, registry=registry)


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
    async def test_revision_boundaries_reject_before_wire(self):
        revision = json.loads((PROTOCOL / 'common.schema.json').read_text())['$defs']['Revision']
        low, high = revision['minimum'], revision['maximum']
        validate = validator()
        async with FakeGame() as game:
            async with Client(create_server(BridgeClient(token=game.token, port=game.port))) as client:
                await client.call_tool('tome.connect')
                # A real MCP act gives FakeGame the command record that respond
                # expects. This verifies serialization, not native acceptance.
                await client.call_tool('tome.act', {**action_args(), 'wait_ms': 0})
                calls = {
                    'tome.act': {**action_args(), 'wait_ms': 0},
                    'tome.respond': {'session_id': 's1', 'control_token': 'c1', 'command_id': 'cmd-1',
                        'interaction_id': 'i1', 'response_id': 'answer1',
                        'answer': {'type': 'cancel'}, 'wait_ms': 0},
                    'tome.dismiss': {'session_id': 's1', 'control_token': 'c1',
                        'answer': {'type': 'cancel'}},
                }
                for name, args in calls.items():
                    for value in (low-1, low, high, high+1):
                        with self.subTest(tool=name, revision=value):
                            before = len(game.requests)
                            reply = await client.call_tool(name, {**args, 'expected_revision': value})
                            if value < low or value > high:
                                self.assertEqual(len(game.requests), before, game.requests[before:])
                                self.assertTrue(reply.is_error)
                            else:
                                self.assertFalse(reply.is_error)
                                self.assertEqual(len(game.requests), before+1)
                                self.assertEqual(game.requests[-1]['args']['expected_revision'], value)
                                validate.validate(game.requests[-1])
                for tool in (await client.list_tools()).tools:
                    if tool.name not in calls:
                        continue
                    shape = tool.input_schema['properties']['expected_revision']
                    if 'anyOf' in shape:
                        shape = next(s for s in shape['anyOf'] if s.get('type') == 'integer')
                    with self.subTest(advertised_tool=tool.name):
                        self.assertEqual(shape['minimum'], low)
                        self.assertEqual(shape['maximum'], high)

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
