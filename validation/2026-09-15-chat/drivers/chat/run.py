#!/usr/bin/env python3
"""Natural escort through MCP only, from an explicitly published save copy."""
from __future__ import annotations
from pathlib import Path
import importlib.util
import argparse
import asyncio
from collections import deque,Counter
import json
import math
import os
import shutil
import sys
import time
import traceback
from mcp import Client,StdioServerParameters

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
TESTS=Path(__file__).resolve().parents[1]
world=module('chat_world_driver',TESTS/'worldmap/run.py')
source=module('chat_runtime',Path(__file__).with_name('runtime.py'))
base=world.interactive
DIRECTIONS=world.DIRECTIONS

class Acceptance(world.Acceptance):
    async def settle(self,r):
        for _ in range(1200):
            if r['status'] not in ('queued','executing','settling'):return r
            await asyncio.sleep(.05)
            r=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=r['command_id']))
        raise AssertionError(r)

    async def action(self,action,intent=None):
        r,args,before=await self.act(action);r=await self.settle(r)
        command=r['command_id'];last_sequence=0
        if action['type']=='change_level':
            self.connection=await self.call('tome.connect',dict(protocol_version=2))
            r=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=command))
        while r['status']=='awaiting_input':
            h=r['interaction'];s=await self.observe()
            if h['kind'].startswith('target.'):
                assert intent is not None,(r,intent)
                r,_=await self.answer(r,dict(type='actor',target_id=intent));r=await self.settle(r);continue
            self.check(h['sequence']>last_sequence and not r['execution_released'],'natural_page_retains_original_invocation',native_ui=h.get('native_ui'))
            last_sequence=h['sequence']
            args['control_token']=self.connection['control_token']
            duplicate=await self.call('tome.act',args);stable=await self.observe()
            self.check(stable['player']==s['player'] and stable['world_tick']==s['world_tick']
                       and stable['scene']==s['scene'] and duplicate['command_id']==command,'natural_duplicate_act_never_repeats_committed_action')
            options=h['options']
            if h.get('native_ui')=='Chat':
                self.chat_pages.append(dict(command_id=command,action=action,page=h,before=s))
                names=[o['label'] for o in options]
                selected=next((o for o in options if 'willpower' in o['label'].lower() and ('5' in o['label'] or 'Improve' in o['label'])),None)
                if selected is None:selected=next((o for o in options if 'Improve' in o['label'] and '5' in o['label']),None)
                if selected:self.reward_before=s
                if selected is None:selected=next((o for o in options if 'lead on' in o['label'].lower()),None)
                if selected is None:selected=next((o for o in options if 'thank you' in o['label'].lower()),None)
                assert selected is not None,(names,h)
                print(json.dumps(dict(chat=names,selected=selected['label'],command_id=command)),flush=True)
                choice=selected
            else:
                assert h['kind']=='dialog.notice',r
                choice=options[0]
            r,response_args=await self.answer(r,dict(type='option',option_id=choice['option_id']));r=await self.settle(r)
            after=await self.observe();await self.call('tome.respond',response_args);stable=await self.observe()
            self.check(stable['player']==after['player'] and stable['world_tick']==after['world_tick']
                       and stable['scene']==after['scene'],'natural_duplicate_answer_does_not_reaward_or_change_scene')
            if self.reward_before is not None and 'Improve' in choice['label'] and '5' in choice['label']:
                self.reward_after=after
                self.reward_stat=next(k for k,v in after['player']['stats'].items() if v['bonus']==self.reward_before['player']['stats'][k]['bonus']+5)
                self.check(bool(self.reward_stat),'natural_escort_native_stat_reward_exactly_plus_five',stat=self.reward_stat,label=choice['label'])
        known_rejection=r['status']=='failed' and r.get('code')=='native_rejected' and action['type']=='use_talent'
        if known_rejection:self.rejected_talents.add(action['talent_id'])
        self.check((r['status']=='completed' or known_rejection) and r['execution_released'],'natural_action_settled_'+str(self.sequence),action=action,status=r['status'],code=r.get('code'))
        if action['type']=='change_level':self.connection=await self.call('tome.connect',dict(protocol_version=2))
        s=await self.observe();self.record('observed',s)
        self.commands.append(dict(action=action,command_id=command,status=r['status'],energy=r.get('energy_spent')))
        assert s['phase']=='ready' and s['player']['life']>0,s
        return s

    @staticmethod
    def enemies(s):
        p=s['player'];return sorted([a for a in s['actors'] if a.get('faction')=='enemies' or a.get('reaction',0)<0],
                                    key=lambda a:max(abs(a['x']-p['x']),abs(a['y']-p['y'])))

    def combat(self,s):
        p=s['player'];enemies=self.enemies(s)
        if getattr(self,'protecting',None):
            e=self.protecting
            enemies.sort(key=lambda a:(max(abs(a['x']-e['x']),abs(a['y']-e['y'])),max(abs(a['x']-p['x']),abs(a['y']-p['y']))))
        talents={t['id']:t for t in s['talents']}
        ready=lambda tid:tid not in self.rejected_talents and talents.get(tid,{}).get('cooldown')==0
        effects={e['id'] for e in p['effects']};hurt=p['max_life']-p['life']
        def skill(tid,target=None):return dict(type='use_talent',talent_id=tid),target
        if hurt>max(40,p['max_life']*.32) and ready('T_INFUSION:_HEALING_3'):return skill('T_INFUSION:_HEALING_3')
        if effects & {'EFF_STUNNED','EFF_DAZED','EFF_DISARMED','EFF_PINNED','EFF_CONFUSED'} and ready('T_INFUSION:_WILD_2'):return skill('T_INFUSION:_WILD_2')
        if enemies and hurt>12 and 'EFF_REGENERATION' not in effects and ready('T_INFUSION:_REGENERATION_1'):return skill('T_INFUSION:_REGENERATION_1')
        if enemies:
            e=enemies[0];dist=max(abs(e['x']-p['x']),abs(e['y']-p['y']));stamina=p['resources']['stamina']['value']
            if dist<=6 and stamina>=40 and ready('T_WARSHOUT_BERSERKER'):return skill('T_WARSHOUT_BERSERKER',e['id'])
            if dist<=1 and stamina>=15 and ready('T_STUNNING_BLOW_ASSAULT'):return skill('T_STUNNING_BLOW_ASSAULT',e['id'])
            if dist<=1:return dict(type='attack',target_id=e['id']),e['id']
            if dist<=4 and stamina>=37 and ready('T_RUSH'):return skill('T_RUSH',e['id'])
            if dist>1:
                try:return self.follow(s,e,0),None
                except AssertionError:pass
        return dict(type='wait'),None

    def follow(self,s,escort,stalls):
        p=s['player'];origin=(p['x'],p['y']);goal=(escort['x'],escort['y']);cells=self.terrain(s)
        occupied={(a['x'],a['y']) for a in s['actors']};distance=lambda xy:max(abs(xy[0]-goal[0]),abs(xy[1]-goal[1]))
        if distance(origin)<=1:
            if stalls<3:return dict(type='wait')
            # Give way after three stationary NPC observations. Choose only
            # visible passable cells, preferring space beside the escort.
            moves=[(self.visits[(origin[0]+dx,origin[1]+dy)],distance((origin[0]+dx,origin[1]+dy)),d)
                   for d,(dx,dy) in DIRECTIONS.items() if (origin[0]+dx,origin[1]+dy) not in occupied
                   and cells.get((origin[0]+dx,origin[1]+dy),{}).get('blocked') is False]
            assert moves
            return dict(type='move',direction=min(moves)[2])
        queue=deque([(origin,[])]);seen={origin}
        while queue:
            xy,path=queue.popleft()
            if path and distance(xy)<=1:return dict(type='move',direction=path[0])
            for d,(dx,dy) in DIRECTIONS.items():
                nxt=(xy[0]+dx,xy[1]+dy);tile=cells.get(nxt,{})
                if nxt in seen or nxt in occupied or not tile.get('known') or tile.get('blocked') is not False:continue
                seen.add(nxt);queue.append((nxt,path+[d]))
        raise AssertionError(('no observed escort route',origin,goal))

    def explore(self,s,last_escort):
        cells=self.terrain(s);p=s['player'];origin=p['x'],p['y']
        occupied={(a['x'],a['y']) for a in s['actors']};queue=deque([(origin,[])]);seen={origin};candidates=[]
        while queue:
            xy,path=queue.popleft()
            if path:
                frontier=sum(not cells.get((xy[0]+dx,xy[1]+dy),{}).get('known') for dx,dy in DIRECTIONS.values())
                distance=max(abs(xy[0]-last_escort[0]),abs(xy[1]-last_escort[1])) if last_escort else 0
                candidates.append((0 if frontier else 1,self.visits[xy],distance,len(path),path[0]))
            for d,(dx,dy) in DIRECTIONS.items():
                nxt=xy[0]+dx,xy[1]+dy;tile=cells.get(nxt,{})
                if nxt in seen or nxt in occupied or not tile.get('known') or tile.get('blocked') is not False:continue
                seen.add(nxt);queue.append((nxt,path+[d]))
        assert candidates,'No MCP-known passage to search for escort'
        return dict(type='move',direction=min(candidates)[-1])

    async def wait_ready(self,log):
        deadline=time.monotonic()+90
        while '[MCP Bridge] Listening' not in log.read_text(errors='replace'):
            assert self.runtime.process.poll() is None and time.monotonic()<deadline;await asyncio.sleep(.05)
        await asyncio.sleep(.3)

    async def run(self,load_only=False):
        self.commands=[];self.chat_pages=[];self.reward_before=None;self.reward_after=None;self.visits=Counter();self.rejected_talents=set()
        await self.wait_ready(self.runtime.session/'game.log')
        params=StdioServerParameters(command=sys.executable,args=['-m','tome_mcp'],env={**os.environ,
            'PYTHONPATH':str(self.runtime.server_source),'TOME_MCP_PORT':str(self.runtime.port),'TOME_MCP_TOKEN':self.runtime.token})
        async with Client(params) as client:
            self.client=client;self.connection=await self.call('tome.connect',dict(protocol_version=2));s=await self.observe();self.record('initial',s)
            expected=self.runtime.source_record['expected_state'];old=expected['player'];p=s['player']
            keys=('x','y','level','life','max_life','exp','stats','effects','unused_stats','unused_talents','unused_generics','unused_talents_types')
            self.check(s['scene']==expected['scene'] and all(p[k]==old[k] for k in keys if k!='exp') and math.isclose(p['exp'],old['exp'],abs_tol=1e-9)
                       and p['resources']['stamina']==old['stamina'],'load_matches_exact_published_source_state')
            items=lambda player:sorted((i['name'],i['count'],i['container'],i.get('activation')) for i in player['inventory']+player['equipment'])
            self.check(items(p)==items(old),'load_matches_published_inventory_and_equipment')
            if not load_only:
                # The destination must already appear in MCP-visible terrain.
                destination=next(c for c in s['map']['cells'] if c.get('visible') and c.get('is_exit') and "Kor'Pul" in c.get('name',''))
                for _ in range(30):
                    if (s['player']['x'],s['player']['y'])==(destination['x'],destination['y']):break
                    route=self.route(s,(destination['x'],destination['y']));assert route
                    s=await self.action(dict(type='move',direction=route[0]))
                s=await self.action(dict(type='change_level'))
                self.check(s['scene']['zone_id']=='ruins-kor-pul' and bool(self.chat_pages),'native_change_level_and_escort_offer_complete_without_reentry')
                last=None;stalls=0
                for page in self.chat_pages:
                    for a in page['before']['actors']:
                        if a.get('faction')=='allied-kingdoms':last=(a['x'],a['y'])
                for step in range(600):
                    failed=[e['text'] for e in s['events']['entries'] if ('Escort:' in e['text'] and 'failed!' in e['text']) or 'quest failed!' in e['text']]
                    assert not failed,('Natural escort failed in combat',failed)
                    self.visits[(s['player']['x'],s['player']['y'])]+=1
                    if self.reward_after:break
                    escorts=[a for a in s['actors'] if a.get('faction')=='allied-kingdoms']
                    self.protecting=escorts[0] if escorts else None
                    if escorts:
                        e=escorts[0];point=e['x'],e['y'];stalls=stalls+1 if point==last else 0;last=point
                    enemies=self.enemies(s)
                    threats=[a for a in enemies if not escorts or max(abs(a['x']-e['x']),abs(a['y']-e['y']))<=6
                             or max(abs(a['x']-s['player']['x']),abs(a['y']-s['player']['y']))<=1]
                    if threats:action,intent=self.combat(s)
                    else:
                        action=self.follow(s,e,stalls) if escorts else self.explore(s,last)
                        intent=None
                    s=await self.action(action,intent)
                self.check(self.reward_after is not None and len(self.chat_pages)>=3,'natural_offer_reward_and_farewell_all_completed_via_mcp')
                self.check(s['player']['stats'][self.reward_stat]['bonus']==self.reward_after['player']['stats'][self.reward_stat]['bonus'],
                           'farewell_keeps_reward_without_second_award')
            self.final=s;self.record('final',s)
            self.check(s['battle_companion']['state']=='idle' and s['battle_companion']['actions']==0,'companion_idle_through_chat_workflow')
            await self.call('tome.stop',dict(session_id=self.connection['session_id'],control_token=self.connection['control_token']))
            before=(self.runtime.session/'game.log').read_text(errors='replace');self.runtime.input.chord('Control_L','s');deadline=time.monotonic()+60
            while 'Saving done.' not in (self.runtime.session/'game.log').read_text(errors='replace')[len(before):]:
                assert time.monotonic()<deadline;await asyncio.sleep(.05)
            self.check(True,'native_save_after_completed_conversation')
        old_session=s['session_id'];self.runtime.restart_from_saved_copy();await self.wait_ready(self.runtime.session/'reload.log')
        async with Client(params) as client:
            self.client=client;self.connection=await self.call('tome.connect',dict(protocol_version=2));loaded=await self.observe();self.record('reloaded',loaded);self.reloaded=loaded
            self.check(loaded['session_id']!=old_session and loaded['phase']=='ready' and loaded['scene']==s['scene']
                       and all(loaded['player'][k]==s['player'][k] for k in keys if k!='exp') and math.isclose(loaded['player']['exp'],s['player']['exp'],abs_tol=1e-9) and items(loaded['player'])==items(s['player']),
                       'new_session_reload_keeps_native_reward_and_has_no_pending_replay')
            await self.call('tome.stop',dict(session_id=self.connection['session_id'],control_token=self.connection['control_token']))

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('session');parser.add_argument('--addon-archive',type=Path)
    parser.add_argument('--load-only',action='store_true');args=parser.parse_args()
    record='campaign-play-v061-01' if args.load_only else 'campaign-play-v060-02'
    runtime=source.CampaignRuntime(args.session,source.campaign.WORKSPACE/'tmp/tome-mcp-validation/sessions'/record,args.addon_archive,source_record=record)
    for group in ('chat','worldmap','interactions'):
        dest=runtime.session/'harness-source'/group;dest.mkdir(parents=True,exist_ok=True)
        for p in (TESTS/group).glob('*.py'):shutil.copy2(p,dest/p.name)
    run=Acceptance(runtime);error=None
    try:runtime.start();asyncio.run(run.run(args.load_only))
    except Exception:error=traceback.format_exc();print(error,flush=True)
    finally:runtime.close()
    unchanged=runtime.source_unchanged();logs='\n'.join(p.read_text(errors='replace') for p in runtime.log_paths)
    result=dict(passed=error is None and unchanged and 'Lua Error:' not in logs and 'stack traceback:' not in logs,error=error,
        checks=run.checks,commands=getattr(run,'commands',[]),chat_pages=getattr(run,'chat_pages',[]),final=getattr(run,'final',None),reloaded=getattr(run,'reloaded',None),
        historical_sources_unchanged=unchanged,normal_campaign=True,gameplay_fixture=False,cheat=False,campaign_complete=False,
        source_record=record,navigation_source='MCP observations only')
    (runtime.session/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    (runtime.session/'mcp.json').write_text(json.dumps(run.transcript,ensure_ascii=False,indent=2).replace(runtime.token,'<redacted>'))
    print(json.dumps(dict(passed=result['passed'],checks=len(run.checks),session=str(runtime.session))),flush=True)
    return 0 if result['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
