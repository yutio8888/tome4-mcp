#!/usr/bin/env python3
"""Reload a copy of this suite's saved natural reward, optionally hand off pickup."""
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
from mcp import Client,StdioServerParameters

spec=importlib.util.spec_from_file_location('notice_driver',Path(__file__).with_name('run.py'))
driver=importlib.util.module_from_spec(spec);spec.loader.exec_module(driver)
campaign=driver.campaign
WORKSPACE=driver.WORKSPACE

class Acceptance(driver.interactive.Acceptance):
    async def run(self,source_result,pickup_handoff):
        deadline=time.monotonic()+90
        while '[MCP Bridge] Listening' not in (self.runtime.session/'game.log').read_text(errors='replace'):
            assert self.runtime.process.poll() is None and time.monotonic()<deadline
            await asyncio.sleep(.05)
        await asyncio.sleep(.3)
        params=StdioServerParameters(command=sys.executable,args=['-m','tome_mcp'],
            env={**os.environ,'PYTHONPATH':str(self.runtime.server_source),'TOME_MCP_PORT':str(self.runtime.port),'TOME_MCP_TOKEN':self.runtime.token})
        async with Client(params) as client:
            self.client=client;self.connection=await self.call('tome.connect',dict(protocol_version=2))
            s=await self.observe();expected=source_result['final'];p=s['player'];old=expected['player']
            keys=('level','exp','life','max_life','x','y','stats','unused_stats','unused_talents','unused_generics','unused_talents_types','effects')
            self.check(all(p.get(k)==old.get(k) for k in keys),'native_reload_preserves_natural_reward_and_effects')
            items=lambda player:sorted((o['name'],o['count'],o.get('container')) for o in player['inventory']+player['equipment'])
            self.check(items(p)==items(old),'native_reload_preserves_inventory_once')
            self.check(s['phase']=='ready' and 'pending_command' not in s and s['session_id']!=expected['session_id'],
                       'native_reload_has_new_session_without_serialized_invocation')
            old_id=source_result['commands'][-1]['result']['command_id']
            missing=await self.raw('tome.status',dict(session_id=s['session_id'],command_id=old_id))
            self.check(not missing['ok'] and missing['error']['code']=='unknown_command','old_command_is_not_restored_as_new_action')
            if pickup_handoff:await self.pickup()
            self.final=await self.observe()
            self.check(self.final['battle_companion']['state']=='idle' and self.final['battle_companion']['actions']==0,
                       'recovery_keeps_battle_companion_idle')
            await self.call('tome.stop',dict(session_id=self.connection['session_id'],control_token=self.connection['control_token']))

    async def observe(self):
        return await self.call('tome.observe',dict(session_id=self.connection['session_id']))

    async def pickup(self):
        for _ in range(30):
            s=await self.observe();p=s['player']
            candidates=s['ground']['items']
            if not candidates:raise AssertionError('No naturally dropped item is visible')
            under=[o for o in candidates if o['underfoot']]
            rod=next((o for o in under if o['name']=='Rod of Recall'),None)
            if rod:
                record,args,before=await self.act(dict(type='pickup',item_id=rod['id']))
                self.check(record['status']=='awaiting_input' and record['interaction']['native_ui']=='simplePopup',
                           'natural_rod_pickup_awaits_native_tutorial')
                committed=await self.observe()
                self.check(sum(o['count'] for o in committed['player']['inventory'] if o['name']=='Rod of Recall')==1,
                           'rod_is_already_owned_before_tutorial_close')
                await self.call('tome.stop',dict(session_id=self.connection['session_id'],control_token=self.connection['control_token']))
                await asyncio.sleep(.1)
                pending=await self.observe()
                self.check(pending['phase']=='needs_input' and not pending['pending_command']['execution_released'],
                           'pickup_manual_handoff_retains_execution_barrier')
                self.runtime.input.press('Escape');await asyncio.sleep(.2)
                self.connection=await self.call('tome.connect',dict(protocol_version=2))
                historical=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=record['command_id']))
                after=await self.observe()
                self.check(historical['status']=='needs_input' and historical['execution_released'] and after['phase']=='ready',
                           'manual_pickup_close_releases_original_command')
                duplicate=await self.call('tome.act',args)
                stable=await self.observe()
                self.check(duplicate['status']=='needs_input' and stable['player']==after['player'] and stable['world_tick']==after['world_tick']
                           and sum(o['count'] for o in stable['player']['inventory'] if o['name']=='Rod of Recall')==1,
                           'completed_pickup_handoff_dedup_cannot_grant_a_second_rod')
                return
            if under:
                action=dict(type='pickup',item_id=under[0]['id'])
            else:
                obj=min(candidates,key=lambda o:max(abs(o['x']-p['x']),abs(o['y']-p['y'])))
                direction=driver.Acceptance.route(self,s,obj['x'],obj['y']);assert direction
                action=dict(type='move',direction=direction)
            record,_,_=await self.act(action)
            while record['status']=='awaiting_input':
                assert record['interaction']['kind']=='dialog.notice',record
                record,_=await self.answer(record,dict(type='option',option_id=record['interaction']['options'][0]['option_id']))
            assert record['status']=='completed' and record['snapshot']['player']['life']>0,record
        raise AssertionError('Natural Rod pickup was not reached')

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('session');parser.add_argument('source_session',type=Path)
    parser.add_argument('--pickup-handoff',action='store_true');args=parser.parse_args()
    source=args.source_session.resolve();source_result=json.loads((source/'result.json').read_text())
    assert source_result['passed'] and source_result['normal_campaign'] and not source_result['gameplay_fixture'] and not source_result['cheat']
    source_save=source/campaign.SAVE_RELATIVE;source_hashes=campaign.hashes(source_save)
    runtime=campaign.CampaignRuntime(args.session,campaign.CONTINUATION_SESSION,
                                    WORKSPACE/'game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa')
    target=runtime.home/'.t-engine/4.0/tome/save'
    assert target.is_relative_to(runtime.session) and runtime.process is None
    shutil.rmtree(target);shutil.copytree(source_save,target)
    assert campaign.hashes(target)==source_hashes
    meta=json.loads((runtime.session/'input.json').read_text())
    meta.update(derived_ordinary_source=str(source),derived_source_result_sha256=campaign.native.sha(source/'result.json'),
                source_save_replaced_with_derived_copy=True,derived_source_save_sha256=source_hashes,
                recovery_driver_sha256=campaign.native.sha(Path(__file__)))
    (runtime.session/'input.json').write_text(json.dumps(meta,indent=2));shutil.copy2(__file__,runtime.session/'recovery-run.py')
    run=Acceptance(runtime);error=None
    try:runtime.start();asyncio.run(run.run(source_result,args.pickup_handoff))
    except Exception:error=traceback.format_exc();print(error,flush=True)
    finally:runtime.close()
    unchanged=source_hashes==campaign.hashes(source_save) and runtime.source_unchanged()
    logs=(runtime.session/'game.log').read_text(errors='replace')
    result=dict(passed=error is None and unchanged and 'Lua Error:' not in logs,error=error,checks=run.checks,
                final=getattr(run,'final',None),derived_source_unchanged=unchanged,normal_campaign=True,gameplay_fixture=False,cheat=False)
    (runtime.session/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    (runtime.session/'mcp.json').write_text(json.dumps(run.transcript,ensure_ascii=False,indent=2).replace(runtime.token,'<redacted>'))
    print(json.dumps(dict(passed=result['passed'],checks=len(run.checks),evidence=str(runtime.session))),flush=True)
    return 0 if result['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
