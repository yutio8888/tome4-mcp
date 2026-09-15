-- Native Chat fixture. Selection, regeneration and auto pages use engine code.
local function emit(event,value)
    require('mod.MCPProbe').emit{kind='interaction_fixture',event=event,value=value}
end
local answers={}
for i=1,40 do
    local n=i
    answers[#answers+1]={i<=2 and 'Same label' or 'Visible choice '..i,
        action=function() emit('chat_choice',n) end,jump='automatic'}
end
answers[#answers+1]={'Hidden choice',cond=function() emit('chat_cond',true);return false end}
newChat{id='welcome',text='Native conversation with forty visible answers.',answers=answers}
newChat{id='automatic',text='Native automatic transition.',auto=function() return 'jump','reward' end,answers={}}
newChat{id='reward',text='Choose a reward, then continue the same conversation.',answers={
    {'Improve Willpower by 2',action=function(npc,player)
        player:incIncStat('wil',2)
        emit('chat_reward',true)
        require('engine.ui.Dialog'):simplePopup('Reward notice','The reward has already been applied.')
    end,jump='farewell'},
}}
newChat{id='farewell',text='The reward is complete.',answers={
    {'Thank you. Farewell.',action=function() emit('chat_farewell',true) end},
}}
return 'welcome'
