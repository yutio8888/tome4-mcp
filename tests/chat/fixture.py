#!/usr/bin/env python3
"""Native Chat provider, page identity, ownership and exactly-once acceptance."""
from pathlib import Path
import importlib.util
import asyncio
import hashlib
import json
import os
import shutil
import sys
import time
import traceback
import argparse
from mcp import Client,StdioServerParameters
spec=importlib.util.spec_from_file_location('interactive',Path(__file__).resolve().parents[1]/'interactions/run.py')
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)

class Acceptance(base.Acceptance):
    def events(self,event):return [r for r in self.runtime.records() if r.get('event')==event]

    async def settle(self,r):
        for _ in range(200):
            if r['status'] not in ('queued','executing','settling'):return r
            await asyncio.sleep(.05)
            r=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=r['command_id']))
        raise AssertionError(r)

    async def conversation(self,npc=False):
        if npc:
            armed,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_ARM_CHAT'))
            self.check(armed['status']=='completed','npc_chat_armed_without_time')
            r,args,before=await self.act(dict(type='move',direction=2))
        else:r,args,before=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_CHAT'))
        r=await self.settle(r)
        if npc:
            self.check(r['status']=='awaiting_input' and r['interaction']['native_ui']=='QuestPopup',
                       'npc_settlement_owns_deferred_notice',record=r)
            r,_=await self.answer(r,dict(type='option',option_id=r['interaction']['options'][0]['option_id']))
        self.check(r['status']=='awaiting_input' and r['interaction']['native_ui']=='Chat'
                   and r['interaction']['kind']=='dialog.choice','native_chat_owned',record=r)
        first=r['interaction'];frozen=await self.observe();condition_count=len(self.events('chat_cond'))
        self.check(first['options_total']==40 and len(first['options'])==32
                   and 'cancel' not in first['answer_types'] and all('Hidden' not in o['label'] for o in first['options']),
                   'only_visible_native_choices_no_synthetic_cancel')
        self.check(first['options'][0]['label']==first['options'][1]['label']=='Same label'
                   and first['options'][0]['option_id']!=first['options'][1]['option_id'],'chat_duplicate_labels_have_distinct_native_options')
        page=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=r['command_id'],options_offset=32))
        await asyncio.sleep(.2);stable=await self.observe()
        self.check(len(page['interaction']['options'])==8 and page['revision']==r['revision']
                   and len(self.events('chat_cond'))==condition_count and frozen['player']==stable['player']
                   and frozen['world_tick']==stable['world_tick'],'chat_paging_does_not_evaluate_conditions_or_advance_world')
        bad=dict(session_id=self.connection['session_id'],control_token=self.connection['control_token'],
                 command_id=r['command_id'],interaction_id=first['interaction_id'],expected_revision=page['revision'],
                 response_id=f'invalid-{self.sequence}',answer=dict(type='cancel'))
        refused=await self.raw('tome.respond',bad)
        self.check(not refused['ok'],'chat_cancel_without_native_choice_is_rejected')
        self.connection=await self.call('tome.connect',{})
        recovered=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=r['command_id'],options_offset=32))
        self.check(recovered['input_owner']=='remote' and recovered['interaction']['interaction_id']==first['interaction_id'],
                   'reconnect_preserves_chat_page_and_command')
        reward,response=await self.answer(recovered,dict(type='option',option_id=recovered['interaction']['options'][4]['option_id']))
        reward=await self.settle(reward)
        self.check(reward['status']=='awaiting_input' and reward['interaction']['native_ui']=='Chat'
                   and reward['interaction']['sequence']>first['sequence'] and 'reward' in reward['interaction']['text'],
                   'paged_native_choice_follows_automatic_page_to_reward',record=reward)
        self.check(self.events('chat_choice')[-1]['value']==37,'native_choice_37_called_once')
        await self.call('tome.respond',response)
        self.check(len(self.events('chat_choice'))==(2 if npc else 1),'duplicate_choice_does_not_replay_native_callback')
        n=len(self.events('chat_reward'));reward_before=await self.observe()
        notice,reward_args=await self.answer(reward,dict(type='option',option_id=reward['interaction']['options'][0]['option_id']))
        self.check(notice['status']=='awaiting_input' and notice['interaction']['native_ui']=='simplePopup',
                   'reward_native_notice_above_farewell')
        self.check((await self.observe())['player']['stats']['wil']['bonus']==reward_before['player']['stats']['wil']['bonus']+2
                   and len(self.events('chat_reward'))==n+1,'reward_applied_once_before_farewell')
        farewell,_=await self.answer(notice,dict(type='option',option_id=notice['interaction']['options'][0]['option_id']))
        self.check(farewell['status']=='awaiting_input' and farewell['interaction']['native_ui']=='Chat'
                   and farewell['interaction']['sequence']>notice['interaction']['sequence'],'farewell_exposes_fresh_page_identity')
        await self.call('tome.respond',reward_args)
        self.check(len(self.events('chat_reward'))==n+1,'duplicate_reward_reply_cannot_award_twice')
        done,last_args=await self.answer(farewell,dict(type='option',option_id=farewell['interaction']['options'][0]['option_id']))
        done=await self.settle(done)
        self.check(done['status']=='completed' and done['execution_released'],'farewell_finishes_original_invocation')
        snapshot=await self.observe()
        args['control_token']=self.connection['control_token']
        await self.call('tome.act',args);await self.call('tome.respond',last_args)
        stable=await self.observe()
        self.check(snapshot['player']==stable['player'] and snapshot['world_tick']==stable['world_tick']
                   and len(self.events('chat_reward'))==n+1,'completed_duplicate_chat_move_and_reward_are_inert')
        if npc:self.check(snapshot['player']['x']==before['player']['x'] and snapshot['player']['y']==before['player']['y']+1
                           and done['energy_spent']==1000,'npc_chat_does_not_replay_already_spent_move')

    async def run(self):
        params=StdioServerParameters(command=sys.executable,args=['-m','tome_mcp'],env={**os.environ,
            'PYTHONPATH':str(self.runtime.server_source),'TOME_MCP_PORT':str(self.runtime.port),'TOME_MCP_TOKEN':self.runtime.token})
        async with Client(params) as client:
            self.client=client;self.connection=await self.call('tome.connect',{})
            await self.conversation();await self.conversation(npc=True)
            r,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_CHAT'))
            await self.call('tome.stop',dict(session_id=self.connection['session_id'],control_token=self.connection['control_token']))
            stopped=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=r['command_id']))
            self.check(stopped['input_owner']=='manual' and not stopped['execution_released'] and stopped['interaction'],
                       'stop_preserves_actual_native_chat_for_manual_input')
            # Complete welcome, reward, notice and farewell using actual local keys.
            for key in ('a','a','Escape','a'):
                self.runtime.input.press(key);await asyncio.sleep(.4)
            self.connection=await self.call('tome.connect',{})
            done=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=r['command_id']))
            self.check(done['execution_released'] and len(self.events('chat_reward'))==3,'manual_chat_pages_release_barrier_and_reward_once')
            reward,action_args,before=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_ESCORT_REWARD'))
            self.check(reward['status']=='awaiting_input' and reward['interaction']['native_ui']=='Chat',
                       'actual_native_escort_reward_script_is_supported')
            will=next(o for o in reward['interaction']['options'] if 'Willpower' in o['label'] and '+5' in o['label'])
            farewell,reward_args=await self.answer(reward,dict(type='option',option_id=will['option_id']))
            self.check(farewell['status']=='awaiting_input' and farewell['interaction']['native_ui']=='Chat'
                       and 'Farewell' in farewell['interaction']['text'],'actual_native_escort_reward_regenerates_farewell')
            current=await self.observe()
            self.check(current['player']['stats']['wil']['bonus']==before['player']['stats']['wil']['bonus']+5,
                       'actual_native_escort_stat_reward_applies_plus_five')
            await self.call('tome.respond',reward_args);await self.call('tome.act',action_args)
            stable=await self.observe()
            self.check(stable['player']==current['player'] and len(self.events('native_escort_open'))==1,
                       'actual_native_escort_duplicate_reward_and_action_are_inert')
            done,_=await self.answer(farewell,dict(type='option',option_id=farewell['interaction']['options'][0]['option_id']))
            self.check(done['status']=='completed' and done['execution_released']
                       and (await self.observe())['player']['stats']['wil']['bonus']==current['player']['stats']['wil']['bonus'],
                       'actual_native_escort_thank_you_finishes_original_command')
            purity=[r for r in self.runtime.records() if r.get('kind')=='observation_check']
            self.check(bool(purity) and all(r['passed'] for r in purity),'chat_read_only_observation_and_status_callback_purity')

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('session');parser.add_argument('--addon-archive',type=Path);args=parser.parse_args()
    runtime=base.Runtime(args.session,base.DEFAULT_SOURCE,base.DEFAULT_DEPS,addon_archive=args.addon_archive,interaction_probe=True,
        extra_addons={'battle-companion':base.WORKSPACE/'game/addons/tome-battle-companion/dist/tome-battle-companion.teaa',
                      'danger-alert':base.WORKSPACE/'game/addons/tome-battle-companion/dist/tome-danger-alert.teaa'})
    runtime.server_source=runtime.session/'mcp-server-src';shutil.copytree(base.WORKSPACE/'tools/tome-mcp-server/src',runtime.server_source,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
    shutil.copy2(__file__,runtime.session/'chat-fixture.py')
    metadata=json.loads((runtime.session/'input.json').read_text());metadata['mcp_server_py_sha256']={str(p.relative_to(runtime.server_source)):hashlib.sha256(p.read_bytes()).hexdigest() for p in runtime.server_source.rglob('*.py')};metadata['driver_sha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    (runtime.session/'input.json').write_text(json.dumps(metadata,indent=2))
    run=Acceptance(runtime,True);error=None
    try:runtime.start();runtime.wait_ready();asyncio.run(run.run())
    except Exception:error=traceback.format_exc();print(error,flush=True)
    finally:runtime.close()
    logs='\n'.join(p.read_text(errors='replace') for p in runtime.log_paths)
    result=dict(passed=error is None and 'Lua Error:' not in logs,error=error,checks=run.checks)
    (runtime.session/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    (runtime.session/'mcp.json').write_text(json.dumps(run.transcript,ensure_ascii=False,indent=2).replace(runtime.token,'<redacted>'))
    print(json.dumps(dict(passed=result['passed'],checks=len(run.checks),session=str(runtime.session))),flush=True)
    return 0 if result['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
