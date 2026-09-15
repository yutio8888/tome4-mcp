-- Test-only fixtures and diagnostics. Remote answers still use production MCP.
local M={calls=0}
local test_ids={}
local function emit(kind,value)
    require('mod.MCPProbe').emit{kind='interaction_fixture',event=kind,value=value}
end
function M.define()
    local Talents=require 'engine.interface.ActorTalents'
    local Dialog=require 'engine.ui.Dialog'
    local function talent(name,action,extra)
        local definition={name='MCP Test '..name,short_name='MCP_TEST_'..name:upper(),
            type={'spell/other',1},points=1,mode='activated',no_energy=true,action=action,
            info=function() return 'Native acceptance fixture only.' end}
        for k,v in pairs(extra or {}) do definition[k]=v end
        Talents:newTalent(definition)
        test_ids[#test_ids+1]=definition.id
    end
    talent('confirm',function(self)
        local co=coroutine.running()
        Dialog:yesnoPopup('Native confirmation','Buttons intentionally use custom meanings.',
            function(value) assert(coroutine.resume(co,value)) end,'Abort','Proceed')
        local value=coroutine.yield()
        emit('confirm',value)
        return value==false
    end)
    talent('list',function(self)
        local list={}
        for i=1,40 do list[i]={name=i<=2 and 'Same label' or 'Native option '..i,value=i} end
        local value=self:talentDialog(Dialog:listPopup('Native choices','Choose one of forty entries.',list,400,400,
            function(item) self:talentDialogReturn(item and item.value) end))
        emit('list',value)
        return value~=nil
    end)
    talent('inventory',function(self)
        require('engine.ui.Inventory')._last_tabs={all=true}
        local value=self:talentDialog(self:showInventory('Native inventory selection',self:getInven('INVEN'),nil,
            function(object) self:talentDialogReturn(object and object.name);return nil end))
        emit('inventory',value)
        return value~=nil
    end)
    talent('equipment_choice',function(self)
        require('engine.ui.Inventory')._last_tabs={all=true}
        local value=self:talentDialog(self:showEquipInven('Native equipment selection',nil,
            function(object) self:talentDialogReturn(object and object.name);return true end))
        emit('equipment_choice',value)
        return value~=nil
    end)
    talent('cancel',function(self)
        local x=self:getTarget{type='hit',range=20,nolock=true,nowarning=true}
        if not x then self:incMana(-1) end
        emit('cancel',x~=nil)
        return true
    end)
    talent('prespent',function(self)
        self:useEnergy()
        emit('prespent_before',game.turn)
        local x=self:getTarget{type='hit',range=20,nolock=true,nowarning=true}
        emit('prespent_after',game.turn)
        return x~=nil
    end)
    talent('post_dialog',function() return true end,{no_energy=false,post_action=function(self)
        self:getTarget{type='hit',range=20,nolock=true,nowarning=true}
        emit('post_dialog',true)
    end})
    talent('nested',function(self)
        self:useTalent('T_MCP_TEST_CANCEL',nil,nil,nil,nil,nil,true)
        return true
    end)
    talent('notice_stack',function(self)
        self:useEnergy()
        Dialog:simplePopup('First native notice','The native action already spent a turn.',function() emit('notice_first_closed',true) end)
        Dialog:simpleLongPopup('Second native notice','Close each actual native layer once.',350)
        game:onTickEnd(function()
            game:registerDialog(require('mod.dialogs.QuestPopup').new({name='MCP fixture quest'},engine.Quest.PENDING))
        end,'mcp_notice_fixture')
        return true
    end)
    talent('lore_library',function()
        game:registerDialog(require('mod.dialogs.ShowLore').new('Known lore',game.party))
        return true
    end)
    talent('chat',function(self)
        require('engine.Chat').new('mcp-probe+acceptance',require('mod.MCPProbe').enemy,self):invoke()
        return true
    end)
    talent('arm_chat',function()
        M.npc_chat_armed=true
        return true
    end)
    talent('escort_reward',function(self)
        -- Fixture context only; the reward options and callbacks below come
        -- from the unmodified production escort-quest.lua / EscortRewards.
        if self.alchemy_golem then self.alchemy_golem.no_party_reward=true end
        local npc=require('mod.MCPProbe').enemy
        npc.reward_type='divination';npc.quest_id='mcp-native-escort-fixture'
        self.quests=self.quests or {};self.quests[npc.quest_id]={}
        emit('native_escort_open',true)
        require('engine.Chat').new('escort-quest',npc,self):invoke()
        return true
    end)
    talent('unsupported',function(self)
        local d=Dialog.new('Manual fixture',300,100)
        d:loadUI{{left=0,top=0,ui=require('engine.ui.Textzone').new{width=280,height=60,text='Unsupported custom dialog'}}}
        d.key:addBind('EXIT',function() game:unregisterDialog(d) end)
        d:setupUI(true,true)
        self:talentDialog(d)
        return true
    end)
    talent('error',function(self)
        self:getTarget{type='hit',range=20,nolock=true,nowarning=true}
        self:incMana(-5)
        error('mcp-expected-after-resume-error')
    end)
    talent('bare_yield',function() coroutine.yield();return true end)
    talent('task_prompt',function(self)
        local co=coroutine.running()
        self:restInit(3,'waiting','waited',function() assert(coroutine.resume(co)) end)
        coroutine.yield()
        local x=self:getTarget{type='hit',range=20,nolock=true,nowarning=true}
        emit('task_prompt',x~=nil)
        return x~=nil
    end,{no_energy=false})
    talent('task',function(self)
        local co=coroutine.running()
        local complete=false
        self:restInit(1005,'waiting','waited',function(cnt,max)
            complete=cnt>max
            assert(coroutine.resume(co))
        end)
        coroutine.yield()
        emit('task',complete)
        return complete
    end,{no_energy=false})
end
function M.start()
    local p=game.player
    -- Native Daze adds a numeric temporary never_move value. The older fixture
    -- used a boolean, which is unsuitable for Rush's native Daze path.
    require('mod.MCPProbe').enemy.never_move=1
    for _,id in ipairs{'T_RUSH','T_PRECISE_STRIKES','T_PHASE_DOOR','T_FEARLESS_CLEAVE','T_REFIT_GOLEM','T_CATAPULT_TRAP'} do
        if p.talents_def[id] then p:learnTalent(id,true,id=='T_PHASE_DOOR' and 5 or 1) end
    end
    p.max_mana=1000;p.mana=1000;p.max_stamina=1000;p.stamina=1000
    if p.alchemy_golem then p.alchemy_golem.dont_act=true;p.alchemy_golem:move(2,8,true) end
    for _,id in ipairs(test_ids) do p:learnTalent(id,true,1) end
    local Object=require 'mod.class.Object'
    local function item(name,extra)
        local def={name=name,type='test',subtype='test',identified=true,display='!',color=colors.WHITE,encumber=0}
        for k,v in pairs(extra) do def[k]=v end
        local object=Object.new(def)
        p:addObject(p.INVEN_INVEN,object)
        return object
    end
    item('MCP native charged device',{power=20,max_power=20,power_regen=0,use_power={power=7,name='choose twice',use=function(o,who)
        local x=who:getTarget{type='hit',range=20,nolock=true,nowarning=true}
        if not x then return {used=false} end
        local y=who:getTarget{type='hit',range=20,nolock=true,nowarning=true}
        require('mod.MCPProbe').emit{kind='interaction_fixture',event='item_two_questions',value=y~=nil}
        return {used=y~=nil}
    end}})
    item('MCP native consumable',{use_simple={name='consume',use=function()
        require('mod.MCPProbe').emit{kind='interaction_fixture',event='item_consumed',value=true}
        return {used=true,destroy=true,id=true}
    end}})
    item('MCP native wearable device',{slot='TOOL',power=10,max_power=10,use_power={power=5,name='test wear rule',use=function()
        require('mod.MCPProbe').emit{kind='interaction_fixture',event='unworn_device_called',value=true};return {used=true}
    end}})
    item('MCP native talent device',{power=20,max_power=20,power_regen=0,
        use_talent={id='T_PHASE_DOOR',level=5,power=10}})
    -- Fixture UI settings make answers observable, including a user's native
    -- convenience auto-accept setting that must not pre-answer remote prompts.
    config.settings.auto_accept_target=true
    config.settings.tome.immediate_melee_keys=false
    M.attach()
end
function M.attach()
    if M.attached then return end
    M.attached=true
    local function save() game:saveGame() end
    local function trapState()
        local traps={}
        for _,entity in pairs(game.level.entities) do
            if entity.name=='catapult trap' then
                traps[#traps+1]={x=entity.x,y=entity.y,target_x=entity.target_x,target_y=entity.target_y,uid=entity.uid}
            end
        end
        return traps
    end
    game.normal_key:addCommands{_F9=save,_F11=function() config.settings.tome.immediate_melee_keys=true;emit('direction_setting',true) end}
    game.targetmode_key:addCommands{_F9=save,_F10=function()
        local Controller=package.loaded['mod.battle_companion.Controller']
        if Controller then
            local started,code=Controller.start(game.player)
            emit('companion_attempt',{started=started,code=code})
        end
    end}
    local function restFixture()
        local actors={}
        for _,actor in pairs(game.level.entities) do
            if actor.__is_actor and actor.faction=='enemies' then actors[#actors+1]=actor end
        end
        for _,actor in ipairs(actors) do game.level:removeEntity(actor,true) end
        local p=game.player
        p.life=p.max_life;p.mana=p.max_mana;p.stamina=p.max_stamina
        for id in pairs(p.talents_cd) do p.talents_cd[id]=nil end
        local gem=game.zone:makeEntityByName(game.level,'object','ALCHEMIST_GEM_AGATE')
        assert(gem,'Native alchemist gem fixture is missing')
        local single=gem:clone()
        for i=1,29 do gem:stack(single:clone()) end
        p.inven[p.INVEN_QUIVER]=p.inven[p.INVEN_QUIVER] or {max=1,worn=true,name='QUIVER',id=p.INVEN_QUIVER}
        p:addObject(p.INVEN_QUIVER,gem)
        local golem=assert(p.alchemy_golem)
        game.level:removeEntity(golem,true);golem.dead=true;golem.life=-1
        p.energy.value=game.energy_to_act;game.paused=true
        emit('rest_fixture_ready',true)
    end
    game.normal_key:addCommands{_F12=restFixture,_F10=function()
        restFixture();M.interrupt_refit=true
    end}
    local NativeTasks=require 'mod.mcp_bridge.NativeTasks'
    local afterStep=NativeTasks.afterStep
    NativeTasks.afterStep=function(task,energy_before)
        afterStep(task,energy_before)
        if M.interrupt_refit and task.root.command.action.talent_id=='T_REFIT_GOLEM' and task.turns>=3 then
            M.interrupt_refit=false
            local p=game.player
            game.zone:addEntity(game.level,require('mod.MCPProbe').enemy,'actor',p.x+2,p.y)
            emit('refit_enemy_spawned',task.turns)
        end
    end
    local Interactions=require 'mod.mcp_bridge.Interactions'
    local openTarget=Interactions.openTarget
    Interactions.openTarget=function(g,typ)
        emit('target_metadata',{immediate=typ.immediate_keys,style=g.target_style,
            entity=g.target.target.entity and g.target.target.entity.uid,player=g.player.uid,
            traps=trapState(),direction_compatible=require('mod.mcp_bridge.NativeCompatibility').matches('setDirFrom',g.target.setDirFrom)})
        return openTarget(g,typ)
    end
    local Tracker=require 'mod.mcp_bridge.InvocationTracker'
    local start=Tracker.start
    Tracker.start=function(g,command,fn)
        M.calls=M.calls+1
        require('mod.MCPProbe').emit{kind='interactive_begin',command_id=command.command_id,
            talent_id=command.action.talent_id,calls=M.calls}
        return start(g,command,fn)
    end
    local release=Tracker.release
    Tracker.release=function(root)
        require('mod.MCPProbe').emit{kind='interactive_release',command_id=root.command.command_id,
            native_return=root.native_return,done=root.done,pending=root.pending,traps=trapState(),
            state=require('mod.MCPProbe').state()}
        return release(root)
    end
end
return M
