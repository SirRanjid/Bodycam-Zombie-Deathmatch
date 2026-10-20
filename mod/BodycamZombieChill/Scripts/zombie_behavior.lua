-- Host-owned zombie speed selection; caller owns the native game-thread tick.
local Module={}
local WALK,RUN,FAST_RUN,FAST_PERCENT,DELAY_MIN,DELAY_MAX,MAX_ALIVE=125,375,450,25,1,4,42
local SIGHT_MULTIPLIER=1.8
local function get(o,k)
    if o==nil then return nil end
    local ok,v=pcall(function()return o[k]end);if ok then return v end
end
local function call(o,k,...)
    if o==nil then return false,'missing receiver' end
    local a=table.pack(...);local ok,f=pcall(function()return o[k]end)
    if ok and f~=nil then return pcall(f,o,table.unpack(a,1,a.n)) end
    local mt_ok,mt=pcall(getmetatable,o);f=mt_ok and type(mt)=='table' and rawget(mt,k)
    if type(f)=='function' then return pcall(f,o,table.unpack(a,1,a.n)) end
    return false,'method unavailable'
end
local function valid(o)local ok,v=call(o,'IsValid');return ok and v==true end
local function name(o)local ok,v=call(o,'GetFullName');return ok and type(v)=='string' and v or nil end
local function finite(n)return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function near(a,b)return finite(a)and finite(b)and math.abs(a-b)<=math.max(0.01,math.abs(b)*0.00001)end
local function belongs(o,w)
    if not valid(o)then return false end
    local ok,world=call(o,'GetWorld');return ok and valid(world) and name(world)==name(w)
end
local function dead(actor)
    local d=get(get(actor,'WW_SurvivorStatus'),'Death?')
    if type(d)=='boolean'then return d end
    local out={};local ok=call(actor,'IsDead',out)
    if ok and type(out['Dead?'])=='boolean'then return out['Dead?']end
end
function Module.new(core,api,options)
    api,options=api or {},options or {}
    local self={};local active,closed=false,false
    local find_all=api.FindAllOf or FindAllOf
    local find_object=api.StaticFindObject or StaticFindObject
    local random=api.random or math.random
    local sight_class
    local records={};local sight_updates={};local round;local bag={};local cursor=1;local last_elapsed
    local report={version='0.1.7',phase='IDLE',runner_percent=80,walk_speed=WALK,run_speed=RUN,max_active=MAX_ALIVE,
        fast_run_speed=FAST_RUN,fast_runner_percent=FAST_PERCENT,
        aggression_percent=80,sight_range_multiplier=SIGHT_MULTIPLIER,lose_sight_range_multiplier=SIGHT_MULTIPLIER,
        perception_delay_min_seconds=DELAY_MIN,perception_delay_max_seconds=DELAY_MAX,
        walking=0,running=0,fast_running=0,waiting=0,seen=0,eligible_seen=0,errors=0,zombies={}}
    local function issue(reason)
        report.reason=reason;if options.log then pcall(options.log,'Zombie behavior: '..reason)end
        return false,reason
    end
    local function authority(world)
        if not valid(world)or not valid(get(world,'AuthorityGameMode'))or type(find_all)~='function'then return false end
        local ok,driver=pcall(function()return world.NetDriver end)
        if not ok then return false end
        if valid(driver)then
            local read,server=pcall(function()return driver.ServerConnection end)
            if not read or valid(server)then return false end
        end
        local read,list=pcall(find_all,'GameViewportClient')
        if not read or type(list)~='table'then return false end
        for i,vp in ipairs(list)do
            if i>8 then break end
            local w=get(vp,'World')
            if valid(w)then return name(w)==name(world)end
        end
        return false
    end
    local function draw_integer(low,high)
        local ok,value=pcall(random,low,high)
        if ok and finite(value)and value%1==0 and value>=low and value<=high then return value end
    end
    local function next_eligible()
        if cursor>#bag then
            local next_bag={true,true,true,true,false}
            for i=5,2,-1 do
                local j=draw_integer(1,i)
                if not j then return nil,'Runner selection random source failed or exceeded its bounds'end
                next_bag[i],next_bag[j]=next_bag[j],next_bag[i]
            end
            bag=next_bag
            cursor=1
        end
        local value=bag[cursor];cursor=cursor+1;return value
    end
    local function alive_player(world)
        local ok,list=pcall(core.get_players)
        if not ok or type(list)~='table'or #list>6 then return false end
        for i,p in ipairs(list)do
            if i>6 then return false end
            if type(p)=='table'and p.alive==true and p.eliminated~=true and p.connected~=false
                and belongs(p.pawn,world)and dead(p.pawn)==false then return true end
        end
        return false
    end
    local function set_speed(row,r,target)
        local movement=get(row.actor,'CharacterMovement')
        if not valid(movement)then r.reason='Character movement is not ready';return false end
        local owner,actor=call(movement,'GetOwner')
        if not owner or name(actor)~=name(row.actor)then r.reason='Character movement owner mismatch';return false end
        local speed,current=get(row.actor,'Speed'),get(movement,'MaxWalkSpeed')
        if not finite(speed)or not finite(current)then r.reason='Movement speed fields are unreadable';return false end
        if speed~=target or current~=target then
            if r.write_failures>=3 then r.reason='Three speed update failures; further writes blocked';return false end
            local wrote=pcall(function()row.actor.Speed=target;movement.MaxWalkSpeed=target end)
            if not wrote or get(row.actor,'Speed')~=target or get(movement,'MaxWalkSpeed')~=target then
                r.write_failures=r.write_failures+1;r.reason='Speed update readback failed';return false
            end
            call(row.actor,'ForceNetUpdate')
        end
        r.speed=target;r.reason=nil;return true
    end
    local function sight_config(component)
        local array=get(component,'SensesConfig');local counted,count=call(array,'GetArrayNum')
        if not counted and type(array)=='table'and get(array,'ForEach')==nil then count=#array;counted=true end
        if not counted or not finite(count)or count%1~=0 or count<1 or count>8 then return nil,'Bounded native sight configuration is unavailable'end
        local list={};local function add(_,value)
            if not valid(value)then local ok,v=call(value,'get');if ok then value=v end end
            list[#list+1]=value;return #list>=8
        end
        local iterated=call(array,'ForEach',add)
        if not iterated and type(array)=='table'and get(array,'ForEach')==nil then
            list={};for i=1,count do add(i,array[i])end;iterated=true
        end
        if not iterated or #list~=count then return nil,'Native sight configuration enumeration failed'end
        local found
        for _,config in ipairs(list)do
            if not valid(config)then return nil,'Native sight configuration object is invalid'end
            local ok,kind=call(config,'GetClass');local matches=false
            if ok then for _=1,8 do
                if not valid(kind)then break end
                if name(kind)=='Class /Script/AIModule.AISenseConfig_Sight'then matches=true;break end
                local parent,base=call(kind,'GetSuperStruct');if not parent then break end;kind=base
            end end
            if matches then
                local own,outer=call(config,'GetOuter');local key=name(config)
                if not own or not valid(outer)or name(outer)~=name(component)or not key or key:find('Default__',1,true)
                    or key:find('Archetype',1,true)then return nil,'Sight configuration is not an owned instance'end
                if found then return nil,'Multiple native sight configurations are ambiguous'end
                found=config
            end
        end
        return found,not found and 'Native sight configuration class is unavailable'or nil
    end
    local function enhance_sight(row,r,component)
        local key=name(component)
        if not key then r.aggression={reason='Owned perception identity is unavailable'};return false end
        local update=sight_updates[key]
        if not update then
            -- A component replacement retains at most one cache entry per owned
            -- actor. Never dereference old actors or configurations to prune it.
            for cached_key,previous in pairs(sight_updates)do
                if previous.actor_key==row.key then sight_updates[cached_key]=nil end
            end
            update={actor_key=row.key,attempts=0};sight_updates[key]=update
        end
        r.aggression=update
        if update.applied then
            -- The native component may retire its old config independently.
            -- After the initial readback, retain scalars only and never poll a
            -- potentially stale configuration or rebase an external change.
            return update.reason==nil
        end
        if update.attempts>=3 then return false end
        update.attempts=update.attempts+1
        local config,why=sight_config(component)
        if not config then update.reason=why;return false end
        local sight,lose=get(config,'SightRadius'),get(config,'LoseSightRadius')
        if not finite(sight)or not finite(lose)or sight<=0 or lose<sight or lose>100000 then
            update.reason='Native sight radii are unreadable or outside safe bounds';return false
        end
        local target_sight,target_lose=sight*SIGHT_MULTIPLIER,lose*SIGHT_MULTIPLIER
        local wrote=pcall(function()config.SightRadius=target_sight;config.LoseSightRadius=target_lose end)
        if not wrote or not near(get(config,'SightRadius'),target_sight)or not near(get(config,'LoseSightRadius'),target_lose)then
            pcall(function()config.SightRadius=sight;config.LoseSightRadius=lose end)
            update.reason='Native sight radius update failed; original values requested'
            -- A partially refused rollback must never become a new baseline.
            if not near(get(config,'SightRadius'),sight)or not near(get(config,'LoseSightRadius'),lose)then
                update.attempts=3;update.reason='Native sight update rollback failed; further writes blocked'
            end
            return false
        end
        update.sight_original=sight;update.lose_original=lose
        update.sight_target=target_sight;update.lose_target=target_lose;update.applied=true
        update.reason=nil
        local refreshed=call(component,'RequestStimuliListenerUpdate')
        if not refreshed then update.reason='Enhanced sight listener refresh failed'end
        return refreshed
    end
    local function prepare_perception(row,r)
        local component=get(row.controller,'AIPerception')
        if not valid(component)then r.perception_reason='Owned AI perception component is unavailable';return false end
        local ok,owner=call(component,'GetOwner')
        if not ok or name(owner)~=name(row.controller)then r.perception_reason='AI perception owner mismatch';return false end
        -- Change only the controller's instanced native sight config. Leave LOS,
        -- affiliation, memory age, auto-success range and attack/damage untouched.
        -- TargetPerceived already latches in the shipped AI, so do not fabricate
        -- targets or reactivate perception after its original event deactivates it.
        enhance_sight(row,r,component)
        if r.perceived_at~=nil or get(row.controller,'TargetPerceived')==true then return true end
        local key=name(component)
        if r.perception_component==key and r.perception_prepared then return true end
        if (r.perception_attempts or 0)>=3 then return false end
        r.perception_attempts=(r.perception_attempts or 0)+1
        if not valid(sight_class)and type(find_object)=='function'then
            local found,kind=pcall(find_object,'/Script/AIModule.AISense_Sight')
            sight_class=found and kind or nil
        end
        if not valid(sight_class)then r.perception_reason='Native sight sense class is unavailable';return false end
        -- The shipped zombie sight configuration starts disabled. Its native
        -- perception event latches TargetPerceived and deactivates perception
        -- after noticing a player. Enable that existing path once, rather than
        -- promoting runners by spawn age or inventing a perceived target.
        local activated=call(component,'Activate',false)
        local enabled=activated and call(component,'SetSenseEnabled',sight_class,true)
        local refreshed=enabled and call(component,'RequestStimuliListenerUpdate')
        if not refreshed then r.perception_reason='Native sight activation failed';return false end
        r.perception_component=key;r.perception_prepared=true;r.perception_reason=nil
        return true
    end
    local native_cache={}
    local function native_object(path)
        if native_cache[path]==nil then
            local ok,value=false,nil
            if type(find_object)=='function'then ok,value=pcall(find_object,path)end
            native_cache[path]=ok and valid(value)and value or false
        end
        return native_cache[path]or nil
    end
    local function native_call(path,context,...)
        local fn=native_object(path)
        if not fn or context==nil then return false,'Verified native API is unavailable' end
        return call(fn,'CallFunction',context,...)
    end
    local function engine_lives(object)
        if object==nil then return false end
        local ok,alive=native_call('/Script/Engine.KismetSystemLibrary:IsValid',
            native_object('/Script/Engine.Default__KismetSystemLibrary'),object)
        return ok and alive==true
    end
    local function position(actor)
        local ok,p=call(actor,'K2_GetActorLocation')
        local x,y,z=get(p,'X'),get(p,'Y'),get(p,'Z')
        if ok and finite(x)and finite(y)and finite(z)then return {X=x,Y=y,Z=z}end
    end
    local function distance(a,b)
        local x,y,z=a.X-b.X,a.Y-b.Y,a.Z-b.Z
        return math.sqrt(x*x+y*y+z*z)
    end
    local function retry_path(row,r,world,elapsed,budget)
        r.repath=r.repath or {attempts=0,restarts=0,failures=0}
        local state=r.repath
        local function wait(reason)
            state.stationary_since=nil;state.position=nil;state.reason=reason
        end
        if not engine_lives(world)or not engine_lives(row.actor)or not engine_lives(row.controller)then
            wait('Native retry object validity is unavailable');return
        end
        local paused,is_paused=native_call('/Script/Engine.GameplayStatics:IsGamePaused',
            native_object('/Script/Engine.Default__GameplayStatics'),world)
        if not paused or is_paused~=false then wait('Game pause state does not permit repathing');return end
        if get(row.controller,'TargetPerceived')~=true then
            state.perceived_target=nil;wait('No previously perceived target');return
        end
        local target=get(row.actor,'TargetToGo')
        if not engine_lives(target)or not belongs(target,world)then wait('Current target is unavailable');return end
        local target_name=name(target)
        local got,players=pcall(core.get_players)
        if not got or type(players)~='table'or #players>6 then wait('Human target roster is unavailable');return end
        local here=position(row.actor);if not here then wait('Zombie position is unavailable');return end
        local attack=get(row.actor,'DistanceAttack');local minimum=math.max(500,finite(attack)and attack+200 or 500)
        local found=false
        for _,player in ipairs(players)do
            if type(player)=='table'and player.alive==true and player.connected~=false and player.eliminated~=true then
                if not engine_lives(player.pawn)or not belongs(player.pawn,world)then wait('Living player identity is unavailable');return end
                if dead(player.pawn)==false then
                    local there=position(player.pawn)
                    if not there or distance(here,there)<=minimum then wait('A living player is within the attack safety distance');return end
                    if name(player.pawn)==name(target)then found=true end
                end
            end
        end
        if not found then wait('Current target is not a living human participant');return end
        if state.perceived_target~=target_name then
            -- Accept only the AI's existing, validated new goal. Never select or
            -- assign a target; a new pawn life gets its own stationary interval.
            state.perceived_target=target_name;state.position=nil;state.stationary_since=nil
            state.failures=0;state.next_at=nil;state.awaiting_motion=nil;state.restart_position=nil
        end
        if state.awaiting_motion and state.restart_position and distance(here,state.restart_position)>40 then
            state.awaiting_motion=nil;state.restart_position=nil;state.failures=0;state.next_at=nil
            state.observed_motion_after_restart=(state.observed_motion_after_restart or 0)+1
        end
        if get(get(row.actor,'WW_RagdollSystem'),'RagdollState')==true or get(row.actor,'Jumped?')==true then
            wait('Ragdoll or jump action is active');return
        end
        local moved,status=native_call('/Script/AIModule.AIController:GetMoveStatus',row.controller)
        if not moved or status~=0 then wait('Path following is not idle');return end
        local brain=get(row.controller,'StateTreeAI')
        if not engine_lives(brain)then wait('Owned StateTree is unavailable');return end
        local own,owner=call(brain,'GetOwner')
        if not own or not engine_lives(owner)or name(owner)~=name(row.controller)or not belongs(owner,world)then
            wait('StateTree owner or world does not match the tracked controller');return
        end
        local kind_ok,kind=call(brain,'GetClass')
        if not kind_ok or not engine_lives(kind)or name(kind)~='Class /Script/GameplayStateTreeModule.StateTreeAIComponent'then
            wait('The original native StateTree AI component is required');return
        end
        local running,was_running=native_call('/Script/AIModule.BrainComponent:IsRunning',brain)
        local pause_ok,brain_paused=native_call('/Script/AIModule.BrainComponent:IsPaused',brain)
        if not running or was_running~=true or not pause_ok or brain_paused~=false then wait('Brain logic is stopped or paused');return end
        local travelled=state.position and distance(here,state.position)
        if not travelled or travelled>40 then
            state.position=here;state.stationary_since=elapsed;state.reason=nil;return
        end
        if elapsed-(state.stationary_since or elapsed)<3 or elapsed<(state.next_at or 0)or budget.used then return end
        budget.used=true;state.attempts=state.attempts+1
        state.next_at=elapsed+math.min(30,5*2^math.min(3,state.failures));state.failures=state.failures+1
        report.repath_queries=(report.repath_queries or 0)+1
        local queried,path=native_call('/Script/NavigationSystem.NavigationSystemV1:FindPathToActorSynchronously',
            native_object('/Script/NavigationSystem.Default__NavigationSystemV1'),world,here,target,100,row.actor,nil)
        if not queried or not engine_lives(path)then state.reason='No valid navigation path is available';return end
        -- NavigationPath.IsValid is distinct from UE4SS UObject.IsValid.
        local checked,valid_path=native_call('/Script/NavigationSystem.NavigationPath:IsValid',path)
        local partial,partial_path=native_call('/Script/NavigationSystem.NavigationPath:IsPartial',path)
        if not checked or valid_path~=true or not partial or partial_path~=false then state.reason='A complete path to the current target is unavailable';return end
        local restarted,result=native_call('/Script/AIModule.BrainComponent:RestartLogic',brain)
        local verified,is_running=native_call('/Script/AIModule.BrainComponent:IsRunning',brain)
        if not restarted or result==false or not verified or is_running~=true then state.reason='Original StateTree restart did not verify';return end
        state.restarts=state.restarts+1;state.awaiting_motion=true;state.restart_position=here;state.reason=nil
        state.stationary_since=elapsed;state.position=here
        report.repath_restarts=(report.repath_restarts or 0)+1
    end
    function self.start()
        if closed then return issue('Behavior adapter is shut down')end
        if type(core)~='table'or type(core.get_zombies)~='function'or type(core.get_players)~='function'
            or type(find_all)~='function'then return issue('Required owned-zombie APIs are unavailable')end
        active=true;report.phase='READY';return true
    end
    function self.tick(status,world)
        if not active or closed then return false,'Behavior adapter is not active'end
        if type(status)~='table'or status.phase~='RUNNING'and status.phase~='PREMATCH'or status.mode_name~='Z-Deathmatch'then
            report.phase='WAITING';return true
        end
        if not authority(world)then return issue('The current authoritative host world is required')end
        local elapsed=status.clock_seconds or status.elapsed_seconds
        local round_start=status.prematch_started_at or status.started_at
        if not finite(elapsed)or elapsed<0 or not finite(round_start)then return issue('Round clock is unavailable')end
        local identity=name(world)..'|'..tostring(round_start)
        if identity~=round then
            records={};bag={};cursor=1;round=identity;last_elapsed=nil
            report.seen=0;report.eligible_seen=0;report.errors=0;report.zombies={}
        end
        if last_elapsed and elapsed<last_elapsed then return issue('Round clock moved backwards')end
        last_elapsed=elapsed
        local ok,list=pcall(core.get_zombies)
        if not ok or type(list)~='table'or #list>MAX_ALIVE then return issue('Bounded owned-zombie roster is unavailable')end
        local has_player=alive_player(world)
        report.phase='RUNNING';report.reason=nil;report.world=name(world)
        report.walking=0;report.running=0;report.fast_running=0;report.waiting=0;report.zombies={}
        local current_actors={};for _,row in ipairs(list)do if type(row)=='table'and type(row.key)=='string'then current_actors[row.key]=true end end
        -- Drop old entries by their primitive key, never by inspecting a cached actor.
        for key in pairs(records)do if not current_actors[key]then records[key]=nil end end
        for key,update in pairs(sight_updates)do if not current_actors[update.actor_key]then sight_updates[key]=nil end end
        local retry_budget={used=false}
        for i,row in ipairs(list)do
            if i>MAX_ALIVE then break end
            if type(row)=='table'and type(row.key)=='string'and row.key~=''and name(row.actor)==row.key
                and belongs(row.actor,world)and belongs(row.controller,world)and dead(row.actor)==false then
                local controlled,c=call(row.actor,'GetController')
                local auth,a=call(row.actor,'HasAuthority');local ca,controller_authority=call(row.controller,'HasAuthority')
                if controlled and name(c)==name(row.controller)and auth and a==true and ca and controller_authority==true then
                    local r=records[row.key]
                    if not r then
                        local eligible,why=next_eligible();if eligible==nil then return issue(why)end
                        r={generation=row.generation,eligible=eligible,write_failures=0,run_speed=RUN,fast=false}
                        -- Draw once per owned actor life; phase/generation changes keep it.
                        if r.eligible then
                            r.run_delay=draw_integer(DELAY_MIN,DELAY_MAX)
                            if not r.run_delay then r.delay_error='Runner delay draw failed; owned zombie remains walking'end
                            r.fast_draw=draw_integer(1,100)
                            if r.fast_draw then
                                r.fast=r.fast_draw<=FAST_PERCENT;r.run_speed=r.fast and FAST_RUN or RUN
                            else r.fast_selection_reason='Fast-runner draw failed; standard run speed retained'end
                        end
                        records[row.key]=r;report.seen=report.seen+1
                        if r.eligible then report.eligible_seen=report.eligible_seen+1 end
                    else r.generation=row.generation end
                    local low,high=get(row.actor,'AdaptiveSpeedMinDistance'),get(row.actor,'AdaptiveSpeedMaxDistance')
                    local safe=finite(low)and finite(high)and low>=10000000 and high>low
                    -- Walkers need the same native sight/target path; only speed
                    -- promotion is restricted to the selected four of five.
                    if safe and has_player then prepare_perception(row,r)end
                    if r.eligible and r.run_delay~=nil and r.perceived_at==nil and has_player and get(row.controller,'TargetPerceived')==true then
                        r.perceived_at=elapsed
                    end
                    if r.eligible and r.perceived_at~=nil and has_player and elapsed-r.perceived_at>=r.run_delay then r.running=true end
                    local target=r.running and r.run_speed or WALK
                    if not safe then r.reason='Original distance acceleration was not disabled before spawn'
                    else set_speed(row,r,target)end
                    if r.delay_error then r.reason=r.delay_error end
                    if r.reason then report.errors=report.errors+1;report.reason=r.reason end
                    if r.speed==RUN or r.speed==FAST_RUN then report.running=report.running+1 else report.walking=report.walking+1 end
                    if r.speed==FAST_RUN then report.fast_running=report.fast_running+1 end
                    if r.eligible and target==WALK then report.waiting=report.waiting+1 end
                    if safe and has_player then retry_path(row,r,world,elapsed,retry_budget)end
                    report.zombies[row.key]={eligible=r.eligible,speed=r.speed,perceived_at=r.perceived_at,
                        run_delay_seconds=r.run_delay,run_speed=r.run_speed,fast=r.fast,fast_draw=r.fast_draw,
                        fast_selection_reason=r.fast_selection_reason,
                        delay_remaining=r.perceived_at and math.max(0,r.run_delay-(elapsed-r.perceived_at))or nil,
                        reason=r.reason,write_failures=r.write_failures,perception_prepared=r.perception_prepared==true,
                        perception_reason=r.perception_reason,perception_attempts=r.perception_attempts,
                        aggression_applied=r.aggression and r.aggression.applied==true or false,
                        aggression_reason=r.aggression and r.aggression.reason,
                        aggression_attempts=r.aggression and r.aggression.attempts,
                        sight_radius=r.aggression and r.aggression.sight_target,
                        lose_sight_radius=r.aggression and r.aggression.lose_target,
                        target_perceived=get(row.controller,'TargetPerceived')==true,repath=r.repath}
                end
            end
        end
        return true
    end
    function self.shutdown()
        active=false;closed=true;records={};sight_updates={};report.phase='SHUTDOWN';report.zombies={};return true
    end
    function self.status()return report end
    return self
end
return Module
