-- Own only a variant's spawned actor/controller. Keep native locomotion, ragdoll,
-- StateTree attacks and replicated movement; replace its nearest-player timer.
local M={}
local P={
    system='/Script/Engine.Default__KismetSystemLibrary',nav='/Script/NavigationSystem.Default__NavigationSystemV1',
    clear_handle='/Script/Engine.KismetSystemLibrary:K2_ClearAndInvalidateTimerHandle',
    active_handle='/Script/Engine.KismetSystemLibrary:K2_IsTimerActiveHandle',
    clear_timer='/Script/Engine.KismetSystemLibrary:K2_ClearTimer',
    active_timer='/Script/Engine.KismetSystemLibrary:K2_IsTimerActive',
    stop_brain='/Script/AIModule.BrainComponent:StopLogic',restart_brain='/Script/AIModule.BrainComponent:RestartLogic',
    running='/Script/AIModule.BrainComponent:IsRunning',stop_move='/Script/Engine.Controller:StopMovement',
    move_status='/Script/AIModule.AIController:GetMoveStatus',move_to='/Script/AIModule.AIController:MoveToLocation',
    random_point='/Script/NavigationSystem.NavigationSystemV1:K2_GetRandomReachablePointInRadius',
    los='/Script/Engine.Controller:LineOfSightTo',pawn='/Script/Engine.Controller:K2_GetPawn',montage='/Script/Engine.Character:GetCurrentMontage',
    anim='/Script/Engine.SkeletalMeshComponent:GetAnimInstance',montage_stop='/Script/Engine.AnimInstance:Montage_Stop',
    montage_playing='/Script/Engine.AnimInstance:Montage_IsPlaying',
    avatar='/Script/GameplayAbilities.GameplayAbility:GetAvatarActorFromActorInfo',
    cancel_ability='/Script/GameplayAbilities.GameplayAbility:K2_CancelAbility',
}
M.paths=P
-- Exact montage names selected by the shipped STTask_Attack asset.
local attacks={IP_RightAttack_Charged_03_Montage=true,IP_RightAttack_Charged_02_Montage=true,
    IP_RightAttack_Charged_01_Montage=true,IP_RightAttack_01_Montage=true,
    IP_LeftAttack_Charged_03_Montage=true,IP_LeftAttack_Charged_02_Montage1=true,
    IP_LeftAttack_Charged_01_Montage=true,IP_LeftAttack_01_Montage=true}
local function finite(x)return type(x)=='number'and x==x and x~=math.huge and x~=-math.huge end
local function vector(p)return type(p)=='table'and finite(p.X)and finite(p.Y)and finite(p.Z)and {X=p.X,Y=p.Y,Z=p.Z}or nil end
local function distance2(a,b)return (a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2 end
function M.new(runtime,api,options)
    assert(type(runtime)=='table','Runtime is required');api,options=api or {},options or {}
    local get,call,live,key,native=runtime.get,runtime.call,runtime.live,runtime.key,runtime.native
    for _,method in ipairs({'get','call','live','key','native','find','belongs','valid','position_of'})do
        assert(type(runtime[method])=='function','Missing runtime method: '..method)
    end
    local self={};local report={bound=0,target_changes=0,roams=0,cancelled_abilities=0,stopped_attacks=0,failures=0,
        ready=false,ready_reason='Native AI symbols have not been checked'}
    local function vocal(method,...)
        local component=options.vocals
        if type(component)=='table'and type(component[method])=='function'then
            local ok=pcall(component[method],...)
            if not ok then report.vocal_errors=(report.vocal_errors or 0)+1 end
        end
    end
    local ability_limit=options.ability_inventory_limit or 256
    assert(finite(ability_limit)and ability_limit%1==0 and ability_limit>=1 and ability_limit<=2048,'Invalid ability inventory bound')
    local function fail(reason)report.failures=report.failures+1;report.reason=reason;return false,reason end
    local function read(path,receiver,...)return native(path,receiver,...)end
    local function library(path,...)return read(path,runtime.find(P.system),...)end
    local function same(a,b)local ka,kb=key(a),key(b);return ka~=nil and kb~=nil and ka==kb end
    local function authority(o)local ok,v=call(o,'HasAuthority');return ok and v==true end
    local function brain_for(row,c)
        if type(c)~='table'or c.authority~=true or type(row)~='table'or row.world_id~=c.world_id
            or not runtime.valid(row,c)or not authority(row.actor)or not authority(row.controller)then return nil,'Owned authoritative zombie unavailable' end
        local ok,pawn=call(row.controller,'K2_GetPawn');if not ok or not same(pawn,row.actor)then return nil,'Controller pawn mismatch' end
        local brain=get(row.controller,'StateTreeAI')
        if not live(brain)or not runtime.belongs(brain,c.world)then return nil,'Owned StateTree unavailable' end
        local owned,owner=call(brain,'GetOwner');if not owned or not same(owner,row.controller)then return nil,'StateTree owner mismatch' end
        local typed,class=call(brain,'GetClass');local named,name=false,nil
        if typed then named,name=call(class,'GetFullName')end
        if not named or name~='Class /Script/GameplayStateTreeModule.StateTreeAIComponent'then return nil,'Unexpected StateTree component class' end
        return brain
    end
    local function timer_handle(row)
        local h=get(row.actor,'UpdateTargetTick');local value=get(h,'Handle')
        if not finite(value)or value<0 or value%1~=0 then return nil end
        return {Handle=value}
    end
    local function own_selector(row)
        local h=timer_handle(row);if not h then return fail('Native target timer handle unavailable')end
        local checked,active=library(P.active_handle,row.actor,h)
        if not checked or type(active)~='boolean'then return fail('Native target timer query failed')end
        -- A successful read-only inactive query needs no second identical call.
        -- After a clear, always reread the actor's handle and native timer state.
        if not active then return true end
        local ok=library(P.clear_handle,row.actor,h);if not ok then return fail('Native target timer clear failed')end
        -- The actor retains its original handle value; test that actual handle in
        -- the timer manager, not just the cleared temporary out-parameter.
        local original=timer_handle(row);local readback,running=library(P.active_handle,row.actor,original)
        if not readback or running~=false then return fail('Nearest-player timer remains active')end
        return true
    end
    local function set_speed(row,speed)
        if not finite(speed)or speed<0 or speed>1000 then return fail('Invalid zombie speed')end
        local movement=get(row.actor,'CharacterMovement')
        if not live(movement)then return fail('Character movement unavailable')end
        local ok,owner=call(movement,'GetOwner');if not ok or not same(owner,row.actor)then return fail('Movement owner mismatch')end
        if get(row.actor,'Speed')~=speed or get(movement,'MaxWalkSpeed')~=speed then
            local wrote=pcall(function()row.actor.Speed=speed;movement.MaxWalkSpeed=speed end)
            if not wrote or get(row.actor,'Speed')~=speed or get(movement,'MaxWalkSpeed')~=speed then return fail('Zombie speed readback failed')end
            call(row.actor,'ForceNetUpdate')
        end
        return true
    end
    local function hit_timer(row)
        local ok,running=library(P.active_timer,row.actor,'AttackHitDetection')
        if not ok or type(running)~='boolean'then return nil end
        return running
    end
    local function current_attack(row)
        local ok,montage=read(P.montage,row.actor)
        if not ok then return nil,nil,'Current montage query failed' end
        if not live(montage)then return false end
        local named,name=call(montage,'GetFullName')
        if not named or type(name)~='string'then return nil,nil,'Montage identity unavailable' end
        return attacks[name:match('([^./: ]+)$')]==true,montage
    end
    local function cancel_abilities(row)
        if type(api.FindAllOf)~='function'then return fail('Native ability inventory unavailable')end
        local ok,list=pcall(api.FindAllOf,'GA_Zombie_Attack_C')
        if not ok or(list~=nil and type(list)~='table')or(type(list)=='table'and #list>ability_limit)then return fail('Native ability inventory failed or exceeded bound')end
        for _,ability in ipairs(list or {})do
            if live(ability)then
                local named,name=call(ability,'GetFullName')
                if named and type(name)=='string'and not name:find('Default__',1,true)and not name:find('Archetype',1,true)then
                    local resolved,avatar=read(P.avatar,ability)
                    if resolved and same(avatar,row.actor)then
                        local owner=get(ability,'ZombieOwner')
                        if live(owner)and not same(owner,row.actor)then return fail('Attack ability owner disagrees with native avatar')end
                        local active=get(ability,'bIsActive')
                        if type(active)~='boolean'then return fail('Owned attack active state unavailable')end
                        if active then
                            if get(ability,'bIsCancelable')~=true then return fail('Owned attack ability is not cancelable')end
                            local cancelled=read(P.cancel_ability,ability)
                            if not cancelled or get(ability,'bIsActive')~=false then return fail('Owned attack ability cancellation did not verify')end
                            report.cancelled_abilities=report.cancelled_abilities+1
                        end
                    elseif same(get(ability,'ZombieOwner'),row.actor)then return fail('Owned attack avatar resolution failed')end
                end
            end
        end
        return true
    end
    local function quiesce(row,c,brain)
        local ok=read(P.stop_brain,brain,'Bodycam zombie variant target transition')
        local checked,running=read(P.running,brain)
        if not ok or not checked or running~=false then return fail('Native StateTree stop did not verify')end
        local stopped=read(P.stop_move,row.controller);local status_ok,status=read(P.move_status,row.controller)
        if not stopped or not status_ok or status~=0 then return fail('Native movement stop did not verify')end
        local attack,montage,reason=current_attack(row);if attack==nil then return fail(reason)end
        if attack then
            local mesh=get(row.actor,'Mesh');if not live(mesh)then return fail('Owned zombie mesh unavailable')end
            local owned,owner=call(mesh,'GetOwner');if not owned or not same(owner,row.actor)then return fail('Mesh owner mismatch')end
            local got,anim=read(P.anim,mesh);if not got or not live(anim)then return fail('Owned animation instance unavailable')end
            local halted=read(P.montage_stop,anim,0.0,montage)
            local check,playing=read(P.montage_playing,anim,montage)
            if not halted or not check or playing~=false then return fail('Attack montage stop did not verify')end
            report.stopped_attacks=report.stopped_attacks+1
        end
        -- Anim notify begin schedules damage every 0.033 seconds. Stop the
        -- montage first, then clear the named timer so a notify cannot rearm it.
        if not library(P.clear_timer,row.actor,'AttackHitDetection')or hit_timer(row)~=false then return fail('Attack hit timer clear did not verify')end
        if not cancel_abilities(row)then return false end
        if hit_timer(row)~=false then return fail('Attack hit timer restarted during cancellation')end
        return true
    end
    local function valid_player(player,c)
        if type(player)~='table'or player.alive~=true or player.connected==false or type(player.life)~='string'
            or not runtime.belongs(player.pawn,c.world)or get(get(player.pawn,'WW_SurvivorStatus'),'Death?')~=false then return false end
        if type(runtime.is_combatant)=='function'then
            if runtime.is_combatant(player.pawn,player.controller,c.world)~=true then return false end
        else
            local controlled,human=call(player.pawn,'IsPlayerControlled');if not controlled or human~=true then return false end
        end
        local found=false
        for _,p in ipairs(c.players or {})do
            if p.life==player.life and p.alive==true and same(p.pawn,player.pawn)then found=true;break end
        end
        return found
    end
    function self.ready()
        local function result(ok,why)report.ready=ok;report.ready_reason=why;return ok,why end
        if type(api.FindAllOf)~='function'then return result(false,'Ability inventory unavailable')end
        for _,path in pairs(P)do if not runtime.find(path)then return result(false,'Native AI symbol unavailable: '..path)end end
        return result(true)
    end
    function self.bind_ai(row,c)
        local ready,why=self.ready();if not ready then return fail(why)end
        local brain,reason=brain_for(row,c);if not brain then return fail(reason)end
        if not own_selector(row)or not quiesce(row,c,brain)then return false end
        local changed=pcall(function()row.actor.TargetToGo=nil;row.controller.TargetPerceived=false end)
        if not changed or live(get(row.actor,'TargetToGo'))or get(row.controller,'TargetPerceived')~=false then return fail('Initial native target clear did not verify')end
        row.variant_native_ai={world_id=c.world_id,brain_key=key(brain),target_life=nil,target_key=nil,roaming=true}
        report.bound=report.bound+1;report.reason=nil;return true
    end
    function self.target(row,c,player,speed,intent)
        local brain,reason=brain_for(row,c);if not brain then return fail(reason)end
        local state=row.variant_native_ai
        if not state or state.world_id~=c.world_id or state.brain_key~=key(brain)then return fail('AI binding changed')end
        if not own_selector(row)or not set_speed(row,speed)then return false end
        local brain_ok,running=read(P.running,brain);if not brain_ok or type(running)~='boolean'then return fail('StateTree run state unavailable')end
        if player==nil then
            local current=get(row.actor,'TargetToGo')
            if state.roaming and not live(current)and not running and hit_timer(row)==false then vocal('target',row,c,nil,speed,intent);return true end
            if not quiesce(row,c,brain)then return false end
            local wrote=pcall(function()row.actor.TargetToGo=nil;row.controller.TargetPerceived=false end)
            if not wrote or live(get(row.actor,'TargetToGo'))or get(row.controller,'TargetPerceived')~=false then return fail('Native target clear did not verify')end
            state.target_life=nil;state.target_key=nil;state.roaming=true;report.target_changes=report.target_changes+1
            vocal('target',row,c,nil,speed,intent);return true
        end
        if not valid_player(player,c)then return fail('Exact living player target unavailable')end
        local target_key=key(player.pawn)
        if not state.roaming and state.target_life==player.life and state.target_key==target_key
            and same(get(row.actor,'TargetToGo'),player.pawn)and running and get(row.controller,'TargetPerceived')==true then
            vocal('target',row,c,player,speed,intent);return true
        end
        if not quiesce(row,c,brain)then return false end
        local changed=pcall(function()row.actor.TargetToGo=player.pawn;row.controller.TargetPerceived=true end)
        if not changed or not same(get(row.actor,'TargetToGo'),player.pawn)or get(row.controller,'TargetPerceived')~=true then return fail('Exact native target assignment failed')end
        local restarted=read(P.restart_brain,brain);local check,active=read(P.running,brain)
        if not restarted or not check or active~=true or not same(get(row.actor,'TargetToGo'),player.pawn)then return fail('Native StateTree restart did not verify')end
        state.target_life=player.life;state.target_key=target_key;state.roaming=false
        report.target_changes=report.target_changes+1;report.reason=nil
        vocal('target',row,c,player,speed,intent);return true
    end
    function self.roam(row,c,settings)
        local brain,reason=brain_for(row,c);if not brain then return fail(reason)end
        local state=row.variant_native_ai
        if not state or state.world_id~=c.world_id or state.brain_key~=key(brain)or not state.roaming then return fail('Roaming requires a cleared native target')end
        local checked,running=read(P.running,brain)
        if not checked or running~=false or live(get(row.actor,'TargetToGo'))or hit_timer(row)~=false then return fail('Native chase or attack remains active')end
        if not own_selector(row)or not set_speed(row,settings.speed)then return false end
        local origin=runtime.position_of(row.actor);local radius=settings.radius
        if not vector(origin)or not finite(radius)or radius<=0 or radius>10000 then return fail('Invalid roaming search')end
        state.patrol_at=c.now;state.patrol_target=nil;state.patrol_result='no_route'
        local nav=runtime.find(P.nav)
        for _=1,8 do
            local point={};local ok,reachable=read(P.random_point,nav,c.world,origin,point,radius,nil,nil)
            point=vector(point)
            if ok and reachable==true and point and distance2(origin,point)>150^2 and distance2(origin,point)<=radius^2 and math.abs(point.Z-origin.Z)<300 then
                local moved,result=read(P.move_to,row.controller,point,75,true,true,true,false,nil,false)
                state.patrol_target=vector(point);state.patrol_result=moved and type(result)=='number'and result or 'call_failed'
                if moved and(result==1 or result==2)then report.roams=report.roams+1;return true end
            end
        end
        -- Standing is a valid ambient state when this spawn has no patrol route.
        report.idle_no_route=(report.idle_no_route or 0)+1;return true
    end
    function self.perceived(row,c,player)
        local brain=brain_for(row,c);if not brain or not row.variant_native_ai or not valid_player(player,c)then return false end
        -- Native Controller.LineOfSightTo uses its eye viewpoint for zero vector.
        local ok,visible=read(P.los,row.controller,player.pawn,{X=0,Y=0,Z=0},false)
        return ok and visible==true
    end
    function self.combat(row,c)
        local brain=brain_for(row,c);if not brain or not row.variant_native_ai then return false end
        local attack=hit_timer(row)==true
        if not attack then attack=current_attack(row)==true end
        vocal('combat',row,c,attack);return attack
    end
    function self.snapshot()
        local out={};for k,v in pairs(report)do out[k]=v end
        -- The controller's explicit readiness check and bind path refresh this.
        -- Writing diagnostics must not perform another native symbol inventory.
        out.owner='BodycamZombieVariants';out.live_verified=false;return out
    end
    return self
end
return M
