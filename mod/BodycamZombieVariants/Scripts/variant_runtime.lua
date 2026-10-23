-- Host-only Unreal adapter. All entrypoints must run on the game thread.
-- The verified damage/score/target bridge is intentionally a required dependency.
local M={}
local PAWN='/Game/BodycamZombies/ZombieAI/BP_NormalZombie.BP_NormalZombie_C'
local CONTROLLER='/Game/BodycamZombies/ZombieAI/AIC_Zombie.AIC_Zombie_C'
local PDA='/Game/GM/Zombie/Gamemode/PDA/cemeteryZombies.cemeteryZombies'
local BOT_PAWN='/Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/AI_Humanoid.AI_Humanoid_C'
local BOT_CONTROLLER='/Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/AI/ALS_AI_Controller.ALS_AI_Controller_C'
local function get(o,k) if o~=nil then local ok,v=pcall(function()return o[k]end);if ok then return v end end end
local function call(o,k,...)
    if o==nil then return false end
    local args=table.pack(...);local f=get(o,k)
    if f~=nil then return pcall(f,o,table.unpack(args,1,args.n)) end
    local ok,mt=pcall(getmetatable,o);f=ok and type(mt)=='table' and rawget(mt,k)
    if type(f)=='function' then return pcall(f,o,table.unpack(args,1,args.n)) end
    return false
end
local function valid(o)local ok,v=call(o,'IsValid');return ok and v==true end
local function finite(n)return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function vec(v)
    local x,y,z=get(v,'X'),get(v,'Y'),get(v,'Z')
    if finite(x) and finite(y) and finite(z) then return {X=x,Y=y,Z=z} end
end
local function dist2(a,b)return (a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2 end
local function dead(actor)return get(get(actor,'WW_SurvivorStatus'),'Death?') end
local function boolean(v)if type(v)=='boolean'then return v end end
local function start_tag(actor)
    local tag=get(actor,'PlayerStartTag')
    if type(tag)=='string'then return tag end
    local ok,value=call(tag,'ToString');return ok and type(value)=='string'and value or nil
end
function M.new(api,bridge,settings)
    api,bridge=api or {},bridge or {}
    local population_limit=(settings and settings.max_total or 14)+(settings and settings.corpse_cap or 8)
    assert(finite(population_limit) and population_limit%1==0 and population_limit>0 and population_limit<=256,'Invalid population limit')
    local self={};local owned={};local corpses={};local world_id;local generation=0;local roster={};local cleanup_failed=false;local lives={};local life_serial=0
    local symbols={};local active_viewport
    local function find(path)
        if type(api.StaticFindObject)~='function' then return nil end
        -- Engine symbols are stable UObject definitions, not actors or world data.
        -- Keep only successful /Script lookups and still validate every wrapper.
        local cacheable=type(path)=='string'and path:sub(1,8)=='/Script/'
        local cached=cacheable and symbols[path]
        if cached and valid(cached)then return cached end
        local ok,o=pcall(api.StaticFindObject,path);o=ok and valid(o)and o or nil
        if cacheable then symbols[path]=o end
        return o
    end
    local function native(path,receiver,...)
        return call(find(path),'CallFunction',receiver,...)
    end
    local function live(o)
        if not valid(o) then return false end
        local ok,v=native('/Script/Engine.KismetSystemLibrary:IsValid',find('/Script/Engine.Default__KismetSystemLibrary'),o)
        if not ok or v~=true then return false end
        local read,destroying=call(o,'IsActorBeingDestroyed')
        return not(read and destroying==true)
    end
    local function live_identity(o)
        local ok,address=call(o,'GetAddress');local named,n=call(o,'GetFullName')
        if ok and finite(address) and address>0 and named and type(n)=='string' then return n..'@'..string.format('%.0f',address) end
    end
    local function key(o)if live(o)then return live_identity(o)end end
    local function belongs(o,world)
        if not live(o) or not live(world) then return false end
        local expected_world=live_identity(world);if not expected_world then return false end
        local ok,w=call(o,'GetWorld');if ok and key(w)==expected_world then return true end
        local got,level=call(o,'GetLevel');if not got or not live(level)then return false end
        if key(get(level,'OwningWorld'))==expected_world then return true end
        local levels=get(world,'Levels');local counted,n=call(levels,'GetArrayNum')
        if not counted or not finite(n)or n<0 or n>512 or n%1~=0 then return false end
        local found=false;local visited=0;local expected=key(level)
        call(levels,'ForEach',function(_,element)
            visited=visited+1;local wrapped,value=call(element,'get');if wrapped then element=value end
            if key(element)==expected then found=true;return true end
            return visited>=n
        end)
        return found
    end
    local function position(o)if live(o) then local ok,p=call(o,'K2_GetActorLocation');return ok and vec(p) or nil end end
    local function class_path(o)
        local typed,class=call(o,'GetClass');if not typed or not live(class)then return nil end
        local named,n=call(class,'GetFullName');return named and type(n)=='string'and n:match('^%S+ (/.+)$')or nil
    end
    local function combatant_kind(pawn,controller,pawn_key,controller_key)
        if pawn_key and owned[pawn_key]then return false end
        local controlled,human=call(pawn,'IsPlayerControlled')
        if not controlled then return false end
        if human==true then return true,'human' end
        -- Only the game's actual match bot pair may join the player roster.
        -- General AIControllers, spectator actors and zombie pawns are excluded.
        if human~=false or class_path(pawn)~=BOT_PAWN or class_path(controller)~=BOT_CONTROLLER then return false end
        local auth,authoritative=call(controller,'HasAuthority');local pawn_auth,authoritative_pawn=call(pawn,'HasAuthority')
        local back,owner=call(pawn,'GetController')
        local linked,actual=call(controller,'K2_GetPawn')
        if auth and authoritative==true and pawn_auth and authoritative_pawn==true
            and back and key(owner)==controller_key and linked and key(actual)==pawn_key then return true,'bot' end
        return false
    end
    local function combatant(pawn,controller,world)
        if not belongs(pawn,world)or not belongs(controller,world)then return false end
        local pk,ck=key(pawn),key(controller)
        if not pk or not ck then return false end
        return combatant_kind(pawn,controller,pk,ck)
    end
    local function owns_controller(pc,actor,world)
        if not belongs(pc,world) then return false end
        local linked,pawn=call(pc,'K2_GetPawn');local typed,class=call(pc,'GetClass')
        local named,n=false,nil;if typed then named,n=call(class,'GetFullName')end
        return linked and key(pawn)==key(actor) and named and type(n)=='string' and n:match('([^./: ]+)$')=='AIC_Zombie_C'
    end
    local function all(class,limit)
        if type(api.FindAllOf)~='function' then return {} end
        local ok,list=pcall(api.FindAllOf,class)
        if not ok or type(list)~='table' or #list>limit then return {} end
        return list
    end
    local function load(path)
        local o=find(path);if o then return o end
        if type(api.LoadAsset)~='function' then return nil,'LoadAsset unavailable' end
        local ok,v,found,loaded=pcall(api.LoadAsset,path)
        if not ok then return nil,'LoadAsset failed: '..tostring(v):sub(1,200)end
        if live(v)then return v end
        return nil,'LoadAsset returned no live object (found='..tostring(found)..', loaded='..tostring(loaded)..')'
    end
    self.get=get;self.call=call;self.live=live;self.key=key;self.belongs=belongs;self.position_of=position
    self.is_combatant=combatant
    self.find=find;self.native=native;self.find_all=all;self.load_asset=load
    local function world_context(world,id)
        local gm=get(world,'AuthorityGameMode');local network_read,driver=pcall(function()return world.NetDriver end)
        local auth,has_authority=call(gm,'HasAuthority')
        local authority=live(gm) and auth and has_authority==true and network_read
        if live(driver)then
            local read,server=pcall(function()return driver.ServerConnection end)
            authority=authority and read and not live(server)
        end
        local ok,now=call(find('/Script/Engine.Default__GameplayStatics'),'GetRealTimeSeconds',world)
        if not ok or not finite(now) then return nil,'World clock unavailable' end
        return {world=world,world_id=id,world_key=id,generation=generation,now=now,authority=authority,players={},gamemode=gm,game_mode=gm}
    end
    function self.context()
        local world,viewport_found;active_viewport=nil
        for _,viewport in ipairs(all('GameViewportClient',8)) do
            if live(viewport)then local w=get(viewport,'World');if live(w) then world=w;viewport_found=viewport;break end end
        end
        if not world then roster={};return nil,'Active world unavailable' end
        local id=key(world);if not id then return nil,'World identity unavailable' end
        if world_id~=id then
            -- Never dereference old actors during travel. Only scalar generation survives.
            owned={};corpses={};roster={};lives={};symbols={};cleanup_failed=false;generation=generation+1;world_id=id
        end
        local c,why=world_context(world,id);if not c then roster={};return nil,why end
        active_viewport=viewport_found
        if not c.authority then roster={};return c end
        local seen={}
        local controllers=all('PlayerController',64)
        -- Do not mutate the inventory returned by the UE4SS API.
        local candidates={};for _,pc in ipairs(controllers)do candidates[#candidates+1]=pc end
        for _,pc in ipairs(all('ALS_AI_Controller_C',256))do candidates[#candidates+1]=pc end
        for _,pc in ipairs(candidates) do
            if belongs(pc,world) then
                local auth,a=call(pc,'HasAuthority');local p,pawn=call(pc,'K2_GetPawn')
                if auth and a==true and p and belongs(pawn,world) then
                    local pk,ck=key(pawn),key(pc)
                    -- World/authority checks above are still current: only reads
                    -- occur before this private classifier. Do not repeat them.
                    local eligible,kind=false,nil
                    if pk and ck then eligible,kind=combatant_kind(pawn,pc,pk,ck)end
                    local pos=eligible and position(pawn)or nil
                    if eligible and pk and ck and pos and not seen[pk] then
                        seen[pk]=true
                        local alive=dead(pawn)==false;local life=lives[pk]
                        if not life or (life.alive==false and alive) then
                            life_serial=life_serial+1;life={id=pk..'#'..life_serial};lives[pk]=life
                        end
                        life.alive=alive
                        c.players[#c.players+1]={key=ck,life=life.id,pawn_key=pk,pawn=pawn,controller=pc,position=pos,alive=alive,combatant_kind=kind}
                    end
                end
            end
        end
        for k in pairs(lives)do if not seen[k]then lives[k]=nil end end
        roster=c.players;return c
    end
    function self.peek_context()
        -- Native hit/death callbacks need fresh world/authority/time, not another
        -- global inventory. Target adapters still validate exact current pawns.
        if not world_id or not live(active_viewport)then return nil,'Active viewport unavailable' end
        local world=get(active_viewport,'World');local id=key(world)
        if not id or id~=world_id then return nil,'World changed since roster capture' end
        local c,why=world_context(world,id);if not c then return nil,why end
        c.players=c.authority and roster or {};return c
    end
    function self.resolve_player(object)
        local k=key(object);if not k then return nil end
        for _,p in ipairs(roster) do if k==p.pawn_key or k==p.key then return p end end
    end
    function self.mark_dead(life_id,event_world)
        if event_world~=world_id then return false end
        for _,life in pairs(lives)do if life.id==life_id then life.alive=false;return true end end
        return false
    end
    function self.is_owned_zombie(object)
        local k=key(object);return k and owned[k]~=nil or false
    end
    function self.owned_id(object)local k=key(object);return k and owned[k] and k or nil end
    function self.valid(row,c)
        if not c or c.authority~=true or c.world_id~=world_id or owned[row.id]~=row then return false,'wrong_world_or_owner' end
        -- Only the explicit, native-confirmed terminal AI corpse transition may
        -- use this path. Keep liveness polling for native early cleanup, without
        -- rereading world, controller or death properties on every corpse tick.
        if corpses[row] then
            if not live(row.actor)then return false,'actor_not_live_in_world' end
            return false,'zombie_dead'
        end
        if not belongs(row.actor,c.world)then return false,'actor_not_live_in_world' end
        local death=dead(row.actor)
        if death~=false then return false,death==true and'zombie_dead'or'death_state_unreadable' end
        if not belongs(row.controller,c.world)then return false,'controller_not_live_in_world' end
        local ok,v=call(row.actor,'GetController')
        if not ok or key(v)~=key(row.controller)then return false,'controller_changed' end
        return true
    end
    function self.mark_corpse(row,c)
        local valid,why=self.valid(row,c)
        if valid~=false or why~='zombie_dead'then return false end
        corpses[row]=true;return true
    end
    function self.position(row,c)if self.valid(row,c) then return position(row.actor) end end
    function self.destroy(row,c)
        if not c or c.authority~=true or c.world_id~=world_id then return false end
        if owned[row.id]~=row then
            -- A preceding retry_cleanup may have completed this exact row.
            -- Confirm that recorded completion without touching retired objects.
            return owned[row.id]==nil and row.cleanup_complete==true and row.world_id==world_id
        end
        -- Deferred FinishSpawningActor can create its controller before a later setup failure.
        if not row.controller and belongs(row.actor,c.world) then
            local got,pc=call(row.actor,'GetController')
            if got and owns_controller(pc,row.actor,c.world) then row.controller=pc end
        end
        row.cleanup_requested=true
        if not row.bonus_retired and type(bridge.retire)=='function'then
            local ok,retired=pcall(bridge.retire,row,c)
            if not ok or retired~=true then cleanup_failed=true;return false end
            row.bonus_retired=true
        end
        local complete=true
        for _,o in ipairs({row.actor,row.controller}) do
            if belongs(o,c.world) then
                local ok,result=call(o,'K2_DestroyActor');if not ok or result==false or live(o) then complete=false end
            end
        end
        if complete and type(bridge.unregister)=='function' then
            local ok,result=pcall(bridge.unregister,row,c)
            complete=ok and result==true
        end
        if complete then owned[row.id]=nil;corpses[row]=nil;row.cleanup_complete=true end
        cleanup_failed=false
        for _,pending in pairs(owned)do if pending.cleanup_requested then cleanup_failed=true;break end end
        return complete
    end
    function self.owned_count()
        local count=0;for _ in pairs(owned)do count=count+1 end;return count
    end
    function self.retry_cleanup(c)
        if not c or not c.authority or c.world_id~=world_id then return self.owned_count()==0 end
        local list={};for _,row in pairs(owned)do if row.cleanup_requested then list[#list+1]=row end end
        for _,row in ipairs(list)do self.destroy(row,c)end
        return not cleanup_failed
    end
    function self.cleanup_owned(c)
        if not c or not c.authority or c.world_id~=world_id then return self.owned_count()==0 end
        local list={};for _,row in pairs(owned)do list[#list+1]=row end
        for _,row in ipairs(list)do self.destroy(row,c)end
        return self.owned_count()==0
    end
    local function safe(point,origin,request,c,minimum,search_positions)
        if not point or dist2(point,origin)>request.max_distance^2 then return false end
        if dist2(point,origin)<minimum^2 then return false end
        for _,p in ipairs(c.players) do
            if p.alive and dist2(point,p.position)<minimum^2 then return false end
        end
        if search_positions then
            local points=search_positions();if not points then return false end
            for _,p in ipairs(points)do
                if dist2(point,p)<(request.spacing or 400)^2 then return false end
            end
        else
            for _,r in pairs(owned) do
                if self.valid(r,c) then local p=position(r.actor)
                    if not p or dist2(point,p)<(request.spacing or 400)^2 then return false end
                end
            end
        end
        return true
    end
    function self.spawn_point(request,c)
        local origin=vec(request.origin);if not origin then return nil end
        local min,max=request.min_distance or 0,request.max_distance
        if not finite(max) or max<=0 or max>20000 then return nil end
        -- A synchronous search can reject many candidates. Read owned spacing
        -- once, lazily, into primitive vectors; never reuse it in another search
        -- or in the fresh post-FinishSpawningActor safety check below.
        local spacing
        local function search_positions()
            if spacing==nil then
                spacing={}
                for _,r in pairs(owned)do
                    if self.valid(r,c)then
                        local p=position(r.actor)
                        if not p then spacing=false;break end
                        spacing[#spacing+1]=p
                    end
                end
            end
            return spacing
        end
        if request.try_exact and safe(vec(request.position) or origin,origin,request,c,0,search_positions) then
            return vec(request.position) or origin,{stage='death_position',min_distance=0}
        end
        local nav=find('/Script/NavigationSystem.Default__NavigationSystemV1')
        local stages={{min,max}}
        if request.kind=='environment' then stages={{min,max},{1000,8000},{600,8000},{400,8000}} end
        for i,range in ipairs(stages) do
            for _=1,16 do
                local out={};local ok,reached=call(nav,'K2_GetRandomReachablePointInRadius',c.world,origin,out,range[2],nil,nil)
                local p=ok and reached==true and vec(out)
                if p and math.abs(p.Z-origin.Z)<300 then
                    p.Z=p.Z+100
                    if safe(p,origin,request,c,range[1],search_positions) then return p,{stage='nav_'..i,min_distance=range[1]} end
                end
            end
        end
        -- Same bounded fallback order as the established mod: native starts, then ground traces.
        local fallback_min=request.kind=='environment' and 400 or min
        for _,start in ipairs(all('PlayerStart',256)) do
            if belongs(start,c.world) then local p=position(start);local tag=start_tag(start)
                local reserved=tag and(tag:lower()=='waiting'or tag:lower()=='drone')
                if not reserved and safe(p,origin,request,c,fallback_min,search_positions) and math.abs(p.Z-origin.Z)<600 then
                    return p,{stage='player_start',min_distance=fallback_min,no_nav=true,start_tag=tag,start_id=key(start)}
                end
            end
        end
        local system=find('/Script/Engine.Default__KismetSystemLibrary')
        local color={R=0,G=0,B=0,A=1};local ignore={}
        for _,p in ipairs(c.players) do ignore[#ignore+1]=p.pawn end
        for _,r in pairs(owned) do if belongs(r.actor,c.world) then ignore[#ignore+1]=r.actor end end
        for _,fraction in ipairs({0.25,0.5,0.75,1}) do for angle=0,7 do
            local radius=fallback_min+(max-fallback_min)*fraction;local a=angle*math.pi/4
            local x,y=origin.X+math.cos(a)*radius,origin.Y+math.sin(a)*radius
            local from={X=x,Y=y,Z=origin.Z+150};local to={X=x,Y=y,Z=origin.Z-700};local hit={}
            local ok,blocking=call(system,'LineTraceSingle',c.world,from,to,0,false,ignore,0,hit,true,color,color,0)
            local floor,normal=vec(get(hit,'Location')),vec(get(hit,'Normal'))
            if ok and blocking==true and get(hit,'bBlockingHit')==true and get(hit,'bStartPenetrating')==false
                and floor and normal and normal.Z>=0.5 and normal.Z<=1.01
                and math.abs(floor.X-x)<10 and math.abs(floor.Y-y)<10 and floor.Z>=to.Z and floor.Z<=from.Z then
                local p={X=x,Y=y,Z=floor.Z+100}
                if safe(p,origin,request,c,fallback_min,search_positions) then return p,{stage='ground_probe',min_distance=fallback_min,no_nav=true} end
            end
        end end
    end
    function self.spawn(request,c)
        if not c or not c.authority or c.world_id~=world_id or type(bridge.prepare_zombie)~='function'
            or type(bridge.ready)~='function' or bridge.ready()~=true then return nil,'Verified native bridge unavailable' end
        if cleanup_failed then return nil,'Owned actor cleanup remains unverified' end
        local count=0;for _ in pairs(owned)do count=count+1 end
        if count>=population_limit then return nil,'Runtime safety population limit reached' end
        local p,search=self.spawn_point(request,c);if not p then return nil,'No collision-safe spawn location' end
        local pawn,pawn_reason=load(PAWN)
        local controller,controller_reason=load(CONTROLLER)
        local pda,pda_reason=load(PDA)
        if not pawn or not controller or not pda then
            local path=not pawn and PAWN or not controller and CONTROLLER or PDA
            local reason=not pawn and pawn_reason or not controller and controller_reason or pda_reason
            return nil,'Native zombie asset unavailable: '..path..' | '..tostring(reason)
        end
        local gs=find('/Script/Engine.Default__GameplayStatics')
        local transform={Rotation={X=0,Y=0,Z=0,W=1},Translation=p,Scale3D={X=1,Y=1,Z=1}}
        local ok,actor=call(gs,'BeginDeferredActorSpawnFromClass',c.world,pawn,transform,3,nil,1)
        if not ok or not live(actor) then
            if request.try_exact then
                local fallback={};for k,v in pairs(request)do fallback[k]=v end;fallback.try_exact=false
                return self.spawn(fallback,c)
            end
            return nil,'Deferred spawn failed'..(not ok and ': '..tostring(actor):sub(1,360)or': no live actor returned')
        end
        local row={actor=actor,id=key(actor),world_id=c.world_id,spawn_position=vec(p),spawn_origin=vec(request.origin),
            spawn_stage=search.stage,spawn_start_tag=search.start_tag,spawn_start_id=search.start_id,spawned_at=c.now}
        if not row.id then call(actor,'K2_DestroyActor');return nil,'Spawn identity unavailable' end
        owned[row.id]=row
        local function reject(reason) self.destroy(row,c);return nil,reason end
        local set,initialization_error=pcall(function()
            actor.PDA_Zombie=pda;actor.AIControllerClass=controller;actor['IsSprinter?']=false;actor['Debug?']=false
            actor.Speed=request.speed;actor.ExpectedHealth=100;actor.ShouldCommunicateDeath=false
            actor.AdaptiveSpeedMinDistance=10000000;actor.AdaptiveSpeedMaxDistance=10000001
        end)
        if not set or get(actor,'ShouldCommunicateDeath')~=false then
            return reject('Native initialization failed: '..tostring(initialization_error or'ShouldCommunicateDeath readback failed'):sub(1,360))
        end
        -- Must suppress every native score/progress path before BeginPlay and bind real damage events.
        local prepared,preparation,preparation_reason=pcall(bridge.prepare_zombie,actor,c,row)
        if not prepared or preparation~=true then
            return reject('Damage/zero-score bridge rejected zombie: '..tostring(not prepared and preparation or preparation_reason or'no reason returned'):sub(1,360))
        end
        local replicated=call(actor,'SetReplicates',true);local movement=call(actor,'SetReplicateMovement',true)
        if not replicated or not movement or get(actor,'bReplicates')~=true then return reject('Replication unavailable') end
        local finished,result=call(gs,'FinishSpawningActor',actor,transform,1)
        if not finished or not live(result) or key(result)~=row.id then
            return reject('Finish spawn failed'..(not finished and ': '..tostring(result):sub(1,360)or': no matching live actor returned'))
        end
        local actual=position(actor)
        row.spawn_position=vec(actual)
        if not safe(actual,request.origin,request,c,search.min_distance) then
            -- Exclude self from the spacing check at its final collision-adjusted position.
            owned[row.id]=nil;local accepted=safe(actual,request.origin,request,c,search.min_distance);owned[row.id]=row
            if not accepted then return reject('Adjusted spawn violates spacing') end
        end
        if search.no_nav and dist2(actual,p)>100^2 then return reject('Adjusted fallback left verified floor') end
        local got,pc=call(actor,'GetController')
        if not got or not live(pc) then call(actor,'SpawnDefaultController');got,pc=call(actor,'GetController') end
        if not got or not owns_controller(pc,actor,c.world) then return reject('Owned AI controller unavailable') end
        row.controller=pc
        if type(bridge.bind_ai)~='function' then return reject('Native target ownership unavailable')end
        local bound,result,binding_reason=pcall(bridge.bind_ai,row,c)
        if not bound or result~=true then
            return reject('Native target ownership unavailable: '..tostring(not bound and result or binding_reason or'no reason returned'):sub(1,360))
        end
        -- Refreshed on valid adapter actions; active combat cannot hit a fixed lifetime limit.
        local actor_life=call(actor,'SetLifeSpan',180);local controller_life=call(pc,'SetLifeSpan',180)
        call(actor,'ForceNetUpdate')
        if actor_life and controller_life then row.lifespan_refreshed_at=c.now end
        return row
    end
    local function act(method,row,c,...)
        if not self.valid(row,c) or type(bridge[method])~='function' then return false end
        -- One context drives combat, detection and targeting synchronously. Reset
        -- the two lifetime timers once for that timestamp, not for every reader.
        if not finite(c.now)or row.lifespan_refreshed_at~=c.now then
            local actor_ok=call(row.actor,'SetLifeSpan',180);local controller_ok=call(row.controller,'SetLifeSpan',180)
            if actor_ok and controller_ok then row.lifespan_refreshed_at=c.now end
        end
        return bridge[method](row,c,...)
    end
    function self.target(row,player,speed,c,intent)return act('target',row,c,player,speed,intent) end
    function self.roam(row,settings,c)return act('roam',row,c,settings) end
    function self.perceived(row,player,c)return act('perceived',row,c,player) end
    function self.combat(row,c)return act('combat',row,c) end
    function self.diagnostics(c)
        local out={world_id=world_id,generation=generation,players={},zombies={}}
        if not c or c.authority~=true or c.world_id~=world_id or c.generation~=generation or not live(c.world)then return out end
        for _,p in ipairs(c.players or {})do
            out.players[#out.players+1]={life=p.life,alive=p.alive,position=vec(p.position),combatant_kind=p.combatant_kind}
        end
        for id,row in pairs(owned)do
            local d={id=id,spawn_stage=row.spawn_stage,spawn_position=vec(row.spawn_position),spawn_origin=vec(row.spawn_origin),
                spawn_start_tag=row.spawn_start_tag,spawn_start_id=row.spawn_start_id,spawned_at=row.spawned_at,
                cleanup_requested=row.cleanup_requested==true}
            -- Read current-world objects only; diagnostics never move or reveal actors.
            d.actor_live=belongs(row.actor,c.world);d.controller_live=belongs(row.controller,c.world)
            if d.actor_live then
                d.position=position(row.actor);d.dead=boolean(dead(row.actor));d.hidden=boolean(get(row.actor,'bHidden'))
                d.collision_enabled=boolean(get(row.actor,'bActorEnableCollision'))
                local mesh=get(row.actor,'Mesh')
                if belongs(mesh,c.world)then d.mesh_visible=boolean(get(mesh,'bVisible'));d.mesh_hidden=boolean(get(mesh,'bHiddenInGame'))end
            end
            local state=row.variant_native_ai
            if type(state)=='table'and state.world_id==world_id then
                d.patrol_at=state.patrol_at;d.patrol_result=state.patrol_result;d.patrol_target=vec(state.patrol_target)
            end
            out.zombies[#out.zombies+1]=d
        end
        return out
    end
    function self.release()owned={};corpses={};roster={};symbols={};active_viewport=nil;world_id=nil end
    return self
end
return M
