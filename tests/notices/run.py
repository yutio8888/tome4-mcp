#!/usr/bin/env python3
"""Exercise natural quest rewards on a fresh ordinary campaign save copy.

Only official MCP actions and responses affect gameplay. No gameplay probe,
reward injection, stat edits or direct native calls are present.
"""
from __future__ import annotations
import argparse
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import time
import traceback
from collections import deque
from mcp import Client, StdioServerParameters

TESTS=Path(__file__).resolve().parents[1]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result)
    return result
interactive=module('notice_interactive_driver',TESTS/'interactions/run.py')
campaign=module('notice_campaign_runtime',TESTS/'campaign/runtime.py')
WORKSPACE=campaign.WORKSPACE
SOURCE=WORKSPACE/'tmp/tome-mcp-validation/sessions/campaign-play-v050-01/campaign-mcp.jsonl'

def objects(s):
    p=s.get('player',{})
    return [p,*s.get('actors',[]),*p.get('inventory',[]),*p.get('equipment',[]),*s.get('ground',{}).get('items',[])]

class Acceptance(interactive.Acceptance):
    def __init__(self,runtime,handoff=False):
        super().__init__(runtime,True)
        self.handoff=handoff;self.notices=[];self.commands=[]
        self.recorded=[json.loads(line) for line in SOURCE.open()]

    async def observe(self):
        return await self.call('tome.observe',dict(session_id=self.connection['session_id']))

    @staticmethod
    def enemies(s):
        p=s['player']
        return sorted((a for a in s['actors'] if a.get('faction')=='enemies' or a.get('reaction',0)<0),
                      key=lambda a:max(abs(a['x']-p['x']),abs(a['y']-p['y'])))

    def route(self,s,x,y):
        directions={7:(-1,-1),8:(0,-1),9:(1,-1),4:(-1,0),6:(1,0),1:(-1,1),2:(0,1),3:(1,1)}
        cells={(c['x'],c['y']):c for c in s['map']['cells'] if c.get('known')}
        origin=(s['player']['x'],s['player']['y']);queue=deque([origin]);first={origin:None}
        occupied={(a['x'],a['y']) for a in s['actors']}
        candidates=[]
        visits=getattr(self,'route_visits',{})
        while queue:
            xy=queue.popleft()
            if xy==(x,y):return first[xy]
            if xy!=origin:
                unknown=sum((xy[0]+dx,xy[1]+dy) not in cells for dx,dy in directions.values())
                candidates.append((max(abs(x-xy[0]),abs(y-xy[1]))*4+visits.get(xy,0)*12-min(unknown,3),xy,first[xy]))
            for d,(dx,dy) in directions.items():
                n=(xy[0]+dx,xy[1]+dy);cell=cells.get(n)
                if n in first or n in occupied or not cell or cell.get('blocked') or cell.get('char') in {'#','?',' '}:continue
                first[n]=d if xy==origin else first[xy];queue.append(n)
        return min(candidates)[-1] if candidates else None

    async def submit(self,action,intent=None):
        before=await self.observe();number=len(self.commands)+1
        if before['control_source']!='remote':
            self.connection=await self.call('tome.connect',{})
        result,args,_=await self.act(action,command_id='notice-'+str(number))
        while result.get('status')=='awaiting_input':
            if result['interaction']['kind']=='dialog.notice':result=await self.notice(result,args)
            else:
                assert intent,result
                if result['interaction']['kind']=='target.direction':
                    s=await self.observe();e=next(a for a in s['actors'] if a['id']==intent);p=s['player']
                    dx=(e['x']>p['x'])-(e['x']<p['x']);dy=(e['y']>p['y'])-(e['y']<p['y'])
                    direction={(1,0):6,(-1,0):4,(0,1):2,(0,-1):8,(1,1):3,(-1,1):1,(1,-1):9,(-1,-1):7}[(dx,dy)]
                    answer=dict(type='direction',direction=direction)
                else:
                    assert result['interaction']['kind']=='target.grid',result
                    answer=dict(type='actor',target_id=intent)
                result,_=await self.answer(result,answer)
        self.commands.append(dict(number=number,action=action,result=result))
        print(json.dumps(dict(command=number,action=action,status=result['status'],code=result.get('code'))),flush=True)
        assert result['status'] in {'completed','failed'} or self.handoff and self.notices,result
        after=await self.observe()
        assert after['phase']=='ready' and after['player']['life']>0
        self.route_visits=getattr(self,'route_visits',{})
        xy=(after['player']['x'],after['player']['y'])
        self.route_visits[xy]=self.route_visits.get(xy,0)+1
        return result

    async def battle(self):
        # Keep the original, naturally earned growth allocation. Combat adapts
        # to actors actually perceived in this new native run: load-time RNG and
        # enemy decisions make a literal transcript replay unsuitable.
        for row in self.recorded:
            if row['tool']=='tome.act' and int(row['args']['command_id'].split('-')[-1])<=20:
                await self.submit(row['args']['action'])
        # The prior trial found this weapon on visible Trollmire 2 ground.
        # Navigate and fight from fresh observations before picking it up.
        for destination in ('weapon','exit'):
            goal=(57,34) if destination=='weapon' else (64,36)
            for _ in range(100):
                s=await self.observe();p=s['player'];enemies=self.enemies(s)
                if destination=='weapon':
                    visible=next((o for o in s['ground']['items'] if o['name']=='iron greatmaul'),None)
                    if visible:goal=(visible['x'],visible['y'])
                if enemies:
                    action,intent=self.combat_action(s);await self.submit(action,intent);continue
                if p['life']<p['max_life'] or p['resources']['stamina']['value']<p['resources']['stamina']['max']:
                    await self.submit(dict(type='rest',max_turns=150));continue
                if (p['x'],p['y'])==goal:break
                direction=self.route(s,*goal);assert direction,(goal,p['x'],p['y'])
                await self.submit(dict(type='move',direction=direction))
            else:raise AssertionError('Visible route did not finish')
            if destination=='weapon':
                s=await self.observe();items=[o for o in s['ground']['items'] if o['underfoot']]
                for o in items:await self.submit(dict(type='pickup',item_id=o['id']))
                s=await self.observe()
                weapon=next(o for o in s['player']['inventory'] if o['name']=='iron greatmaul')
                await self.submit(dict(type='equip',item_id=weapon['id']))
        await self.submit(dict(type='change_level'))
        await self.submit(dict(type='use_talent',talent_id='T_INFUSION:_WILD_2'))
        boss_seen=False;loot=None
        retreating=False
        for _ in range(400):
            s=await self.observe();p=s['player'];enemies=self.enemies(s)
            for a in enemies:
                if a['name']=='Prox the Mighty':boss_seen=True;loot=(a['x'],a['y'])
            if s['scene']['level']==2:
                talents={t['id']:t for t in s['talents']}
                if p['life']<p['max_life'] or any(t.get('cooldown',0)>0 for t in talents.values()):
                    if p['life']<p['max_life']-40 and talents.get('T_INFUSION:_HEALING_3',{}).get('cooldown')==0:
                        await self.submit(dict(type='use_talent',talent_id='T_INFUSION:_HEALING_3'))
                    else:await self.submit(dict(type='rest',max_turns=150))
                    continue
                await self.submit(dict(type='change_level'))
                await self.submit(dict(type='use_talent',talent_id='T_INFUSION:_WILD_2'))
                retreating=False
                continue
            talents={t['id']:t for t in s['talents']}
            healing_ready=talents.get('T_INFUSION:_HEALING_3',{}).get('cooldown')==0
            if p['life']<p['max_life']*.62 and not healing_ready:retreating=True
            if retreating:
                if (p['x'],p['y'])==(0,5):await self.submit(dict(type='change_level'))
                else:
                    direction=self.route(s,0,5)
                    if direction:await self.submit(dict(type='move',direction=direction))
                    else:
                        action,intent=self.combat_action(s);await self.submit(action,intent)
                continue
            if not enemies and boss_seen and p['level']>=5:break
            action,intent=self.combat_action(s)
            await self.submit(action,intent)
            if self.handoff and self.notices:return
        else:raise AssertionError('Natural boss encounter did not finish within the action bound')
        self.check(boss_seen and loot is not None,'prox_seen_and_defeated_through_native_combat')
        for _ in range(30):
            s=await self.observe();p=s['player']
            if (p['x'],p['y'])==loot:break
            direction=self.route(s,*loot);assert direction,(loot,s['ground'])
            await self.submit(dict(type='move',direction=direction))
        for _ in range(32):
            s=await self.observe();items=[o for o in s['ground']['items'] if o['underfoot']]
            if not items:break
            await self.submit(dict(type='pickup',item_id=items[0]['id']))
        for _ in range(20):
            s=await self.observe()
            paper=next((o for o in s['ground']['items'] if o['name']=='tattered paper scrap'),None)
            if not paper:break
            if paper['underfoot']:
                await self.submit(dict(type='pickup',item_id=paper['id']));break
            direction=self.route(s,paper['x'],paper['y']);assert direction,paper
            await self.submit(dict(type='move',direction=direction))
        await self.submit(dict(type='rest',max_turns=150))

    def combat_action(self,s):
        p=s['player'];enemies=self.enemies(s);talents={t['id']:t for t in s['talents']}
        ready=lambda tid:talents.get(tid,{}).get('cooldown')==0
        effects={e['id'] for e in p['effects']};hurt=p['max_life']-p['life']
        def skill(tid,target=None):return dict(type='use_talent',talent_id=tid),target
        if hurt>max(40,p['max_life']*.32) and ready('T_INFUSION:_HEALING_3'):return skill('T_INFUSION:_HEALING_3')
        if effects & {'EFF_STUNNED','EFF_DAZED','EFF_DISARMED','EFF_PINNED','EFF_CONFUSED'} and ready('T_INFUSION:_WILD_2'):
            return skill('T_INFUSION:_WILD_2')
        if enemies and hurt>12 and 'EFF_REGENERATION' not in effects and ready('T_INFUSION:_REGENERATION_1'):
            return skill('T_INFUSION:_REGENERATION_1')
        if enemies:
            e=enemies[0];dist=max(abs(e['x']-p['x']),abs(e['y']-p['y']));stamina=p['resources']['stamina']['value']
            if dist<=6 and stamina>=40 and ready('T_WARSHOUT_BERSERKER'):return skill('T_WARSHOUT_BERSERKER',e['id'])
            if dist<=1 and stamina>=15 and ready('T_STUNNING_BLOW_ASSAULT'):return skill('T_STUNNING_BLOW_ASSAULT',e['id'])
            if dist<=1:return dict(type='attack',target_id=e['id']),e['id']
            if dist<=4 and stamina>=37 and ready('T_RUSH'):return skill('T_RUSH',e['id'])
        return dict(type='wait'),None

    async def notice(self,record,args):
        original=record['command_id'];last_sequence=0
        while record.get('status')=='awaiting_input' and record['interaction']['kind']=='dialog.notice':
            h=record['interaction'];before=await self.observe()
            self.check(h['sequence']>last_sequence,'notice_sequence_increases',interaction=h)
            last_sequence=h['sequence']
            self.check(not record['execution_released'] and before['control_source']=='remote','notice_retains_command_execution')
            duplicate=await self.call('tome.act',args)
            stable=await self.observe()
            self.check(duplicate['interaction']['interaction_id']==h['interaction_id'] and stable['player']==before['player']
                       and stable['world_tick']==before['world_tick'],'duplicate_action_preserves_committed_reward')
            if not self.notices:
                # Explicit reconnect reclaims the same pending command and UI.
                self.connection=await self.call('tome.connect',{})
                fresh=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=original))
                self.check(fresh['interaction']['interaction_id']==h['interaction_id'],'notice_survives_reconnect')
                record=fresh
            if self.handoff and not self.notices:
                await self.call('tome.stop',dict(session_id=self.connection['session_id'],control_token=self.connection['control_token']))
                pending=await self.observe()
                self.check(pending['phase']=='needs_input' and pending['player']==before['player'],'manual_handoff_keeps_committed_reward')
                self.runtime.input.press('Escape')
                await asyncio.sleep(.2)
                self.connection=await self.call('tome.connect',{})
                settled=await self.observe()
                historical=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=original))
                self.check(settled['phase']=='ready' and historical['status']=='needs_input' and historical['execution_released'],
                           'manual_close_releases_without_rewriting_historical_status')
                self.check(settled['player']['level']==before['player']['level'] and settled['player']['exp']==before['player']['exp'],
                           'manual_close_does_not_repeat_experience')
                self.notices.append(dict(command_id=original,interaction=h,handoff=True))
                return historical
            done,response_args=await self.answer(record,dict(type='option',option_id=h['options'][0]['option_id']))
            after=await self.observe()
            again=await self.call('tome.respond',response_args)
            stable=await self.observe()
            self.check(again['response_receipt']['state']=='applied' and stable['player']==after['player']
                       and stable['world_tick']==after['world_tick'],'duplicate_notice_answer_is_inert')
            self.check(done['command_id']==original,'notice_continues_original_command')
            self.notices.append(dict(command_id=original,interaction=h,before=before,after=after))
            record=done
        return record

    async def run(self):
        deadline=time.monotonic()+90
        while '[MCP Bridge] Listening' not in (self.runtime.session/'game.log').read_text(errors='replace'):
            assert self.runtime.process.poll() is None and time.monotonic()<deadline
            await asyncio.sleep(.05)
        await asyncio.sleep(.3)
        params=StdioServerParameters(command=sys.executable,args=['-m','tome_mcp'],
            env={**os.environ,'PYTHONPATH':str(self.runtime.server_source),'TOME_MCP_PORT':str(self.runtime.port),'TOME_MCP_TOKEN':self.runtime.token})
        async with Client(params) as client:
            self.client=client
            self.connection=await self.call('tome.connect',{})
            initial=await self.observe()
            self.check(initial['phase']=='ready' and initial['player']['level']==3,'exact_ordinary_level_three_source')
            await self.battle()
            self.final=await self.observe()
            if not self.handoff:
                self.check(len(self.notices)>=7,'natural_notices_answered_without_escape',count=len(self.notices))
                self.check({n['interaction']['native_ui'] for n in self.notices}=={'QuestPopup','LorePopup','simplePopup'},
                           'natural_quest_lore_and_item_tutorial_classes')
                self.check(self.final['player']['level']==5,'natural_prox_experience_committed_once')
                self.check(sum(o['count'] for o in self.final['player']['inventory'] if o['name']=='Rod of Recall')==1,
                           'natural_rod_pickup_committed_once')
                grouped={}
                for n in self.notices:grouped.setdefault(n['command_id'],set()).add(n['interaction']['native_ui'])
                self.check(any(kinds=={'QuestPopup','LorePopup','simplePopup'} for kinds in grouped.values()),
                           'natural_paper_pickup_closes_three_different_native_layers')
                rod=next(o for o in self.final['player']['inventory'] if o['name']=='Rod of Recall')
                before=rod['activation']['power']
                used=await self.submit(dict(type='use_item',item_id=rod['id']))
                after=await self.observe()
                detail=await self.call('tome.inspect',dict(session_id=self.connection['session_id'],kind='item',id=rod['id']))
                self.check(used['status']=='completed' and used['native_return'] and used['energy_spent']>0
                           and any(e['id']=='EFF_RECALL' for e in after['player']['effects']) and detail['activation']['power']<before,
                           'naturally_obtained_rod_uses_generic_native_item_entrypoint')
                self.final=after
            self.check(self.final['battle_companion']['state']=='idle' and self.final['battle_companion']['actions']==0,
                       'battle_companion_remains_idle')
            await self.call('tome.stop',dict(session_id=self.connection['session_id'],control_token=self.connection['control_token']))
            before=(self.runtime.session/'game.log').read_text(errors='replace')
            self.runtime.input.chord('Control_L','s')
            deadline=time.monotonic()+60
            while 'Saving done.' not in (self.runtime.session/'game.log').read_text(errors='replace')[len(before):]:
                assert time.monotonic()<deadline
                await asyncio.sleep(.05)
            self.check(True,'native_save_completed')

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('session')
    parser.add_argument('--addon-archive',type=Path);parser.add_argument('--handoff',action='store_true')
    args=parser.parse_args()
    runtime=campaign.CampaignRuntime(args.session,campaign.CONTINUATION_SESSION,args.addon_archive)
    shutil.copy2(__file__,runtime.session/'notice-run.py')
    acceptance=Acceptance(runtime,args.handoff);error=None
    try:
        runtime.start();asyncio.run(acceptance.run())
    except Exception:
        error=traceback.format_exc();print(error,flush=True)
    finally:runtime.close()
    unchanged=runtime.source_unchanged()
    logs=(runtime.session/'game.log').read_text(errors='replace')
    passed=error is None and unchanged and 'Lua Error:' not in logs and 'stack traceback:' not in logs
    result=dict(passed=passed,error=error,checks=acceptance.checks,notices=acceptance.notices,
                commands=acceptance.commands,final=getattr(acceptance,'final',None),historical_sources_unchanged=unchanged,
                normal_campaign=True,gameplay_fixture=False,cheat=False,recorded_growth_allocation=True,
                observation_driven_combat=True)
    (runtime.session/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    (runtime.session/'mcp.json').write_text(json.dumps(acceptance.transcript,ensure_ascii=False,indent=2).replace(runtime.token,'<redacted>'))
    print(json.dumps(dict(passed=passed,checks=len(acceptance.checks),evidence=str(runtime.session))),flush=True)
    return 0 if passed else 1
if __name__=='__main__':raise SystemExit(main())
