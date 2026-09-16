#!/usr/bin/env python3
"""Agent-facing interactive ToME MCP console.

Starts an isolated ordinary ToME run (Halfling / Celestial-Anorithil / Madness),
opens the official ToME MCP server over stdio, and then reads one JSON command
per line from stdin. Every command prints exactly one JSON result line.

Commands (one JSON object per line):
  {}                                   observe (compact summary)
  {"observe": true}                    observe (compact summary)
  {"action": {...}, "reason": "..."}   perform one native action
  {"respond": {"type": ...}, "reason": "..."}   answer the current interaction
  {"inspect": {"kind": "...", "id": "..."}}     read-only inspect
  {"walk": [8,8,6], "reason": "..."}   bounded movement, stops on actors
  {"key": "a", "modifier": "Control_L"} native key press + reconnect
  {"auto": "preset"|"start"|"stop"|"pause"|"resume"|"status"}  auto-combat control
  {"auto": {"op": "preset", "name": "anorithil_p1a"}}  preset then approve+activate
  {"policy": {"op": "status"|"preset"|"set_draft"|...}}  raw tome.policy op
  {"policy_log": 24}                   recent auto-combat decisions
  {"connect": "control"|"observe"}     explicit (re)connect
  {"stop": true}                       release control / hand off
  {"quit": true, "save": false}        end the run
"""
import asyncio, json, os, shutil, sys, time, zipfile
from pathlib import Path

ROOT = Path('/workspace/t-engine4')
sys.path.insert(0, str(ROOT / 'game/addons/tome-mcp-bridge/tests/native'))
from runtime import Runtime, DEFAULT_SOURCE, DEFAULT_DEPS, sha  # noqa: E402
from mcp import Client, StdioServerParameters  # noqa: E402

SERVER_SRC = ROOT / 'game/addons/tome-mcp-bridge/server/src'


CURRENT_RID = None


def emit(payload):
    global CURRENT_RID
    # Unwrap a bridge error instead of double-wrapping it in a successful reply.
    result = payload.get('result') if isinstance(payload, dict) else None
    if isinstance(payload, dict) and payload.get('ok') is True and isinstance(result, dict):
        if '_error' in result:
            inner = result['_error']
            error = inner.get('error', inner) if isinstance(inner, dict) else inner
            payload = {'ok': False, 'error': error}
        elif set(result.keys()) == {'error'}:
            payload = {'ok': False, 'error': result['error']}
    if CURRENT_RID is not None and isinstance(payload, dict):
        payload = {**payload, '__rid': CURRENT_RID}
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def _prune(value):
    """Drop None recursively so an omitted domain is absent, not a null stub."""
    if isinstance(value, dict):
        pruned = {k: _prune(v) for k, v in value.items()}
        pruned = {k: v for k, v in pruned.items() if v is not None}
        return pruned or None
    if isinstance(value, list):
        return [_prune(v) for v in value]
    return value


def snapshot_summary(s):
    if not s:
        return None
    player = s.get('player') or {}
    summary = {
        'phase': s.get('phase'),
        'actionable': s.get('actionable'),
        'needs_reconnect': s.get('needs_reconnect'),
        'release_reason': s.get('release_reason'),
        'release_hint': s.get('release_hint'),
        'control_lease': s.get('control_lease'),
        'control': s.get('control_source') or s.get('control'),
        'revision': s.get('revision'),
        'world_tick': s.get('world_tick'),
        'level_instance_id': s.get('level_instance_id'),
        'scene': s.get('scene'),
        'interaction': s.get('interaction'),
        'interaction_scope': s.get('interaction_scope'),
        'player': {k: player.get(k) for k in
                   ('id', 'name', 'x', 'y', 'life', 'max_life', 'level', 'exp', 'exp_next',
                    'life_regen', 'energy', 'faction', 'type', 'subtype', 'rank',
                    'stats', 'descriptor', 'unused_stats', 'unused_talents', 'unused_generics',
                    'unused_talents_types', 'inventory_count', 'equipment_count')},
        'resources': player.get('resources'),
        'effects': player.get('effects'),
        'actors': s.get('actors') if s.get('actors') is not None else None,
        'ground': s.get('ground'),
        'map': {k: (s.get('map') or {}).get(k) for k in ('x', 'y', 'rows')} if s.get('map') else None,
        'talents': ([{'id': t.get('id'), 'name': t.get('name'), 'mode': t.get('mode'),
                      'level': t.get('level'), 'cooldown': t.get('cooldown'),
                      'base_cooldown': t.get('base_cooldown'), 'supported': t.get('supported')}
                     for t in s.get('talents') if t.get('mode') != 'passive']
                    if s.get('talents') is not None else None),
        'dialogs': s.get('dialogs') if s.get('dialogs') is not None else None,
        'sustains': player.get('sustains'),
        'events': s.get('events'),
        'history': s.get('history'),
        'ground_effects': s.get('ground_effects'),
        'ground_effects_truncated': s.get('ground_effects_truncated'),
        'inventory': player.get('inventory'),
        'equipment': player.get('equipment'),
        'pending_command': s.get('pending_command'),
        'lua_heap_kb': s.get('lua_heap_kb'),
    }
    # Drop domains the bridge omitted (observe.sections), keeping true false/0 values.
    return _prune(summary)


async def main():
    global CURRENT_RID
    name = sys.argv[1]
    birth = os.environ.get('TOME_BIRTH_ADDON', 'mcp-play-birth-ham')
    r = Runtime(name, DEFAULT_SOURCE, DEFAULT_DEPS,
                addon_archive=ROOT / 'game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa',
                extra_addons={birth: ROOT / ('tmp/mcp-play-support/tome-' + birth)})
    addons = r.runtime / 'game/addons'
    shutil.rmtree(addons / 'tome-mcp-probe')
    r.command[-1] = "-Eset_addons={'mcp-bridge','" + birth + "'};no_birth_popup=true"
    settings = r.home / '.t-engine/4.0/settings/mcp-test.cfg'
    settings.write_text(settings.read_text()
        .replace('cheat = true', 'cheat = false')
        .replace('tome_mcp_bridge = {enabled=true,',
                 'tome_mcp_bridge = {allow_auto_combat_execution=true,enabled=true,'))
    with zipfile.ZipFile(r.session / 'candidate.zip', 'w', zipfile.ZIP_DEFLATED) as z:
        for p in sorted(addons.rglob('*')):
            if p.is_file():
                z.write(p, p.relative_to(addons))
    metadata = json.loads((r.session / 'input.json').read_text())
    metadata.update(command=r.command, cheat=False, normal_campaign=True, fixture_removed=True,
                    character={'race': 'Halfling', 'class': 'Celestial', 'subclass': 'Anorithil',
                               'difficulty': 'Madness', 'permadeath': 'Roguelike'},
                    candidate_sha256=sha(r.session / 'candidate.zip'),
                    addon_lua_sha256={str(p.relative_to(addons)): sha(p) for p in addons.rglob('*.lua')},
                    driver_sha256=sha(Path(__file__)))
    (r.session / 'input.json').write_text(json.dumps(metadata, indent=2))

    transcript = (r.session / 'play-mcp.jsonl').open('w')
    decisions = (r.session / 'decisions.jsonl').open('w')
    state = {'connection': None, 'current': None, 'command_id': None,
             'interaction': None, 'revision': None, 'counter': 0}

    def record(tool, args, response):
        transcript.write(json.dumps({'tool': tool, 'args': args, 'response': response},
                                    ensure_ascii=False) + '\n')
        transcript.flush()

    try:
        r.start()
        for _ in range(3600):
            assert r.process.poll() is None, 'Game exited during birth'
            if '[MCPPlayBirth]' in (r.session / 'game.log').read_text(errors='replace'):
                break
            await asyncio.sleep(.05)
        else:
            raise TimeoutError('Birth did not finish')

        params = StdioServerParameters(command=sys.executable, args=['-m', 'tome_mcp'],
            env={**os.environ, 'PYTHONPATH': str(SERVER_SRC),
                 'TOME_MCP_PORT': str(r.port), 'TOME_MCP_TOKEN': r.token})
        async with Client(params) as client:
            async def call(tool, args=None):
                reply = await client.call_tool(tool, args or {})
                value = reply.structured_content
                record(tool, args or {}, value)
                if not value:
                    # MCP-level (schema) rejection has no structured content; keep
                    # the text so a validation failure is readable, not _error:null.
                    text = ''.join(getattr(part, 'text', '') for part in (reply.content or []))
                    return {'_error': {'code': 'mcp_request_rejected', 'is_error': bool(reply.is_error),
                                       'message': text or 'no structured response'}}
                if not value.get('ok'):
                    return {'_error': value}
                return value['result']

            async def connect(mode='control'):
                conn = await call('tome.connect', {'mode': mode})
                state['connection'] = conn
                if conn.get('snapshot'):
                    state['current'] = conn['snapshot']
                state['revision'] = conn.get('revision')
                return conn

            async def observe():
                conn = state['connection']
                s = await call('tome.observe',
                               {'session_id': conn['session_id'], 'radius': 12, 'include_map': False})
                if '_error' not in s:
                    state['current'] = s
                    (r.session / 'observed.json').write_text(json.dumps(s, indent=2))
                    # Recover a pending interaction so a rejected/failed respond
                    # never loses the native prompt.
                    pc = s.get('pending_command') or {}
                    if isinstance(pc, dict) and pc.get('interaction'):
                        state['interaction'] = pc['interaction']
                        state['command_id'] = pc.get('command_id') or state.get('command_id')
                        state['revision'] = s.get('revision', state.get('revision'))
                return s

            async def settle(result):
                command_id = state['command_id']
                for _ in range(600):
                    if result.get('status') not in ('queued', 'executing', 'settling',
                                                    'running_native_task'):
                        break
                    await asyncio.sleep(.05)
                    result = await call('tome.status',
                                        {'session_id': state['connection']['session_id'],
                                         'command_id': command_id, 'include_map': False})
                if result.get('snapshot'):
                    state['current'] = result['snapshot']
                state['revision'] = result.get('revision', state['revision'])
                if result.get('interaction'):
                    state['interaction'] = result['interaction']
                return result

            async def action(action, reason):
                before = await observe()
                if before.get('phase') != 'ready':
                    return {'status': 'failed', 'code': 'not_ready', 'action_ok': False,
                            'details': {'hint': 'the game is not ready for actions (phase=%s)' % before.get('phase')},
                            'snapshot': snapshot_summary(before)}
                if 'target_id' in action and action['target_id'] and ':' not in action['target_id']:
                    targets = [t for t in before.get('actors', [])
                               if t['id'].endswith('actor-' + action['target_id'])]
                    if len(targets) != 1:
                        return {'error': 'Target not currently observed'}
                    action = {**action, 'target_id': targets[0]['id']}
                state['counter'] += 1
                command_id = (before.get('history') or {}).get('next_command_id')
                if not command_id:
                    return {'error': 'no next_command_id in history; reconnect and observe'}
                state['command_id'] = command_id
                state['interaction'] = None
                args = {'session_id': state['connection']['session_id'],
                        'control_token': state['connection']['control_token'],
                        'command_id': command_id, 'expected_revision': before['revision'],
                        'action': action, 'wait_ms': 10000, 'include_map': False}
                decisions.write(json.dumps({'command': command_id, 'action': action,
                    'reason': reason, 'position': [before['player']['x'], before['player']['y']],
                    'life': before['player']['life'], 'world_tick': before['world_tick']},
                    ensure_ascii=False) + '\n')
                decisions.flush()
                result = await call('tome.act', args)
                result = await settle(result)
                out = {k: v for k, v in result.items() if k != 'snapshot'}
                out['snapshot'] = snapshot_summary(state['current'])
                return out

            async def policy(op, **kwargs):
                args = {'session_id': state['connection']['session_id'], 'policy_op': op}
                args.update(kwargs)
                return await call('tome.policy', args)

            async def auto(op, name=None):
                """High-level auto-combat control so the play agent needs no JSON."""
                if op == 'preset':
                    preset = await policy('preset', name=name or 'anorithil_p1a')
                    if '_error' in preset:
                        return preset
                    draft = await policy('set_draft', policy=preset['policy'])
                    if '_error' in draft:
                        return draft
                    approved = await policy('approve', expected_hash=draft['draft_hash'])
                    if '_error' in approved:
                        return approved
                    return await policy('activate', expected_hash=approved['approved_hash'])
                if op in ('start', 'stop', 'pause', 'resume', 'deactivate'):
                    return await policy(op, reason='playtest')
                if op == 'status':
                    st = await policy('status')
                    log = await call('tome.policy_log',
                                     {'session_id': state['connection']['session_id'], 'limit': 64})
                    return {'status': st, 'log': log}
                return {'error': {'code': 'unknown_auto_op', 'op': op}}

            async def respond(answer, reason):
                if not state.get('interaction') or not state.get('command_id'):
                    return {'status': 'failed', 'code': 'no_pending_interaction', 'action_ok': False,
                            'details': {'hint': 'observe.interaction lists a command interaction; '
                                                'native popups use {"dismiss":{...}}'}}
                interaction = state['interaction']
                state['counter'] += 1
                response_id = f'resp-{state["counter"]:05d}'
                args = {'session_id': state['connection']['session_id'],
                        'control_token': state['connection']['control_token'],
                        'command_id': state['command_id'],
                        'interaction_id': interaction['interaction_id'],
                        'response_id': response_id,
                        'expected_revision': state['revision'],
                        'answer': answer, 'wait_ms': 10000}
                decisions.write(json.dumps({'respond': response_id, 'answer': answer,
                    'reason': reason, 'interaction': interaction}, ensure_ascii=False) + '\n')
                decisions.flush()
                result = await call('tome.respond', args)
                if isinstance(result, dict) and '_error' in result:
                    # Keep the interaction so the caller can correct the answer.
                    state['interaction'] = interaction
                    return result
                state['interaction'] = None
                result = await settle(result)
                out = {k: v for k, v in result.items() if k != 'snapshot'}
                out['snapshot'] = snapshot_summary(state['current'])
                return out

            await connect()
            print('READY ' + str(r.session), flush=True)
            emit({'ready': True, 'session': str(r.session), 'port': r.port,
                  'snapshot': snapshot_summary(await observe())})

            while True:
                line = await asyncio.to_thread(sys.stdin.readline)
                if not line:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    c = json.loads(line)
                    if isinstance(c, dict):
                        CURRENT_RID = c.pop('__rid', None)
                    else:
                        CURRENT_RID = None
                    if c.get('quit'):
                        if state['connection'].get('control_token'):
                            await call('tome.stop', {'session_id': state['connection']['session_id'],
                                                     'control_token': state['connection']['control_token']})
                        if c.get('save'):
                            r.input.chord('Control_L', 's')
                            await asyncio.sleep(3)
                        emit({'quit': True})
                        break
                    if c.get('connect'):
                        await connect(c['connect'])
                        out = {**(snapshot_summary(await observe()) or {}),
                               'status': 'completed', 'code': 'connected', 'action_ok': True}
                    elif c.get('stop'):
                        out = await call('tome.stop', {'session_id': state['connection']['session_id'],
                                                       'control_token': state['connection']['control_token']})
                    elif c.get('abandon'):
                        out = await call('tome.abandon', {'session_id': state['connection']['session_id'],
                                                          'control_token': state['connection']['control_token']})
                        if isinstance(out, dict) and out.get('snapshot'):
                            state['current'] = out['snapshot']
                            state['revision'] = out['snapshot'].get('revision', state['revision'])
                            out = {**out, 'snapshot': snapshot_summary(out['snapshot'])}
                    elif c.get('key'):
                        mods = c.get('modifiers') or ([c['modifier']] if c.get('modifier') else [])
                        if len(mods) > 1:
                            r.input.chord_many(mods, c['key'])
                        elif mods:
                            r.input.chord(mods[0], c['key'])
                        else:
                            r.input.press(c['key'])
                        await asyncio.sleep(.3)
                        await connect()
                        # A key can start a native task (auto-explore, rest) or open
                        # a popup. Track position AND world tick/revision/phase so a
                        # turn-advancing native task is not misreported as stuck.
                        moved = 0
                        stuck = 0
                        last = None
                        snap = await observe()
                        for _ in range(80):
                            snap = await observe()
                            p = snap.get('player') or {}
                            pos = (p.get('x'), p.get('y'))
                            sig = (pos, snap.get('world_tick'), snap.get('revision'),
                                   snap.get('phase'), snap.get('native_activity'))
                            if sig == last:
                                stuck += 1
                            else:
                                if last is not None and pos != last[0]:
                                    moved += 1
                                stuck = 0
                            last = sig
                            if snap.get('phase') not in ('ready', 'settling', 'unavailable'):
                                break
                            if stuck >= 8:
                                break
                            await asyncio.sleep(.2)
                        phase = snap.get('phase')
                        if phase not in ('ready', 'settling', 'unavailable'):
                            status, code = 'interrupted', phase
                        elif stuck >= 8:
                            status, code = 'stuck', 'no_progress'
                        else:
                            status, code = 'settled', 'key_applied'
                        out = {**(snapshot_summary(snap) or {}),
                               'status': status, 'code': code, 'moved_steps': moved}
                    elif c.get('auto'):
                        spec = c['auto']
                        if isinstance(spec, dict):
                            out = await auto(spec.get('op'), spec.get('name'))
                        else:
                            out = await auto(spec)
                    elif c.get('policy'):
                        spec = dict(c['policy'])
                        op = spec.pop('op', None)
                        out = await policy(op, **spec)
                    elif c.get('action'):
                        out = await action(c['action'], c.get('reason', 'manual MCP decision'))
                    elif c.get('respond'):
                        out = await respond(c['respond'], c.get('reason', 'manual MCP answer'))
                    elif c.get('map'):
                        conn = state['connection']
                        full = await call('tome.observe', {'session_id': conn['session_id'], 'radius': 12})
                        m = full.get('map') if isinstance(full, dict) else None
                        if isinstance(full, dict) and 'player' in full:
                            state['current'] = full
                        m = m or {}
                        cells = m.get('cells') or []
                        exits = [{'x': cell.get('x'), 'y': cell.get('y'), 'name': cell.get('name'),
                                  'char': cell.get('char')}
                                 for cell in cells if cell.get('is_exit') or cell.get('door')]
                        legend = dict(m.get('legend') or {})
                        for cell in cells:
                            ch, nm = cell.get('char'), cell.get('name')
                            if ch and nm and ch not in legend:
                                legend[ch] = nm
                        out = {'x': m.get('x'), 'y': m.get('y'), 'width': m.get('width'),
                               'height': m.get('height'), 'rows': m.get('rows'), 'legend': legend,
                               'exits': exits, 'cells': cells}
                    elif c.get('mapfull') or c.get('level_map'):
                        margs = {'session_id': state['connection']['session_id'], 'source': 'native_map'}
                        region = c.get('region') or (c.get('mapfull') if isinstance(c.get('mapfull'), dict) else None)
                        if region:
                            margs['format'] = 'region'
                            margs['region'] = region
                        else:
                            margs['format'] = 'rows'
                        out = await call('tome.map', margs)
                    elif c.get('sheet'):
                        out = await call('tome.inspect', {'session_id': state['connection']['session_id'],
                                                          'kind': 'character', 'id': 'self'})
                    elif c.get('bench'):
                        n = c['bench'] if isinstance(c['bench'], int) and c['bench'] > 0 else 50
                        n = min(n, 1000)
                        lat = []
                        snap = None
                        for _ in range(n):
                            t0 = time.perf_counter()
                            snap = await observe()
                            lat.append((time.perf_counter() - t0) * 1000.0)
                        lat.sort()

                        def pct(p):
                            return round(lat[min(len(lat) - 1, int(len(lat) * p))], 3)

                        rss = None
                        try:
                            for line in open('/proc/self/status'):
                                if line.startswith('VmRSS:'):
                                    rss = int(line.split()[1])
                                    break
                        except Exception:
                            pass
                        out = {'samples': n, 'p50_ms': pct(0.50), 'p95_ms': pct(0.95), 'p99_ms': pct(0.99),
                               'max_ms': round(lat[-1], 3), 'rss_kb': rss,
                               'lua_heap_kb': (snap or {}).get('lua_heap_kb')}
                    elif c.get('status'):
                        cid = c['status'] if isinstance(c['status'], str) else state.get('command_id')
                        if not cid:
                            out = {'error': 'no command_id tracked'}
                        else:
                            sargs = {'session_id': state['connection']['session_id'], 'command_id': cid}
                            if c.get('compact'):
                                sargs['compact'] = True
                            out = await call('tome.status', sargs)
                    elif c.get('list'):
                        out = await call('tome.list', {'session_id': state['connection']['session_id'],
                                                       'request': c['list']})
                    elif c.get('dismiss'):
                        out = await call('tome.dismiss', {'session_id': state['connection']['session_id'],
                                                          'control_token': state['connection']['control_token'],
                                                          'answer': c['dismiss']})
                    elif c.get('inspect'):
                        out = await call('tome.inspect', {'session_id': state['connection']['session_id'],
                                                          **c['inspect']})
                    elif c.get('walk'):
                        stop_on_enemy = c.get('stop_on_enemy', 'visible')
                        out = []
                        moved = 0
                        initial_enemies = None
                        for direction in c['walk']:
                            s = await observe()
                            actors = s.get('actors') or []
                            player = s.get('player') or {}
                            faction = player.get('faction')
                            enemies = [a for a in actors
                                       if a.get('hostile') is True
                                       or (a.get('hostile') is None and a.get('faction') and faction
                                           and a.get('faction') != faction)]
                            if initial_enemies is None:
                                initial_enemies = {a.get('id') for a in enemies}
                            adjacent = any(max(abs(a.get('x', 0) - player.get('x', 0)),
                                               abs(a.get('y', 0) - player.get('y', 0))) <= 1 for a in enemies)
                            newly_visible = any(a.get('id') not in initial_enemies for a in enemies)
                            # 'visible' must not freeze movement when an enemy was already
                            # visible: stop only for an adjacent or newly appeared enemy so
                            # the caller can still move or flee.
                            if stop_on_enemy == 'adjacent':
                                stop = adjacent
                            elif stop_on_enemy == 'visible':
                                stop = adjacent or newly_visible
                            else:
                                stop = False
                            if s.get('phase') != 'ready' or stop:
                                reason = 'not_ready'
                                if s.get('phase') == 'ready':
                                    reason = 'enemy_adjacent' if adjacent else 'enemy_visible'
                                out = [{'interrupted': snapshot_summary(s),
                                        'player': {k: player.get(k) for k in ('x', 'y', 'life', 'faction')},
                                        'enemies': [{'id': a.get('id'), 'name': a.get('name'),
                                                     'x': a.get('x'), 'y': a.get('y')} for a in enemies],
                                        'stop_on_enemy': stop_on_enemy, 'moved_steps': moved,
                                        'stop_reason': reason, 'status': 'interrupted', 'code': reason}]
                                break
                            res = await action({'type': 'move', 'direction': direction},
                                               c.get('reason', 'Follow observed route'))
                            entry = {'status': res.get('status'), 'code': res.get('code'),
                                     'action_ok': res.get('action_ok'), 'hint': res.get('hint'),
                                     'moved_steps': moved + 1,
                                     'player': {k: (state['current'] or {}).get('player', {}).get(k) for k in ('x', 'y', 'life')}}
                            if isinstance(res, dict) and '_error' in res:
                                entry['error'] = res['_error']
                                out = [entry]
                                break
                            if res.get('status') == 'completed':
                                moved += 1
                            out = [entry]
                            if res.get('status') != 'completed':
                                break
                    elif 'observe' in c or not c:
                        obs = c.get('observe')
                        if isinstance(obs, dict):
                            conn = state['connection']
                            oargs = {'session_id': conn['session_id'], 'radius': 12, 'include_map': False}
                            if obs.get('sections'):
                                oargs['sections'] = obs['sections']
                            if obs.get('detail'):
                                oargs['detail'] = obs['detail']
                            snap = await call('tome.observe', oargs)
                            if isinstance(snap, dict) and '_error' in snap:
                                out = snap
                            else:
                                if isinstance(snap, dict):
                                    state['current'] = snap
                                out = snapshot_summary(snap)
                        else:
                            out = snapshot_summary(await observe())
                    else:
                        # Unknown top-level keys must not silently become an observe.
                        out = {'error': {'code': 'unknown_command_key', 'keys': sorted(c.keys()),
                                         'hint': 'actions are {"action":{...}}; also {"observe":true}, '
                                                 '{"map":true}, {"list":{...}}, {"respond":{...}}, '
                                                 '{"inspect":{...}}, {"walk":[...]}'}}
                    emit({'ok': True, 'result': out})
                except Exception as exc:  # keep the console alive for the agent
                    emit({'ok': False, 'error': repr(exc)})
    finally:
        (r.session / 'play-summary.json').write_text(json.dumps(
            {'submitted_actions': state['counter'], 'last_snapshot': state['current'],
             'normal_campaign': True, 'cheat': False}, indent=2))
        transcript.close()
        decisions.close()
        r.close()


asyncio.run(main())
