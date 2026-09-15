#!/usr/bin/env python3
"""Official MCP v2 -> production bridge -> isolated native interactive talents."""
from __future__ import annotations

import argparse
import hashlib
import asyncio
import json
import os
import shutil
from pathlib import Path
import sys
import time
import traceback

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'native'))
from runtime import Runtime,DEFAULT_SOURCE,DEFAULT_DEPS,WORKSPACE
from mcp import Client,StdioServerParameters


class Acceptance:
    def __init__(self,runtime,companions=False):
        self.runtime=runtime
        self.companions=companions
        self.checks=[]
        self.transcript=[]
        self.sequence=0
        self.client=None
        self.connection=None

    def check(self,condition,name,**details):
        row=dict(name=name,passed=bool(condition),**details)
        self.checks.append(row)
        print(json.dumps(dict(name=name,passed=bool(condition))),flush=True)
        assert condition,row

    async def raw(self,name,args=None):
        result=await self.client.call_tool(name,args or {})
        data=result.structured_content
        self.transcript.append(dict(tool=name,args=args,result=data,is_error=result.is_error))
        assert isinstance(data,dict),(name,result)
        return data

    async def call(self,name,args=None):
        data=await self.raw(name,args)
        assert data.get('ok'),(name,data)
        return data['result']

    async def observe(self):
        return await self.call('tome.observe',dict(session_id=self.connection['session_id'],include_map=False))

    async def act(self,action,command_id=None):
        self.sequence+=1
        snapshot=await self.observe()
        args=dict(session_id=self.connection['session_id'],control_token=self.connection['control_token'],
                  command_id=command_id or f'interactive-{self.sequence}',expected_revision=snapshot['revision'],
                  action=action,wait_ms=10000,include_map=False)
        result=await self.call('tome.act',args)
        return result,args,snapshot

    async def answer(self,record,answer,response_id=None):
        self.sequence+=1
        args=dict(session_id=self.connection['session_id'],control_token=self.connection['control_token'],
                  command_id=record['command_id'],interaction_id=record['interaction']['interaction_id'],
                  expected_revision=record['revision'],response_id=response_id or f'answer-{self.sequence}',
                  answer=answer,wait_ms=10000,include_map=False)
        for attempt in range(4):
            reply=await self.raw('tome.respond',args)
            if reply.get('ok'):
                return reply['result'],args
            if reply.get('error',{}).get('code')!='stale_revision':
                raise AssertionError(reply)
            # A known rejection has not consumed this response ID. Native UI
            # setup can have one pending tick; refresh, never replay uncertainty.
            fresh=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=record['command_id']))
            assert fresh['interaction']['interaction_id']==args['interaction_id']
            args['expected_revision']=fresh['revision']
        raise AssertionError(reply)

    async def run(self):
        params=StdioServerParameters(command=sys.executable,args=['-m','tome_mcp'],
            env={**os.environ,'PYTHONPATH':str(self.runtime.server_source),
                 'TOME_MCP_PORT':str(self.runtime.port),'TOME_MCP_TOKEN':self.runtime.token})
        async with Client(params) as client:
            self.client=client
            self.connection=await self.call('tome.connect',{})
            self.check(self.connection['protocol_version']==3,'protocol_negotiation')
            perception=[r for r in self.runtime.records() if r.get('kind')=='visibility_check']
            self.check(len(perception)==9 and all(r['passed'] for r in perception),
                       'native_world_and_dungeon_perception_regressions')
            initial=await self.observe()
            self.check(initial['phase']=='ready','native_initial_ready')
            if self.companions:
                self.check(initial['battle_companion']['state']=='idle' and initial['battle_companion']['actions']==0,
                           'companion_starts_idle_with_v2_native_compatibility')
            rush=await self.call('tome.inspect',dict(session_id=self.connection['session_id'],kind='talent',id='T_RUSH'))
            self.check(rush.get('activation',{}).get('admitted'),'rush_admitted_without_id_adapter',talent=rush)
            target=next(a for a in initial['actors'] if a['name']=='MCP target dummy')
            request,args,before=await self.act(dict(type='use_talent',talent_id='T_RUSH'))
            self.check(request['status']=='awaiting_input','rush_waits_for_real_native_target',record=request)
            self.check(request['interaction']['kind']=='target.grid','rush_uses_generic_grid_provider')
            same=await self.call('tome.act',args)
            self.check(same['interaction']['interaction_id']==request['interaction']['interaction_id'],
                       'duplicate_act_does_not_restart_suspended_talent')
            record,answer_args=await self.answer(same,dict(type='actor',target_id=target['id']))
            self.check(record['status']=='completed','rush_completes_after_native_continuation',record=record)
            self.check(record['execution_released'],'rush_releases_invocation_at_decision_boundary')
            after=record['snapshot']
            self.check((after['player']['x'],after['player']['y'])==(5,3),'rush_native_landing')
            self.check(record['energy_spent']>0 and after['world_tick']>before['world_tick'],
                       'rush_native_energy_and_world_settlement')
            duplicate=await self.call('tome.respond',answer_args)
            stable=await self.observe()
            self.check(duplicate['status']=='completed' and stable['player']==after['player']
                       and stable['world_tick']==after['world_tick'],'duplicate_answer_does_not_recast_or_move')

            request,_,before=await self.act(dict(type='use_talent',talent_id='T_PHASE_DOOR'))
            self.check(request['status']=='awaiting_input','phase_door_first_question')
            first=request['interaction']['interaction_id']
            second,_=await self.answer(request,dict(type='actor',target_id=before['player']['id']))
            self.check(second['status']=='awaiting_input' and second['interaction']['interaction_id']!=first
                       and second['command_id']==request['command_id'],'phase_door_second_question_same_invocation',record=second)
            self.check(second['interaction']['sequence']==2,'phase_door_monotonic_interaction_sequence')
            done,_=await self.answer(second,dict(type='position',x=10,y=8))
            self.check(done['status']=='completed' and done['execution_released'],
                       'phase_door_completes_after_second_answer',record=done)
            self.check(done['snapshot']['player']['resources']['mana']['value']<before['player']['resources']['mana']['value'],
                       'phase_door_native_resource_cost')

            on,_,_=await self.act(dict(type='set_sustain',talent_id='T_PRECISE_STRIKES',enabled=True))
            self.check(on['status']=='completed','sustain_native_enable',record=on)
            same,_,_=await self.act(dict(type='set_sustain',talent_id='T_PRECISE_STRIKES',enabled=True))
            self.check(same['status']=='completed' and same['code']=='already_in_desired_state'
                       and same['energy_spent']==0,'sustain_desired_state_prevents_double_toggle')
            off,_,_=await self.act(dict(type='set_sustain',talent_id='T_PRECISE_STRIKES',enabled=False))
            self.check(off['status']=='completed','sustain_native_disable',record=off)

            snapshot=await self.observe()
            inventory={o['name']:o for o in snapshot['player']['inventory']}
            device=inventory['MCP native charged device']
            request,_,_=await self.act(dict(type='use_item',item_id=device['id']))
            self.check(request['status']=='awaiting_input' and request['interaction']['kind']=='target.grid',
                       'native_item_body_waits_for_target')
            cancelled,_=await self.answer(request,dict(type='cancel'))
            detail=await self.call('tome.inspect',dict(session_id=self.connection['session_id'],kind='item',id=device['id']))
            self.check(cancelled['status']=='failed' and cancelled['native_return']==False and cancelled['energy_spent']==0
                       and detail['activation']['power']==20,'native_item_cancel_preserves_charges_and_energy')
            request,action_args,_=await self.act(dict(type='use_item',item_id=device['id']))
            second,_=await self.answer(request,dict(type='position',x=10,y=8))
            self.check(second['status']=='awaiting_input' and second['interaction']['sequence']==2,
                       'native_item_second_question_same_command')
            done,response_args=await self.answer(second,dict(type='position',x=10,y=8))
            detail=await self.call('tome.inspect',dict(session_id=self.connection['session_id'],kind='item',id=device['id']))
            self.check(done['status']=='completed' and done['native_return'] and done['energy_spent']==1000
                       and detail['activation']['power']==13,'native_item_spends_charges_and_energy_once')
            await self.call('tome.act',action_args);await self.call('tome.respond',response_args)
            again=await self.call('tome.inspect',dict(session_id=self.connection['session_id'],kind='item',id=device['id']))
            self.check(again==detail,'native_item_duplicate_action_and_response_are_inert')
            unused=inventory['MCP native wearable device']
            refused,_,_=await self.act(dict(type='use_item',item_id=unused['id']))
            self.check(refused['status']=='failed' and refused['energy_spent']==0
                       and not any(r.get('event')=='unworn_device_called' for r in self.runtime.records()),
                       'native_item_wear_requirement_prevents_callback')
            consumed,_,_=await self.act(dict(type='use_item',item_id=inventory['MCP native consumable']['id']))
            self.check(consumed['status']=='completed' and consumed['energy_spent']==1000
                       and not any(o['name']=='MCP native consumable' for o in (await self.observe())['player']['inventory']),
                       'native_consumable_cleanup_removes_item_once')
            talent_item=inventory['MCP native talent device']
            request,_,_=await self.act(dict(type='use_item',item_id=talent_item['id']))
            second,_=await self.answer(request,dict(type='actor',target_id=snapshot['player']['id']))
            done,_=await self.answer(second,dict(type='position',x=10,y=8))
            detail=await self.call('tome.inspect',dict(session_id=self.connection['session_id'],kind='item',id=talent_item['id']))
            self.check(done['status']=='completed' and detail['activation']['power']==10,
                       'native_use_talent_item_restores_talent_and_spends_power')

            request,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_NOTICE_STACK'))
            native_uis=[];previous_sequence=0
            while request['status']=='awaiting_input':
                prompt=request['interaction'];native_uis.append(prompt['native_ui'])
                self.check(prompt['kind']=='dialog.notice' and prompt['sequence']>previous_sequence
                           and not request['execution_released'],'stacked_native_notice_retains_invocation')
                previous_sequence=prompt['sequence']
                before=await self.observe();await asyncio.sleep(.15);stable=await self.observe()
                self.check(stable['world_tick']==before['world_tick'],'spent_turn_does_not_advance_while_notice_open')
                request,_=await self.answer(request,dict(type='option',option_id=prompt['options'][0]['option_id']))
            self.check(native_uis==['QuestPopup','simpleLongPopup','simplePopup'] and request['status']=='completed'
                       and request['energy_spent']==1000,'native_deferred_quest_and_notices_close_in_stack_order')
            self.check(sum(r.get('event')=='notice_first_closed' for r in self.runtime.records())==1,
                       'native_notice_callback_runs_once')
            request,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_LORE_LIBRARY'))
            self.check(request['interaction']['native_ui']=='ShowLore','native_known_lore_library_close_provider')
            done,_=await self.answer(request,dict(type='option',option_id=request['interaction']['options'][0]['option_id']))
            self.check(done['status']=='completed' and done['execution_released'],'native_known_lore_library_closes')


            request,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_CONFIRM'))
            options=request['interaction']['options']
            self.check(request['interaction']['kind']=='dialog.confirm' and [o['label'] for o in options]==['Abort','Proceed'],
                       'native_confirm_custom_labels',record=request)
            done,_=await self.answer(request,dict(type='option',option_id=options[1]['option_id']))
            self.check(done['status']=='completed' and done['native_return'], 'confirm_uses_actual_false_button_callback')
            request,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_LIST'))
            prompt=request['interaction'];options=prompt['options']
            self.check(prompt['options_total']==40 and len(options)==32 and options[0]['label']==options[1]['label']
                       and options[0]['option_id']!=options[1]['option_id'],'list_duplicate_labels_have_distinct_ids')
            page=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=request['command_id'],options_offset=32))
            self.check(len(page['interaction']['options'])==8 and page['revision']==request['revision'],'list_paging_is_read_only')
            done,_=await self.answer(page,dict(type='option',option_id=page['interaction']['options'][4]['option_id']))
            self.check(done['status']=='completed' and any(r.get('event')=='list' and r.get('value')==37 for r in self.runtime.records()),
                       'paged_list_invokes_actual_native_accept')
            for talent in ('INVENTORY','EQUIPMENT_CHOICE'):
                request,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_'+talent))
                self.check(request['status']=='awaiting_input' and request['interaction']['kind']=='inventory.select',
                           'native_'+talent.lower()+'_provider',record=request)
                choice=next(o for o in request['interaction']['options'] if not o['disabled'])
                done,_=await self.answer(request,dict(type='option',option_id=choice['option_id']))
                self.check(done['status']=='completed' and done['execution_released'],'native_'+talent.lower()+'_callback')
            for talent in ('PRESPENT','POST_DIALOG'):
                request,_,before=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_'+talent))
                self.check(request['status']=='awaiting_input' and request['energy_spent']>0,
                           talent.lower()+'_holds_entire_native_body',record=request)
                frozen=await self.observe();await asyncio.sleep(.5);still=await self.observe()
                self.check(frozen['world_tick']==still['world_tick'] and frozen['player']==still['player'],
                           talent.lower()+'_world_frozen_while_answer_pending')
                done,_=await self.answer(request,dict(type='position',x=still['player']['x'],y=still['player']['y']))
                self.check(done['status']=='completed' and done['energy_spent_complete'],talent.lower()+'_native_settlement')
            request,_,before=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_NESTED'))
            self.check(request['status']=='awaiting_input' and not request['execution_released'],'parent_waits_for_nested_native_child')
            done,_=await self.answer(request,dict(type='cancel'))
            self.check(done['status']=='completed' and done['snapshot']['player']['resources']['mana']['value']
                       <before['player']['resources']['mana']['value'],'cancel_can_continue_with_native_partial_effect')


            request,_,before=await self.act(dict(type='use_talent',talent_id='T_LIGHTNING'))
            warning,_=await self.answer(request,dict(type='actor',target_id=before['player']['id']))
            self.check(warning['status']=='awaiting_input' and warning['interaction']['kind']=='dialog.confirm',
                       'native_self_target_warning_belongs_to_same_invocation',record=warning)
            abort=next(o for o in warning['interaction']['options'] if o['label']=='No')
            done,_=await self.answer(warning,dict(type='option',option_id=abort['option_id']))
            self.check(done['status']=='failed' and done['native_return']==False and done['execution_released']
                       and done['snapshot']['player']['life']==before['player']['life'], 'native_self_target_warning_no_cancels_without_damage')

            request,_,before=await self.act(dict(type='use_talent',talent_id='T_CATAPULT_TRAP'))
            placement=(before['player']['x'],before['player']['y']+1)
            aim,_=await self.answer(request,dict(type='position',x=placement[0],y=placement[1]))
            self.check(aim['status']=='awaiting_input' and aim['interaction']['sequence']==2
                       and (aim['interaction']['origin']['x'],aim['interaction']['origin']['y'])==placement,
                       'catapult_trap_actual_second_prompt_uses_trap_origin',record=aim)
            target_record=next(r for r in reversed(self.runtime.records()) if r.get('event')=='target_metadata')
            self.check(any((t['x'],t['y'])==placement for t in target_record['value']['traps'].values()),
                       'native_trap_exists_before_direction_answer')
            done,_=await self.answer(aim,dict(type='cancel'))
            release=next(r for r in reversed(self.runtime.records()) if r.get('kind')=='interactive_release')
            self.check(done['status']=='completed' and any((t['x'],t['y'])==placement
                       and (t['target_x'],t['target_y'])==placement for t in release['traps'].values()),
                       'cancelling_trap_aim_preserves_placed_trap_and_native_default')

            # Native local input revokes the socket. Explicit reconnect is part
            # of the tested client recovery, and is never implicit retry.
            self.runtime.input.press('F11');await asyncio.sleep(.25)
            self.connection=await self.call('tome.connect',{})
            request,_,before=await self.act(dict(type='use_talent',talent_id='T_FEARLESS_CLEAVE'))
            self.check(request['status']=='awaiting_input' and request['interaction']['kind']=='target.direction',
                       'fearless_cleave_native_direction_request',record=request)
            done,_=await self.answer(request,dict(type='direction',direction=6))
            self.check(done['status']=='completed' and done['snapshot']['player']['x']==before['player']['x']+1,
                       'fearless_cleave_native_direction_and_movement')

            request,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_CANCEL'))
            self.connection=await self.call('tome.connect',{})
            recovered=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=request['command_id']))
            self.check(recovered['input_owner']=='remote' and recovered['interaction']['interaction_id']==request['interaction']['interaction_id'],
                       'explicit_reconnect_reclaims_native_orphan')
            done,_=await self.answer(recovered,dict(type='cancel'))
            self.check(done['status']=='completed','reclaimed_native_prompt_continues_once')

            request,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_UNSUPPORTED'))
            self.check(request['status']=='needs_input' and not request['execution_released'],'unknown_native_dialog_hands_off_with_barrier')
            self.runtime.input.press('Escape');await asyncio.sleep(.3)
            self.connection=await self.call('tome.connect',{})
            resolved=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=request['command_id']))
            self.check(resolved['status']=='needs_input' and resolved['execution_released'],'native_manual_dialog_completion_releases_barrier')

            request,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_CANCEL'))
            await self.call('tome.stop',dict(session_id=self.connection['session_id'],control_token=self.connection['control_token']))
            await asyncio.sleep(.2)
            stopped=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=request['command_id']))
            self.check(stopped['status']=='needs_input' and stopped['input_owner']=='manual'
                       and stopped['interaction'] and not stopped['execution_released'],'stop_hands_off_without_answering_cancel')
            if self.companions:
                self.runtime.input.press('F10');await asyncio.sleep(.2)
                attempt=next(r for r in reversed(self.runtime.records()) if r.get('event')=='companion_attempt')
                self.check(attempt['value']['started']==False and attempt['value']['code']=='remote_control',
                           'native_companion_cannot_start_during_manual_execution_barrier')
            self.runtime.input.press('Escape');await asyncio.sleep(.3)
            self.connection=await self.call('tome.connect',{})
            resolved=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=request['command_id']))
            self.check(resolved['status']=='needs_input' and resolved['execution_released'],'native_manual_target_completion_releases_barrier')

            def hashes():
                return {str(p.relative_to(self.runtime.home)):hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in (self.runtime.home/'.t-engine/4.0/tome/save').rglob('*.teag')}
            request,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_CANCEL'))
            old_hashes=hashes()
            self.runtime.input.press('F9');await asyncio.sleep(.5)
            self.check(hashes()==old_hashes,'save_during_native_yield_is_deferred')
            self.runtime.input.press('Escape');await asyncio.sleep(.5)
            deadline=time.monotonic()+30
            while hashes()==old_hashes:
                assert time.monotonic()<deadline,'Deferred save was never written'
                await asyncio.sleep(.1)
            self.connection=await self.call('tome.connect',{})
            deadline=time.monotonic()+30
            while (await self.observe())['phase']!='ready':
                assert time.monotonic()<deadline,'Deferred background save never settled'
                await asyncio.sleep(.1)
            self.check(bool(hashes()),'deferred_save_written_after_native_manual_completion')
            old_session=self.connection['session_id']
            self.runtime.restart_from_saved_copy()
            deadline=time.monotonic()+90
            while not any(r.get('kind')=='reload_ready' for r in self.runtime.records()):
                assert time.monotonic()<deadline,'Reload did not finish'
                assert self.runtime.process.poll() is None,'Native load exited'
                await asyncio.sleep(.1)
            self.connection=await self.call('tome.connect',{})
            loaded=await self.observe()
            self.check(self.connection['session_id']!=old_session and loaded['phase']=='ready'
                       and not loaded.get('pending_command'),'saved_copy_load_drops_invocation_coroutines_and_old_session')
            request,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_CONFIRM'))
            done,_=await self.answer(request,dict(type='option',option_id=request['interaction']['options'][1]['option_id']))
            self.check(done['status']=='completed','native_interactions_work_after_saved_copy_reload')

            self.runtime.input.press('F12');await asyncio.sleep(.5)
            self.check(any(r.get('event')=='rest_fixture_ready' for r in self.runtime.records()),'native_golem_rest_fixture_ready')
            self.connection=await self.call('tome.connect',{})
            done,_,before=await self.act(dict(type='use_talent',talent_id='T_REFIT_GOLEM'))
            if done['status']=='running_native_task':
                deadline=time.monotonic()+30
                while done['status']=='running_native_task':
                    assert time.monotonic()<deadline,'Refit never settled'
                    await asyncio.sleep(.1)
                    done=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=done['command_id']))
            self.check(done['status']=='completed' and done['execution_released'] and done.get('native_task',{}).get('status')=='ended',
                       'refit_golem_waits_for_actual_native_rest_completion',record=done)
            self.check(done['native_task']['turns_executed']==21 and done['energy_spent']>20000 and done['energy_spent_complete'],
                       'refit_golem_counts_rest_and_talent_energy')
            after=done['snapshot']
            self.check(any(a.get('type')=='construct' and a['life']>0 for a in after['actors']), 'refit_golem_native_resurrection')
            gems=lambda snap:sum(o['count'] for o in snap['player']['equipment'] if o.get('container')=='QUIVER')
            self.check(gems(before)-gems(after)==15,'refit_golem_consumes_native_fifteen_gems')

            self.runtime.input.press('F10');await asyncio.sleep(.3)
            self.connection=await self.call('tome.connect',{})
            interrupted,_,before=await self.act(dict(type='use_talent',talent_id='T_REFIT_GOLEM'))
            self.check(interrupted['status']=='failed' and interrupted['execution_released']
                       and interrupted['native_task']['status']=='ended' and interrupted['native_task']['turns_executed']<21
                       and any(r.get('event')=='refit_enemy_spawned' for r in self.runtime.records()),
                       'real_refit_golem_native_hostile_interrupts_wait',record=interrupted)
            self.check(gems(before)==gems(interrupted['snapshot'])
                       and not any(a.get('type')=='construct' and a['life']>0 for a in interrupted['snapshot']['actors']),
                       'interrupted_refit_neither_resurrects_nor_consumes_gems')
            self.runtime.input.press('F12');await asyncio.sleep(.3)
            self.connection=await self.call('tome.connect',{})

            # A long native wait allows both explicit interruption and the
            # production automation turn cap to be exercised deterministically.
            snap=await self.observe();self.sequence+=1;task_id=f'long-task-{self.sequence}'
            task=await self.call('tome.act',dict(session_id=self.connection['session_id'],control_token=self.connection['control_token'],
                command_id=task_id,expected_revision=snap['revision'],action=dict(type='use_talent',talent_id='T_MCP_TEST_TASK'),wait_ms=0))
            deadline=time.monotonic()+30
            while task['status'] in ('queued','settling','executing'):
                assert time.monotonic()<deadline
                task=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=task_id))
                await asyncio.sleep(.01)
            self.check(task['status']=='running_native_task','native_task_reports_running_before_completion',record=task)
            await self.call('tome.stop',dict(session_id=self.connection['session_id'],control_token=self.connection['control_token']))
            deadline=time.monotonic()+30
            while True:
                task=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=task_id))
                if task['execution_released']: break
                assert time.monotonic()<deadline,'Stopped task retained execution forever'
                await asyncio.sleep(.05)
            self.check(task['status']=='failed' and task['native_task']['status']=='ended'
                       and task['native_task']['turns_executed']<1000,'stop_uses_native_rest_cleanup_and_continuation',record=task)
            self.connection=await self.call('tome.connect',{})
            task,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_TASK'))
            deadline=time.monotonic()+45
            while task['status'] in ('queued','settling','executing','running_native_task'):
                assert time.monotonic()<deadline,'Task budget did not finish'
                await asyncio.sleep(.1)
                task=await self.call('tome.status',dict(session_id=self.connection['session_id'],command_id=task['command_id']))
            self.check(task['status']=='failed' and task['execution_released']
                       and task['native_task']['turns_executed']==1000
                       and task['native_task']['stop_reason']=='task_budget_exhausted','native_task_turn_budget_uses_native_stop',record=task)


            request,_,_=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_TASK_PROMPT'))
            self.check(request['status']=='awaiting_input' and request['native_task']['status']=='ended'
                       and not request['execution_released'],'native_task_end_callback_can_open_next_prompt',record=request)
            done,_=await self.answer(request,dict(type='position',x=request['interaction']['origin']['x'],y=request['interaction']['origin']['y']))
            self.check(done['status']=='completed' and done['execution_released'] and done['energy_spent']>4000,
                       'native_task_and_followup_input_both_finish_before_release')

            for talent in ('T_WEAPON_COMBAT','T_DOES_NOT_EXIST'):
                done,_,before=await self.act(dict(type='use_talent',talent_id=talent))
                self.check(done['status']=='failed' and done['execution_released'] and done['energy_spent']==0,
                           'generic_admission_rejects_'+talent.lower())
            done,_,before=await self.act(dict(type='use_talent',talent_id='T_ADRENALINE_SURGE'))
            self.check(done['status']=='completed' and done['energy_spent']==0
                       and done['snapshot']['world_tick']==before['world_tick'],'generic_instant_talent_has_no_fabricated_input_or_turn')
            done,_,before=await self.act(dict(type='use_talent',talent_id='T_HEAL'))
            self.check(done['status']=='completed' and done['energy_spent']>0,'generic_no_input_native_talent_settles')
            done,_,_=await self.act(dict(type='use_talent',talent_id='T_HEAL'))
            self.check(done['status']=='failed' and done['native_return']==False and done['energy_spent']==0,
                       'generic_native_cooldown_rejection_before_body')
            snap=await self.observe()
            healing=next(t['id'] for t in snap['talents'] if t['id'].startswith('T_INFUSION:_HEALING_'))
            done,_,_=await self.act(dict(type='use_talent',talent_id=healing))
            self.check(done['status']=='completed','generic_dynamic_inscription_id_is_admitted')

            request,_,before=await self.act(dict(type='use_talent',talent_id='T_MCP_TEST_ERROR'))
            done,answer_args=await self.answer(request,dict(type='position',x=before['player']['x'],y=before['player']['y']))
            self.check(done['status']=='failed' and done['uncertain'] and not done['execution_released']
                       and 'mcp-expected-after-resume-error' in done['native_message'],
                       'native_post_resume_error_is_uncertain_and_quarantined',record=done)
            snap=await self.observe()
            self.check(snap['phase']=='unavailable' and snap['player']['resources']['mana']['value']
                       ==before['player']['resources']['mana']['value']-5,'native_error_preserves_actual_partial_resource_change')
            self.connection=await self.call('tome.connect',{})
            duplicate=await self.call('tome.respond',answer_args)
            self.check(duplicate['response_receipt']['state']=='applied'
                       and (await self.observe())['player']['resources']['mana']==snap['player']['resources']['mana'],
                       'uncertain_native_response_can_be_recovered_without_reexecution')
            self.check(all(r.get('passed') for r in self.runtime.records() if r.get('kind')=='observation_check'),
                       'native_observation_and_interaction_reads_have_no_rng_or_game_callbacks')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('session')
    parser.add_argument('--addon-archive',type=Path)
    parser.add_argument('--companions',action='store_true',help='also load released Battle Companion and Danger Alert packages')
    args=parser.parse_args()
    extra=None
    if args.companions:
        extra={'battle-companion':WORKSPACE/'game/addons/tome-battle-companion/dist/tome-battle-companion.teaa',
               'danger-alert':WORKSPACE/'game/addons/tome-battle-companion/dist/tome-danger-alert.teaa'}
    runtime=Runtime(args.session,DEFAULT_SOURCE,DEFAULT_DEPS,addon_archive=args.addon_archive,interaction_probe=True,extra_addons=extra)
    runtime.server_source=runtime.session/'mcp-server-src'
    shutil.copytree(Path(__file__).resolve().parents[2]/'server/src',runtime.server_source,
                    ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
    metadata=json.loads((runtime.session/'input.json').read_text())
    metadata['mcp_server_py_sha256']={str(p.relative_to(runtime.server_source)):hashlib.sha256(p.read_bytes()).hexdigest()
                                     for p in runtime.server_source.rglob('*.py')}
    metadata['driver_sha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    (runtime.session/'input.json').write_text(json.dumps(metadata,indent=2))
    shutil.copy2(__file__,runtime.session/'interaction-run.py')
    acceptance=Acceptance(runtime,args.companions)
    error=None
    start=time.monotonic()
    try:
        runtime.start();runtime.wait_ready()
        asyncio.run(acceptance.run())
    except Exception:
        error=traceback.format_exc();print(error,flush=True)
    finally:
        runtime.close()
    logs='\n'.join(path.read_text(errors='replace') for path in runtime.log_paths)
    result=dict(passed=error is None and 'Lua Error:' not in logs,error=error,checks=acceptance.checks,
                elapsed_seconds=time.monotonic()-start,native_records=runtime.records())
    (runtime.session/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    (runtime.session/'mcp.json').write_text(json.dumps(acceptance.transcript,ensure_ascii=False,indent=2)
                                         .replace(runtime.token,'<redacted>'))
    print(json.dumps(dict(passed=result['passed'],checks=len(acceptance.checks),evidence=str(runtime.session))))
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
