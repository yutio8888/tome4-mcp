"""Shared/inline v4 scalar boundaries through the actual MCP and TCP layers."""
from copy import deepcopy
import json
import unittest

from mcp import Client
from tome_mcp.bridge import BridgeClient
from tome_mcp.server import create_server
from support import FakeGame, action_args
from test_public_contract import PROTOCOL, ProtocolValidator, validator

COMMON = json.loads((PROTOCOL / 'common.schema.json').read_text())
REQUESTS = json.loads((PROTOCOL / 'requests.schema.json').read_text())


def resolve(shape, document):
    while '$ref' in shape:
        filename, pointer = shape['$ref'].split('#', 1)
        if filename:
            document = COMMON if filename == 'common.schema.json' else REQUESTS
        shape = document
        for part in pointer.strip('/').split('/'):
            shape = shape[part]
    return shape, document


def scalar_fields(shape, sample, document, path=()):
    shape, document = resolve(shape, document)
    if isinstance(sample, dict):
        if 'properties' not in shape:
            variants = shape.get('oneOf', shape.get('anyOf', []))
            for variant in variants:
                candidate, owner = resolve(variant, document)
                if candidate.get('properties', {}).get('type', {}).get('const') == sample.get('type'):
                    yield from scalar_fields(candidate, sample, owner, path)
                    return
            raise AssertionError(('no matching object variant', path, sample))
        for name, value in sample.items():
            if name in shape['properties']:
                yield from scalar_fields(shape['properties'][name], value, document, path+(name,))
    elif isinstance(sample, (str, int)) and not isinstance(sample, bool):
        if 'anyOf' in shape:
            kind = 'string' if isinstance(sample, str) else 'integer'
            shape = next(s for s in shape['anyOf'] if s.get('type') == kind)
        if 'const' not in shape and 'enum' not in shape:
            yield path, shape


def templates():
    read = {'session_id': 's1'}
    control = {**read, 'control_token': 'c1'}
    respond = {**control, 'command_id': 'cmd-1', 'interaction_id': 'i1',
               'response_id': 'response1', 'expected_revision': 7, 'wait_ms': 0}
    cases = [
        ('tome.observe', 'ObserveArgs', {**read, 'radius': 8, 'events_after': 0}),
        ('tome.inspect', 'InspectArgs', {**read, 'kind': 'talent', 'id': 'T_HEAL',
            'target_id': 'actor-2', 'x': 0, 'y': 0}),
        ('tome.list', 'ListArgs', {**read, 'request': {'type': 'first', 'collection': 'inventory', 'page_size': 1}}),
        ('tome.list', 'ListArgs', {**read, 'request': {'type': 'next', 'cursor': 'cursor'}}),
        ('tome.map', 'LevelMapArgs', {**read, 'format': 'region',
            'region': {'x': 0, 'y': 0, 'width': 1, 'height': 1}}),
        ('tome.status', 'StatusArgs', {**read, 'command_id': 'cmd-1', 'response_id': 'response1', 'options_offset': 0}),
        ('tome.stop', 'StopArgs', control),
        ('tome.abandon', 'AbandonArgs', control),
        ('tome.policy', 'PolicyArgs', {**read, 'policy_op': 'get', 'expected_hash': 'hash',
            'reason': 'reason', 'limit': 1, 'after_seq': 0, 'name': 'name', 'document': 'document'}),
        ('tome.policy_log', 'PolicyLogArgs', {**read, 'limit': 1}),
    ]
    actions = [
        {'type': 'rest', 'max_turns': 1}, {'type': 'attack', 'target_id': 'actor-2'},
        {'type': 'use_talent', 'talent_id': 'T_HEAL', 'target_id': 'actor-2'},
        {'type': 'use_talent', 'talent_id': 'T_HEAL', 'x': 0, 'y': 0},
        {'type': 'set_sustain', 'talent_id': 'T_HEAL', 'enabled': True},
        {'type': 'learn_talent', 'talent_id': 'T_HEAL'},
        {'type': 'unlearn_talent', 'talent_id': 'T_HEAL'},
        {'type': 'learn_category', 'category_id': 'spell/fire'},
        *({'type': kind, 'item_id': 'item-1'} for kind in ('pickup', 'equip', 'unequip', 'use_item')),
    ]
    for action in actions:
        cases.append(('tome.act', 'ActArgs', {**action_args(), 'action': action, 'wait_ms': 0}))
    for answer in ({'type': 'actor', 'target_id': 'actor-2'},
                   {'type': 'position', 'x': 0, 'y': 0}, {'type': 'option', 'option_id': 'option-1'}):
        cases.append(('tome.respond', 'RespondArgs', {**respond, 'answer': answer}))
        cases.append(('tome.dismiss', 'DismissArgs', {**control, 'answer': answer,
            'interaction_id': 'i1', 'expected_revision': 7}))
    return cases


def boundaries(shape):
    kind = shape.get('type')
    if kind == 'string' or isinstance(kind, list) and 'string' in kind:
        if 'x-max-sequence' in shape:
            cap = shape['x-max-sequence']
            return ['cmd-0', 'cmd-01', 'cmd-1', f'cmd-{cap}', f'cmd-{cap+1}', 'cmd-1\n']
        values = ['', 'x', ' ', '~', 'a:/\\#|', '\0', 'bad\nvalue', '\x1f', '\x7f', 'é', '😀']
        cap = shape.get('x-max-utf8-bytes', 256)
        values += ['x'*cap, 'x'*(cap+1), 'é'*(cap//2), 'é'*(cap//2+1),
                   '😀'*(cap//4), '😀'*(cap//4+1)]
        return values
    low = shape.get('minimum', 0)
    high = shape.get('maximum')
    return [low-1, low, high, high+1] if high is not None else [low-1, low, 2147483648, 9007199254740992]


def replace(args, path, value):
    result = deepcopy(args)
    target = result
    for part in path[:-1]:
        target = target[part]
    target[path[-1]] = value
    return result


class ScalarContractTests(unittest.IsolatedAsyncioTestCase):
    async def test_all_mapped_scalar_boundaries_before_tcp(self):
        wire_schema = validator()
        checked = 0
        async with FakeGame() as game:
            async with Client(create_server(BridgeClient(token=game.token, port=game.port))) as client:
                await client.call_tool('tome.connect')
                for name, definition, args in templates():
                    for path, shape in scalar_fields(REQUESTS['$defs'][definition], args, REQUESTS):
                        if path == ('wait_ms',):
                            continue  # Client-side polling; existing tests cover its bounds.
                        if name == 'tome.dismiss' and path == ('expected_revision',):
                            shape = COMMON['$defs']['Revision']  # Binding REV-01 shared revision range.
                        for value in boundaries(shape):
                            checked += 1
                            expected = ProtocolValidator(shape).is_valid(value)
                            candidate = replace(args, path, value)
                            # FakeGame is a permissive receiving peer, not an
                            # oracle for whether a command/response is native-valid.
                            if 'command_id' in candidate:
                                key = candidate['command_id']
                                game.commands[key] = {'command_id': key, 'status': 'completed'}
                            before = len(game.requests)
                            with self.subTest(tool=name, variant=args.get('action', args.get('answer', {})),
                                              path=path, value=value):
                                reply = await client.call_tool(name, candidate)
                                if not expected:
                                    self.assertEqual(len(game.requests), before, game.requests[before:])
                                    self.assertTrue(reply.is_error)
                                else:
                                    self.assertFalse(reply.is_error)
                                    self.assertEqual(len(game.requests), before+1)
                                    wire_schema.validate(game.requests[-1])
        print(f'Public v4 scalar matrix: {checked} actual MCP boundary cases')

    async def test_advertised_shared_and_inline_scalar_constraints(self):
        async with FakeGame() as game:
            async with Client(create_server(BridgeClient(token=game.token, port=game.port))) as client:
                tools = {t.name: t.input_schema for t in (await client.list_tools()).tools}
        for name, definition, args in templates():
            actual = dict(scalar_fields(tools[name], args, tools[name]))
            for path, expected in scalar_fields(REQUESTS['$defs'][definition], args, REQUESTS):
                if name == 'tome.dismiss' and path == ('expected_revision',):
                    expected = COMMON['$defs']['Revision']
                shape = actual[path]
                with self.subTest(tool=name, path=path):
                    for key in ('minimum', 'maximum', 'minLength', 'pattern',
                                'x-max-utf8-bytes', 'x-max-sequence'):
                        self.assertEqual(shape.get(key), expected.get(key), key)
                    # Code-point maxLength may safely reflect the byte bound,
                    # but must not reinstate the historical 128-character cap.
                    implied = expected.get('x-max-utf8-bytes')
                    if 'x-max-sequence' in expected:
                        implied = len('cmd-'+str(expected['x-max-sequence']))
                    self.assertEqual(shape.get('maxLength'), implied)
