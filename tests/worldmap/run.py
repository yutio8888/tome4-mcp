#!/usr/bin/env python3
"""Navigate exclusively from MCP observations in a copy of the published Lv5 world save."""
from __future__ import annotations
import argparse
import asyncio
from collections import deque
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import time
import traceback
from mcp import Client,StdioServerParameters

spec=importlib.util.spec_from_file_location('world_runtime',Path(__file__).with_name('runtime.py'))
world=importlib.util.module_from_spec(spec);spec.loader.exec_module(world)
campaign=world.campaign
spec=importlib.util.spec_from_file_location('world_acceptance',Path(__file__).resolve().parents[1]/'interactions/run.py')
interactive=importlib.util.module_from_spec(spec);spec.loader.exec_module(interactive)
DIRECTIONS={1:(-1,1),2:(0,1),3:(1,1),4:(-1,0),6:(1,0),7:(-1,-1),8:(0,-1),9:(1,-1)}

class Acceptance(interactive.Acceptance):
    async def observe(self):
        return await self.call('tome.observe',dict(session_id=self.connection['session_id'],radius=12))

    def record(self,name,s):
        (self.runtime.session/(name+'.json')).write_text(json.dumps(s,ensure_ascii=False,indent=2))

    def terrain(self,s):return {(c['x'],c['y']):c for c in s['map']['cells']}

    def no_leak(self,s,name):
        unknown=[c for c in s['map']['cells'] if not c['known']]
        self.check(bool(unknown) and all(set(c)=={'x','y','char','known','visible'} and c['char']=='?' and not c['visible'] for c in unknown),name)

    def route(self,s,target):
        cells=self.terrain(s);p=s['player'];start=(p['x'],p['y']);queue=deque([(start,[]) ]);seen={start}
        while queue:
            point,path=queue.popleft()
            if point==target:return path
            for direction,(dx,dy) in DIRECTIONS.items():
                nxt=(point[0]+dx,point[1]+dy);tile=cells.get(nxt,{})
                if nxt in seen or not tile.get('known') or tile.get('blocked') is not False:continue
                seen.add(nxt);queue.append((nxt,path+[direction]))
        return None

    async def action(self,action):
        record,args,before=await self.act(action)
        while record['status'] in ('queued','executing','settling'):
            await asyncio.sleep(.05)
            record=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=record['command_id']))
        while record['status']=='awaiting_input':
            assert record['interaction']['kind']=='dialog.notice',record
            record,_=await self.answer(record,dict(type='option',option_id=record['interaction']['options'][0]['option_id']))
        self.check(record['execution_released'] and (record['status']=='completed' or action['type']=='change_level' and record['code']=='scene_changed'),
                   'native_action_released_'+str(self.sequence),action=action,result=record['status'],code=record.get('code'))
        if action['type']=='change_level':self.connection=await self.call('tome.connect',{})
        s=await self.observe();assert s['phase']=='ready' and s['player']['life']>0
        self.commands.append(dict(action=action,command_id=record['command_id'],status=record['status'],code=record.get('code')))
        return s

    async def run(self):
        deadline=time.monotonic()+90
        while '[MCP Bridge] Listening' not in (self.runtime.session/'game.log').read_text(errors='replace'):
            assert self.runtime.process.poll() is None and time.monotonic()<deadline
            await asyncio.sleep(.05)
        await asyncio.sleep(.3)
        params=StdioServerParameters(command=sys.executable,args=['-m','tome_mcp'],env={**os.environ,
            'PYTHONPATH':str(self.runtime.server_source),'TOME_MCP_PORT':str(self.runtime.port),'TOME_MCP_TOKEN':self.runtime.token})
        self.commands=[]
        async with Client(params) as client:
            self.client=client;self.connection=await self.call('tome.connect',{})
            s=await self.observe();self.initial=s;self.record('initial',s)
            expected=self.runtime.source_record['expected_state'];p=s['player'];old=expected['player']
            keys=('x','y','level','life','max_life','exp','stats','effects','unused_stats','unused_talents','unused_generics','unused_talents_types')
            self.check(s['scene']==expected['scene'] and all(p[k]==old[k] for k in keys)
                       and p['resources']['stamina']==old['stamina'],'load_matches_published_lv5_world_state')
            items=lambda player:sorted((i['name'],i['count'],i['container'],i.get('activation')) for i in player['inventory']+player['equipment'])
            self.check(items(p)==items(old),'load_matches_published_items_and_power')
            origin=(p['x'],p['y']);cells=self.terrain(s);visible=[c for c in cells.values() if c['visible']]
            self.check(0<len(visible)<len(cells)==625 and cells[origin]['known'] and cells[origin]['is_exit'],
                       'world_visible_terrain_and_underfoot_entrance_recovered',visible=len(visible),known=sum(c['known'] for c in cells.values()))
            self.no_leak(s,'undiscovered_cells_hide_names_blocking_and_exits')
            for _ in range(3):
                again=await self.observe()
                self.check(again['map']==s['map'] and again['player']==s['player'] and again['world_tick']==s['world_tick'],
                           'read_only_observation_preserves_map_player_and_turn')
        # Closing the first MCP client terminates its server and bridge socket.
        # Re-open a new MCP process to exercise real TCP disconnect/reconnect.
        async with Client(params) as client:
            self.client=client
            self.connection=await self.call('tome.connect',{});again=await self.observe()
            self.check(again['map']==s['map'] and again['session_id']==s['session_id'],'tcp_reconnect_preserves_visible_world_and_memory')
            adjacent=next((d for d,(dx,dy) in DIRECTIONS.items() if cells.get((origin[0]+dx,origin[1]+dy),{}).get('visible')
                           and cells[(origin[0]+dx,origin[1]+dy)].get('blocked') is False),None)
            assert adjacent is not None
            moved=await self.action(dict(type='move',direction=adjacent));self.record('after-move',moved)
            dx,dy=DIRECTIONS[adjacent]
            self.check((moved['player']['x'],moved['player']['y'])==(origin[0]+dx,origin[1]+dy),'visible_passable_neighbor_allows_native_move')
            self.check(any(self.terrain(moved)[point]['visible']!=cell['visible'] for point,cell in cells.items() if point in self.terrain(moved)),
                       'native_fov_updates_after_movement')
            self.no_leak(moved,'movement_does_not_disclose_unknown_terrain')
            back=next(d for d,v in DIRECTIONS.items() if v==(-dx,-dy))
            s=await self.action(dict(type='move',direction=back))
            candidates=[c for c in self.terrain(s).values() if c.get('visible') and c.get('is_exit') and (c['x'],c['y'])!=origin
                        and self.route(s,(c['x'],c['y']))]
            self.check(bool(candidates),'another_native_entrance_is_visible_and_reachable')
            candidates.sort(key=lambda c:(c['char']!='*',len(self.route(s,(c['x'],c['y'])))))
            destination=candidates[0];self.destination=destination;self.record('destination',destination)
            for _ in range(40):
                point=(s['player']['x'],s['player']['y'])
                if point==(destination['x'],destination['y']):break
                route=self.route(s,(destination['x'],destination['y']));assert route
                s=await self.action(dict(type='move',direction=route[0]))
            self.check((s['player']['x'],s['player']['y'])==(destination['x'],destination['y']),
                       'navigation_reaches_entrance_using_only_observed_passable_cells')
            self.record('at-destination',s)
            # Confirm another entrance's terrain and route, then test entry at
            # the previously visited Trollmire. New random escorts are outside
            # this visibility regression and require an unsupported native chat.
            for _ in range(40):
                if (s['player']['x'],s['player']['y'])==origin:break
                route=self.route(s,origin);assert route
                s=await self.action(dict(type='move',direction=route[0]))
            self.check((s['player']['x'],s['player']['y'])==origin,'observed_route_returns_to_known_trollmire_entrance')
            entered=await self.action(dict(type='change_level'));self.record('entered-zone',entered)
            self.check(entered['scene']['zone_id']=='trollmire' and any(c['visible'] for c in entered['map']['cells']),
                       'native_change_level_enters_observed_destination_with_dungeon_fov')
            entered=await self.action(dict(type='change_level'));self.record('returned-world',entered)
            self.check(entered['scene']['zone_id']=='wilderness' and any(c['visible'] for c in entered['map']['cells']),
                       'native_return_to_world_restores_applyLite_observation')
            self.no_leak(entered,'return_to_world_keeps_unknown_cells_private')
            self.final=entered
            self.check(entered['battle_companion']['state']=='idle' and entered['battle_companion']['actions']==0,'battle_companion_keeps_idle')
            await self.call('tome.stop',dict(session_id=self.connection['session_id'],control_token=self.connection['control_token']))
            before=(self.runtime.session/'game.log').read_text(errors='replace')
            self.runtime.input.chord('Control_L','s');deadline=time.monotonic()+60
            while 'Saving done.' not in (self.runtime.session/'game.log').read_text(errors='replace')[len(before):]:
                assert time.monotonic()<deadline;await asyncio.sleep(.05)
            self.check(True,'native_save_completed_after_world_roundtrip')
        old_session=self.final['session_id']
        self.runtime.restart_from_saved_copy()
        deadline=time.monotonic()+90
        while '[MCP Bridge] Listening' not in (self.runtime.session/'reload.log').read_text(errors='replace'):
            assert self.runtime.process.poll() is None and time.monotonic()<deadline
            await asyncio.sleep(.05)
        await asyncio.sleep(.3)
        async with Client(params) as client:
            self.client=client;self.connection=await self.call('tome.connect',{})
            reloaded=await self.observe();self.record('reloaded-world',reloaded)
            keys=('x','y','level','life','max_life','exp','stats','effects')
            self.check(reloaded['session_id']!=old_session and reloaded['phase']=='ready'
                       and reloaded['scene']==self.final['scene']
                       and all(reloaded['player'][k]==self.final['player'][k] for k in keys)
                       and items(reloaded['player'])==items(self.final['player']),
                       'saved_world_copy_reloads_native_state_without_old_command')
            self.check(any(c['visible'] for c in reloaded['map']['cells']), 'reloaded_world_has_native_visible_terrain')
            self.no_leak(reloaded,'reload_does_not_import_hidden_native_map_memory')
            self.reloaded=reloaded
            await self.call('tome.stop',dict(session_id=self.connection['session_id'],control_token=self.connection['control_token']))

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('session');args=parser.parse_args()
    runtime=world.CampaignRuntime(args.session,world.WORLD_SESSION,campaign.WORKSPACE/'game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa',source_record='campaign-play-v060-02')
    for p in Path(__file__).parent.glob('*.py'):shutil.copy2(p,runtime.session/('worldmap-'+p.name))
    run=Acceptance(runtime);error=None
    try:runtime.start();asyncio.run(run.run())
    except Exception:error=traceback.format_exc();print(error,flush=True)
    finally:runtime.close()
    unchanged=runtime.source_unchanged();logs='\n'.join(p.read_text(errors='replace') for p in runtime.log_paths)
    result=dict(passed=error is None and unchanged and 'Lua Error:' not in logs and 'stack traceback:' not in logs,
        error=error,checks=run.checks,commands=getattr(run,'commands',[]),final=getattr(run,'final',None),
        historical_sources_unchanged=unchanged,normal_campaign=True,gameplay_fixture=False,cheat=False,
        source_record='campaign-play-v060-02',navigation_source='MCP observations only',reloaded=getattr(run,'reloaded',None))
    (runtime.session/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    (runtime.session/'mcp.json').write_text(json.dumps(run.transcript,ensure_ascii=False,indent=2).replace(runtime.token,'<redacted>'))
    print(json.dumps(dict(passed=result['passed'],checks=len(run.checks),session=str(runtime.session))),flush=True)
    return 0 if result['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
