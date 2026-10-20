-- Server-only grouping of new player pawn lives. Caller owns the game-thread tick.
local Module={}
local MAX_PLAYERS,MAX_TRIES=6,8
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
    return false,'method unavailable: '..k
end
local function valid(o)local ok,v=call(o,'IsValid');return ok and v==true end
local function name(o)local ok,v=call(o,'GetFullName');return ok and type(v)=='string' and v or nil end
local function finite(n)return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function vec(v)
    local x,y,z=get(v,'X'),get(v,'Y'),get(v,'Z')
    if finite(x) and finite(y) and finite(z) then return {X=x,Y=y,Z=z} end
end
local function rotation(v)
    local p,y,r=get(v,'Pitch'),get(v,'Yaw'),get(v,'Roll')
    if finite(p) and finite(y) and finite(r) then return {Pitch=p,Yaw=y,Roll=r} end
end
local function distance(a,b)
    local x,y,z=a.X-b.X,a.Y-b.Y,a.Z-b.Z;return math.sqrt(x*x+y*y+z*z)
end
local function belongs(o,w)
    if not valid(o) then return false end
    local ok,world=call(o,'GetWorld');return ok and valid(world) and name(world)==name(w)
end
local function is_dead(pawn)
    local d=get(get(pawn,'WW_SurvivorStatus'),'Death?')
    if type(d)=='boolean' then return d end
    local out={};local ok=call(pawn,'IsDead',out)
    if ok and type(out['Dead?'])=='boolean' then return out['Dead?'] end
end
function Module.new(core,api,options)
    api,options=api or {},options or {}
    local self={};local enabled,closed=false,false
    local find_all=api.FindAllOf or FindAllOf
    local find_object=api.StaticFindObject or StaticFindObject
    local lives={};local round_key,world_key
    local report={version='0.1.0',phase='IDLE',max_players=MAX_PLAYERS,max_attempts=MAX_TRIES,
        moved=0,already_near=0,failed=0,pending=0,players={}}
    local function note(reason)
        report.reason=reason
        if options.log then pcall(options.log,'Group spawn: '..reason) end
        return false,reason
    end
    local function find(path)
        if type(find_object)~='function' then return nil end
        local ok,v=pcall(find_object,path);if ok and valid(v) then return v end
    end
    local nav
    local function current_world()
        if type(find_all)~='function' then return nil end
        local ok,list=pcall(find_all,'GameViewportClient')
        if ok and type(list)=='table' then
            for i,vp in ipairs(list) do
                if i>8 then break end
                local world=get(vp,'World');if valid(world) then return world end
            end
        end
    end
    local function authority(world)
        if not valid(world) or not valid(get(world,'AuthorityGameMode')) then return false end
        local ok,driver=pcall(function()return world.NetDriver end)
        if not ok then return false end
        if valid(driver) then
            local read,server=pcall(function()return driver.ServerConnection end)
            if not read or valid(server) then return false end
        end
        local active=current_world();return active~=nil and name(active)==name(world)
    end
    local function capsule(pawn)
        local c=get(pawn,'CapsuleComponent')
        local h_ok,h=call(c,'GetScaledCapsuleHalfHeight')
        local r_ok,r=call(c,'GetScaledCapsuleRadius')
        if h_ok and r_ok and finite(h) and finite(r) and h>=30 and h<=200 and r>=10 and r<=150 then
            return h,r
        end
    end
    local function player(row,world)
        if type(row)~='table' or type(row.key)~='string' or row.key=='' or row.alive~=true
            or row.eliminated==true or row.connected==false then return nil end
        local pc,pawn=row.controller,row.pawn
        if not belongs(pc,world) or not belongs(pawn,world) or is_dead(pawn)~=false then return nil end
        local pa,p=call(pawn,'HasAuthority');local ca,c=call(pc,'HasAuthority')
        if not pa or p~=true or not ca or c~=true or name(get(pc,'Pawn'))~=name(pawn) then return nil end
        local ok,pos=call(pawn,'K2_GetActorLocation');pos=ok and vec(pos)
        local h,r=capsule(pawn)
        if not pos or not h then return nil end
        local pn=name(pawn);if not pn then return nil end
        return {key=row.key,controller=pc,pawn=pawn,pawn_name=pn,position=pos,half_height=h,radius=r}
    end
    local function zombies(world)
        if type(find_all)~='function' then return nil end
        local ok,objects=pcall(find_all,'Zombie_C')
        if not ok or (objects~=nil and type(objects)~='table') then return nil end
        local result={}
        for i,z in ipairs(objects or {}) do
            if i>64 then return nil end
            if belongs(z,world) then
                local got,p=call(z,'K2_GetActorLocation');p=got and vec(p)
                if not p then return nil end
                result[#result+1]=p
            end
        end
        return result
    end
    local function spaced(point,target,players,npcs)
        for _,p in ipairs(players) do
            if p.key~=target.key and distance(point,p.position)<math.max(200,target.radius+p.radius+30) then return false end
        end
        for _,p in ipairs(npcs) do if distance(point,p)<200 then return false end end
        return true
    end
    local function public(life)
        report.players[life.key]={pawn=life.pawn_name,attempts=life.attempts,done=life.done==true,
            moved=life.moved==true,reason=life.reason,failed=life.failed==true}
    end
    local function complete(life,reason,moved)
        life.done=true;life.reason=reason;life.moved=moved==true
        if moved then report.moved=report.moved+1
        elseif reason=='Already within six metres' then report.already_near=report.already_near+1 end
        public(life)
    end
    local function attempt(target,anchor,players,npcs,world,life)
        life.attempts=life.attempts+1
        local origin={X=anchor.position.X,Y=anchor.position.Y,Z=anchor.position.Z-anchor.half_height}
        local out={}
        local ok,reached=call(nav,'K2_GetRandomReachablePointInRadius',world,origin,out,800,nil,nil)
        local point=ok and reached==true and vec(out)
        if not point then life.reason='No reachable group spawn point';public(life);return end
        local projected={}
        local read,accepted=call(nav,'K2_ProjectPointToNavigation',world,point,projected,nil,nil,{X=80,Y=80,Z=200})
        point=read and accepted==true and vec(projected)
        if not point then life.reason='Group spawn navmesh projection failed';public(life);return end
        point.Z=point.Z+target.half_height+2
        local gap=distance(point,anchor.position)
        if gap<300 or gap>800 or math.abs(point.Z-anchor.position.Z)>250
            or not spaced(point,target,players,npcs) then
            life.reason='Group spawn point is too close or outside the safe range';public(life);return
        end
        local got,rot=call(target.pawn,'K2_GetActorRotation');rot=got and rotation(rot)
        if not rot then life.reason='Player rotation is unreadable';public(life);return end
        -- Recheck authority and life immediately before the only intended movement.
        if not authority(world) or is_dead(target.pawn)~=false then
            life.reason='Player or world changed before teleport';public(life);return
        end
        local moved,result=call(target.pawn,'K2_TeleportTo',point,rot)
        if not moved or result~=true then life.reason='Collision-checked group teleport refused';public(life);return end
        local located,actual=call(target.pawn,'K2_GetActorLocation');actual=located and vec(actual)
        if not actual or distance(actual,anchor.position)<300 or distance(actual,anchor.position)>800
            or not spaced(actual,target,players,npcs) then
            -- A collision adjustment must not leave the pawn in an unsafe position.
            local rolled,restored=call(target.pawn,'K2_TeleportTo',target.position,rot)
            local verified,back=call(target.pawn,'K2_GetActorLocation');back=verified and vec(back)
            restored=rolled and restored==true and back~=nil and distance(back,target.position)<=10
            call(target.pawn,'ForceNetUpdate')
            life.failed=true;report.failed=report.failed+1
            complete(life,restored and 'Unsafe collision adjustment; original position restored'
                or 'Unsafe collision adjustment; position restoration failed',false)
            return
        end
        target.position=actual;call(target.pawn,'ForceNetUpdate')
        complete(life,'Grouped near a living teammate',true)
    end
    function self.start()
        if closed then return note('Grouping adapter is shut down') end
        if type(core)~='table' or type(core.get_players)~='function' or type(find_all)~='function'
            or type(find_object)~='function' then return note('Required grouping APIs are unavailable') end
        nav=find('/Script/NavigationSystem.Default__NavigationSystemV1')
        enabled=true;report.phase='READY';return true
    end
    function self.tick(status,world)
        if not enabled or closed then return false,'Grouping adapter is not active' end
        if type(status)~='table' or (status.phase~='PREMATCH' and status.phase~='RUNNING') or status.mode_name~='Z-Deathmatch' then
            report.phase='WAITING';report.pending=0;return true
        end
        if not authority(world) then return note('Grouping requires the current authoritative host world') end
        local wn=name(world)
        local origin=status.prematch_started_at or status.started_at
        local rk=finite(origin) and tostring(origin) or nil
        if not rk then return note('Round identity is unavailable') end
        rk=wn..'|'..rk
        if round_key~=rk or world_key~=wn then
            lives={};round_key=rk;world_key=wn
            report.players={};report.moved=0;report.already_near=0;report.failed=0;report.world=wn;report.round=rk
        end
        if not valid(nav) then nav=find('/Script/NavigationSystem.Default__NavigationSystemV1') end
        if not valid(nav) then return note('Native navigation library is unavailable') end
        local read,roster=pcall(core.get_players)
        if not read or type(roster)~='table' or #roster>MAX_PLAYERS then return note('Bounded player roster is unavailable') end
        local players,connected={},{}
        for i,row in ipairs(roster) do
            if i>MAX_PLAYERS then return note('Player roster exceeds six') end
            if type(row)=='table' and type(row.key)=='string' then connected[row.key]=true end
            local p=player(row,world)
            if p then
                players[#players+1]=p
                if not lives[p.key] or lives[p.key].pawn_name~=p.pawn_name then
                    lives[p.key]={key=p.key,pawn_name=p.pawn_name,attempts=0}
                end
            end
        end
        for key in pairs(lives) do if not connected[key] then lives[key]=nil;report.players[key]=nil end end
        report.phase=status.phase;report.reason=nil;report.pending=0
        if #players==0 then report.reason='Waiting for living player pawns';return true end
        local anchor
        -- Prefer an established living host. A newly respawned host joins an established teammate.
        local got,host=pcall(function()return core.get_controller and core.get_controller()end)
        local host_name=got and name(host)
        for _,p in ipairs(players) do
            local life=lives[p.key]
            if life.done and not life.failed and (not anchor or name(p.controller)==host_name) then anchor=p end
        end
        if not anchor then
            for _,p in ipairs(players) do if not anchor or name(p.controller)==host_name then anchor=p end end
            complete(lives[anchor.key],'Initial living group anchor',false)
        end
        local npcs
        for _,p in ipairs(players) do
            local life=lives[p.key]
            if not life.done and p.key~=anchor.key then
                if distance(p.position,anchor.position)<=600 then complete(life,'Already within six metres',false)
                elseif life.attempts>=MAX_TRIES then
                    life.failed=true;report.failed=report.failed+1;complete(life,'Eight safe grouping attempts exhausted',false)
                else
                    if npcs==nil then npcs=zombies(world) end
                    if npcs==nil then
                        life.attempts=life.attempts+1;life.reason='Nearby zombie positions are not safely readable';public(life)
                    else attempt(p,anchor,players,npcs,world,life) end
                    if not life.done then report.pending=report.pending+1 end
                end
            end
            public(life)
        end
        return true
    end
    function self.shutdown()
        enabled=false;closed=true;lives={};report.phase='SHUTDOWN';report.pending=0;return true
    end
    function self.status()return report end
    return self
end
return Module
