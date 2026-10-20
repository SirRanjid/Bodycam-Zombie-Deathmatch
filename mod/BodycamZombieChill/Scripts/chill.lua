-- BodycamZombieChill: bounded host-authoritative 300-second zombie competition.
-- All entrypoints and timers run on the game thread. One exact health-death hook.
local Module={}
local VERSION='0.2.2'
local source_info=debug.getinfo(1,'S').source
local SCRIPT_DIR=source_info:sub(1,1)=='@' and source_info:sub(2):match('^(.*[/\\])') or nil
local SETTINGS={duration_seconds=300,prematch_seconds=30,min_active=10,max_active=42,max_players=6,zombies_per_player=7,spawn_interval=2,
    min_player_distance=1800,max_spawn_distance=3200,zombie_speed=125,zombie_run_speed=375,fast_run_speed=450,fast_runner_percent=25,
    runner_percent=80,run_delay_min_seconds=1,run_delay_max_seconds=4,aggression_percent=80,
    sight_range_multiplier=1.8,lose_sight_range_multiplier=1.8,zombie_health=100,death_penalty=5}
local SCORE_RULES={kill_points=1,death_penalty=5,pvp_penalty=5,death_policy='positive_only',pvp_can_be_negative=true,
    eliminate_at=-15,elimination_enabled=true,interpretation_pending=false,
    virtual_opponent='Puppetmaster',virtual_player_kill_points=5,virtual_zombie_death_penalty=0}
local PUPPET_KEY='puppetmaster'
local DEATH_PATH='/Game/AdvancedLocomotionV4/Blueprints/Components/WW_SurvivorStatus.WW_SurvivorStatus_C:K2_OnOutofHealth'
local ASSETS={
    pawn='/Game/BodycamZombies/ZombieAI/BP_NormalZombie.BP_NormalZombie_C',
    controller='/Game/BodycamZombies/ZombieAI/AIC_Zombie.AIC_Zombie_C',
    pda='/Game/GM/Zombie/Gamemode/PDA/cemeteryZombies.cemeteryZombies',
}
local function get(o,k)
    if o==nil then return nil end
    local ok,v=pcall(function()return o[k]end)
    if ok then return v end
end
local function call(o,k,...)
    if o==nil then return false,'missing receiver' end
    local args=table.pack(...)
    local got,member=pcall(function()return o[k]end)
    if got and member~=nil then
        -- A real call failure must not retry a mutating UFunction.
        return pcall(member,o,table.unpack(args,1,args.n))
    end
    local read,mt=pcall(getmetatable,o)
    local fn=read and type(mt)=='table' and rawget(mt,k)
    if type(fn)=='function' then return pcall(fn,o,table.unpack(args,1,args.n)) end
    return false,tostring(member or 'method unavailable'):sub(1,240)
end
local function valid(o)local ok,v=call(o,'IsValid');return ok and v==true end
local function same_object(a,b)
    if a==nil or b==nil then return false end
    if a==b then return true end
    local got,x=call(a,'GetAddress');local read,y=call(b,'GetAddress')
    return got and read and type(x)=='number'and x>0 and x==y
end
local function name(o)local ok,v=call(o,'GetFullName');return ok and type(v)=='string' and v or nil end
local function unwrap(v)
    if v==nil or type(v)=='boolean' or type(v)=='number' or type(v)=='string' then return v end
    local ok,result=call(v,'get');if ok then return result end
    return v
end
local function display_name(s)
    s=(type(s)=='string' and s or 'Player'):gsub('[%z\1-\31\127]','')
    local ok,result=pcall(function()
        local out={}
        for _,cp in utf8.codes(s) do out[#out+1]=utf8.char(cp);if #out>=64 then break end end
        return table.concat(out)
    end)
    return ok and result or s:gsub('[\128-\255]','?'):sub(1,64)
end
local function text_string(value)
    if type(value)=='string'then return value end
    local ok,s=call(value,'ToString')
    if ok and type(s)=='string'then return s end
end
local function finite(n)return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function vec(v)
    local x,y,z=get(v,'X'),get(v,'Y'),get(v,'Z')
    if finite(x) and finite(y) and finite(z) then return {X=x,Y=y,Z=z} end
end
local function class_is(o,short)
    local ok,c=call(o,'GetClass');local seen={}
    for _=1,12 do
        local n=ok and name(c)
        if not n or seen[n] then return false end
        if n:match('([^./: ]+)$')==short then return true end
        seen[n]=true;ok,c=call(c,'GetSuperStruct')
    end
    return false
end
local function reflected_field(o,wanted)
    local ok,c=call(o,'GetClass');local seen={}
    for _=1,12 do
        local cn=ok and name(c)
        if not cn or seen[cn] then break end
        seen[cn]=true
        local found,count=nil,0
        local read=call(c,'ForEachProperty',function(p)
            count=count+1;if count>128 then return true end
            local got,n=call(p,'GetFName')
            if got and type(n)~='string' then local converted,s=call(n,'ToString');n=converted and s or nil end
            local full=name(p) or ''
            if type(n)~='string' then n=full:match('([^:]+)$') end
            if n and n:lower()==wanted then
                local typ=full:match('^(%w+) ')
                if typ=='ByteProperty' or typ=='EnumProperty' then found=n end
                return true
            end
        end)
        if found then return found end
        if not read then return nil,'GameInstance property reflection unavailable' end
        ok,c=call(c,'GetSuperStruct')
    end
    return nil,'GameInstance GameMode enum property was not reflected'
end
local function dead(o)
    local status=get(o,'WW_SurvivorStatus')
    local d=get(status,'Death?')
    if type(d)=='boolean' then return d end
    local out={}
    local ok=call(o,'IsDead',out)
    if ok and type(out['Dead?'])=='boolean' then return out['Dead?'] end
    return nil
end
function Module.new(api,options)
    options=options or {}
    local self={};local loaded={};local owned={};local owned_by_name={};local session
    local generation=0;local hooks={};local controls;local current_roster={};local elimination_handler=options.eliminate_player
    local cleanup_timer;local cleanup_token=0;local cleanup_attempts=0
    local prematch;local begin_session
    local elimination_reset=options.reset_eliminated_players
    local cleanup_failure_latched=false
    local participants,known_controllers,player_lives={},{},{}
    local puppet={enabled=false,kills=0,deaths=0,points=0,round_generation=0}
    local virtual_state;local owned_killer
    local register_hook=api.RegisterHook or RegisterHook
    local unregister_hook=api.UnregisterHook or UnregisterHook
    local status={version=VERSION,phase='IDLE',duration_seconds=SETTINGS.duration_seconds,max_active=SETTINGS.max_active,
        settings=SETTINGS,scoreboard={},spawned=0,kills=0,uncredited=0,active=0,assets={},
        game_thread_only=true,hosting_verified=false,scoring_verified=false,mode_name='Z-Deathmatch',score_rules=SCORE_RULES}
    status.capabilities={register_hook=type(register_hook)=='function',unregister_hook=type(unregister_hook)=='function',
        register_hook_source=api.RegisterHook and 'api' or (RegisterHook and 'mod_global' or 'unavailable'),
        unregister_hook_source=api.UnregisterHook and 'api' or (UnregisterHook and 'mod_global' or 'unavailable')}
    local function puppet_snapshot()
        return {key=PUPPET_KEY,name='Puppetmaster',virtual=true,bot=true,kills=puppet.kills,deaths=puppet.deaths,
            points=puppet.points,eligible=true,connected=true,eliminated=false,round_generation=puppet.round_generation,
            world=status.world,active=puppet.enabled and status.phase=='RUNNING',native_display_verified=false}
    end
    local function publish_scoreboard()
        local rows={};for key,row in pairs(participants)do rows[key]=row end
        if puppet.enabled then rows[PUPPET_KEY]=puppet_snapshot()end
        status.scoreboard=rows;status.puppetmaster=puppet_snapshot()
    end
    local function reset_puppet(enabled)
        puppet={enabled=enabled==true,kills=0,deaths=0,points=0,round_generation=generation}
        publish_scoreboard()
    end
    local function refresh_target()
        local eligible=0
        for _,p in ipairs(current_roster)do
            local score=participants[p.key]
            if p.connected~=false and not(score and score.eliminated)then eligible=eligible+1 end
        end
        status.eligible_connected_players=eligible
        if status.phase=='SMOKE_TEST'then status.target_active=1
        elseif status.phase=='PREMATCH'or status.phase=='RUNNING'then
            status.target_active=eligible>0 and math.min(SETTINGS.max_active,math.max(SETTINGS.min_active,eligible*SETTINGS.zombies_per_player))or 0
        else status.target_active=0 end
    end
    local function virtual_state_matches(state)
        if not virtual_state or not valid(state)then return false end
        if virtual_state.object==state then return true end
        local ok,address=call(state,'GetAddress')
        return ok and type(address)=='number'and address>0 and address==virtual_state.address
    end
    local function write()
        refresh_target()
        publish_scoreboard()
        if options.status then pcall(options.status,status) end
    end
    local function log(message)if options.log then pcall(options.log,message) end end
    local function issue(reason)
        status.reason=reason;write();log(reason)
        return false,reason
    end
    local function find(path)
        if type(api.StaticFindObject)~='function' then return nil end
        local ok,v=pcall(api.StaticFindObject,path)
        return ok and valid(v) and v or nil
    end
    local gs=find('/Script/Engine.Default__GameplayStatics')
    local nav=find('/Script/NavigationSystem.Default__NavigationSystemV1')
    local function object_info(o)
        local r={valid=valid(o)}
        if r.valid then local ok,c=call(o,'GetClass');r.object=name(o);r.class=ok and name(c) or nil end
        return r
    end
    local function read_info(o,k)
        local ok,v=pcall(function()return o[k]end)
        local r={read_ok=ok,type=ok and type(v) or nil}
        if ok and (type(v)=='number' or type(v)=='boolean' or type(v)=='string') then r.value=v
        elseif not ok then r.error=tostring(v):sub(1,240) end
        return r,ok and v or nil
    end
    local function call_info(o,k,...)
        local ok,v=call(o,k,...)
        local r={read_ok=ok,type=ok and type(v) or nil}
        if ok and (type(v)=='number' or type(v)=='boolean' or type(v)=='string') then r.value=v
        elseif not ok then r.error=tostring(v):sub(1,240) end
        return r,ok and v or nil
    end
    local function count_valid(n)return finite(n) and n>=0 and n<=256 and n%1==0 end
    local function array_info(a)
        local r={lua_type=type(a)}
        local rt_ok,rt=call(a,'type');if rt_ok and type(rt)=='string' then r.runtime_type=rt end
        local ok,n=call(a,'GetArrayNum');r.read_ok=ok and count_valid(n)
        if r.read_ok then r.count=n else r.error=ok and 'Invalid array count' or tostring(n):sub(1,240) end
        return r,r.read_ok and n or nil
    end
    local function count_players(world,gm)
        local details={}
        local native,n=call_info(gs,'GetNumPlayerControllers',world);details.native=native
        local local_info,locals=call_info(gs,'GetNumLocalPlayerControllers',world);details.local_controllers=local_info
        local got,state=call(gs,'GetGameState',world)
        if not got or not valid(state) then state=get(world,'GameState') end
        details.game_state=object_info(state)
        local state_array,state_count=array_info(get(state,'PlayerArray'));details.player_array=state_array
        local raw,old=read_info(gm,'NumPlayers');details.gamemode_numplayers=raw
        if native.read_ok and count_valid(n) then
            if local_info.read_ok and count_valid(locals) and (locals<1 or locals>SETTINGS.max_players or n<locals) then
                details.error='Native total/local controller counts are inconsistent';return nil,nil,details
            end
            return n,'GameplayStatics.GetNumPlayerControllers',details
        elseif state_count~=nil then
            if virtual_state and virtual_state.world==name(world)then
                if state_count>SETTINGS.max_players+1 then return state_count,'GameState.PlayerArray',details end
                local seen,excluded,invalid=0,0,false
                local enumerated=call(get(state,'PlayerArray'),'ForEach',function(_,value)
                    seen=seen+1
                    if seen>SETTINGS.max_players+1 then invalid=true;return true end
                    local object=unwrap(value)
                    if not valid(object)then invalid=true;return true end
                    if virtual_state_matches(object)then excluded=excluded+1 end
                end)
                if not enumerated or invalid or seen~=state_count or excluded>1 then
                    details.error='The owned virtual PlayerState could not be safely excluded';return nil,nil,details
                end
                details.player_array.owned_virtual_excluded=excluded
                return state_count-excluded,'GameState.PlayerArray',details
            end
            return state_count,'GameState.PlayerArray',details
        elseif raw.read_ok and count_valid(old) then return old,'GameMode.NumPlayers',details end
        details.error='Player count is unavailable from native, GameState and GameMode sources'
        return nil,nil,details
    end
    local function network_info(world)
        local details={}
        local read,driver=read_info(world,'NetDriver');details.netdriver_read=read;details.netdriver=object_info(driver)
        if not read.read_ok then details.error='Network driver is unreadable';return false,details end
        if not valid(driver) then details.permitted=true;details.standalone=true;return true,details end
        local sr,server=read_info(driver,'ServerConnection');details.server_connection_read=sr;details.server_connection=object_info(server)
        if not sr.read_ok then details.error='Server connection is unreadable';return false,details end
        if valid(server) then details.error='Remote client worlds are refused';return false,details end
        local cr,connections=read_info(driver,'ClientConnections');details.client_connections_read=cr
        local array,count=array_info(connections);details.client_connections=array
        if not cr.read_ok or count==nil or count>SETTINGS.max_players-1 then
            details.error='Network peers exceed the limit or are not safely countable'
            details.roster_transition=true
            return false,details
        end
        details.peer_count=count
        details.permitted=true;return true,details
    end
    local function current_world()
        local ok,vps=pcall(api.FindAllOf,'GameViewportClient')
        if not ok or type(vps)~='table' then return nil,'Viewport unavailable' end
        for _,vp in ipairs(vps) do local world=get(vp,'World');if valid(world) then return world end end
        return nil,'No active world'
    end
    local function world_now(world)
        local ok,n=call(gs,'GetRealTimeSeconds',world)
        if ok and finite(n) then return n end
    end
    -- Opaque round-local identities survive leave/rejoin with a new PlayerState.
    -- Platform identifiers stay inside these tables, never in status or log data.
    local participant_key_by_platform,participant_key_by_state={},{}
    local participant_identity_count=0
    local function participant_identity(state)
        local state_name=name(state)
        if not state_name then return nil,'PlayerState identity is unreadable' end
        local known=participant_key_by_state[state_name]
        local got,platform=call(state,'GetPlatformId')
        if got and type(platform)~='string' then
            local converted,value=call(platform,'ToString')
            if converted then platform=value end
        end
        if got and type(platform)=='string' and platform:find('%S') then
            local key=participant_key_by_platform[platform]
            if not key then
                participant_identity_count=participant_identity_count+1
                key='participant-'..tostring(participant_identity_count)
                participant_key_by_platform[platform]=key
            end
            participant_key_by_state[state_name]=key
            return key
        end
        if known then return known end
        if got then return nil,'Player platform identity is not ready' end
        -- Compatibility for local runtimes/mocks without this native method.
        participant_key_by_state[state_name]=state_name
        return state_name
    end
    function self.reset_participant_identities(seed_players)
        participant_key_by_platform={};participant_key_by_state={};participant_identity_count=0
        for _,p in ipairs(seed_players or {}) do
            local key,why=participant_identity(p.player_state)
            if not key then return false,why end
            p.key=key
        end
        return true
    end
    local function participant(pc,index)
        local state=get(pc,'PlayerState')
        if not valid(state) then return nil,'PlayerState is not ready' end
        if virtual_state_matches(state)then return nil,'The virtual opponent cannot occupy a human controller slot'end
        local key,identity_error=participant_identity(state);if not key then return nil,identity_error end
        local got,n=call(state,'GetBodycamPlayerName')
        n=got and text_string(n)or nil
        if not n or not n:find('%S')then
            got,n=call(state,'GetPlayerName');n=got and text_string(n)or nil
        end
        local id_ok,id=call(state,'GetPlayerId')
        local pawn=get(pc,'Pawn');local alive,position=false,nil
        if valid(pawn) and class_is(pawn,'Bodycam_Player_C') then
            local d=dead(pawn)
            if d==nil then return nil,'Player death state is unreadable' end
            alive=not d
            if alive then
                local located,p=call(pawn,'K2_GetActorLocation');position=located and vec(p)
                if not position then return nil,'Player position is unreadable' end
            end
        end
        return {key=key,controller=pc,controller_name=name(pc),player_state=state,
            name=display_name(n and n:find('%S')and n or ('Player '..tostring(index+1))),
            player_id=id_ok and finite(id) and id or nil,pawn=pawn,pawn_name=name(pawn),alive=alive,position=position}
    end
    local function apply_points(key,delta,kind)
        local p=participants[key]
        if not p or p.eliminated then return false end
        local previous=p.points
        if kind=='player_death' then
            if p.points>0 then p.points=math.max(0,p.points-SCORE_RULES.death_penalty) end
        else p.points=p.points+delta end
        status.last_score_event={type=kind,player=key,points=p.points,delta=p.points-previous}
        if SCORE_RULES.elimination_enabled and p.points<=SCORE_RULES.eliminate_at then
            p.eliminated=true;p.alive=false
            local ref
            for _,candidate in ipairs(current_roster) do if candidate.key==key then ref=candidate;break end end
            if ref and ref.pawn_name then
                local life=player_lives[ref.pawn_name]
                if life then life.suppress_penalty=true end
                p.spectated_pawn=ref.pawn_name
            end
            local ok,result=false,false
            if type(elimination_handler)=='function' and ref then ok,result=pcall(elimination_handler,ref) end
            p.spectator_transition=ok and result~=false
            if not p.spectator_transition then
                status.elimination_error='The required spectator transition failed'
                self.stop(status.elimination_error)
            end
        end
        write();return true
    end
    local function player_penalty(key,pawn_name,instigator,death_event,killer_resolver)
        if not session or not session.scoring or status.phase~='RUNNING' then return false end
        local now=world_now(session.world)
        if not now or now>=session.deadline or now<session.started_at then return false end
        local life=player_lives[pawn_name];local p=participants[key]
        if not life or life.generation~=session.generation or life.suppress_penalty or not p or p.eliminated then return false end
        if not life.penalized then
            life.penalized=true;p.deaths=p.deaths+1
            apply_points(key,-SCORE_RULES.death_penalty,'player_death')
        end
        if death_event and not life.pvp_finalized then
            life.pvp_finalized=true
            if owned_killer and owned_killer(instigator)then
                life.puppetmaster_credited=true;puppet.kills=puppet.kills+1;puppet.points=puppet.points+SCORE_RULES.virtual_player_kill_points
                status.last_score_event={type='zombie_player_kill',player=PUPPET_KEY,victim=key,points=puppet.points,delta=SCORE_RULES.virtual_player_kill_points}
            else
                local killer=type(killer_resolver)=='function' and killer_resolver(instigator) or nil
                if killer and killer~=key then life.pvp_killer=killer;apply_points(killer,-SCORE_RULES.pvp_penalty,'player_kill')end
            end
        end
        write();return true
    end
    local function sync_roster(players)
        current_roster=players
        for _,p in pairs(participants) do p.connected=false;p.alive=false end
        status.players={}
        for _,p in ipairs(players) do
            status.players[p.key]={name=p.name,player_id=p.player_id,pawn=p.pawn_name,alive=p.alive,controller=p.controller_name}
            if session then
                local score=participants[p.key]
                if not score then
                    score={name=p.name,player_id=p.player_id,kills=0,deaths=0,points=0}
                    participants[p.key]=score
                end
                score.name=p.name;score.connected=true;score.alive=p.alive and not score.eliminated;score.pawn=p.pawn_name
                known_controllers[p.controller_name]=p.key
                if valid(p.pawn) and p.pawn_name then
                    local life=player_lives[p.pawn_name]
                    if not life then
                        life={key=p.key,generation=session.generation,seen_alive=p.alive,penalized=false};player_lives[p.pawn_name]=life
                    end
                    if score.eliminated and class_is(p.pawn,'Bodycam_Player_C') and score.spectated_pawn~=p.pawn_name then
                        life.suppress_penalty=true;score.spectated_pawn=p.pawn_name
                        local ok,result=false,false
                        if type(elimination_handler)=='function' then ok,result=pcall(elimination_handler,p) end
                        score.spectator_transition=ok and result~=false
                        if not score.spectator_transition then status.elimination_error='Eliminated player could not remain a spectator';self.stop(status.elimination_error);return end
                    end
                    if p.alive then life.seen_alive=true
                    elseif life.seen_alive then player_penalty(p.key,p.pawn_name) end
                end
            end
        end
        refresh_target();publish_scoreboard()
    end
    local function context()
        if not valid(gs) then gs=find('/Script/Engine.Default__GameplayStatics') end
        if not valid(nav) then nav=find('/Script/NavigationSystem.Default__NavigationSystemV1') end
        if not valid(gs) then return nil,'Native gameplay library unavailable' end
        local world,world_error=current_world()
        if not world then return nil,world_error end
        local wn=name(world) or ''
        if wn:lower():find('/lobby',1,true) or wn:lower():find('mainmenu',1,true) then
            return nil,'Enter a local playable training map first'
        end
        if wn:lower():find('transition',1,true) then return nil,'Waiting for the gameplay map to finish loading','transient' end
        local gm=get(world,'AuthorityGameMode')
        if not valid(gm) then return nil,'Local server authority is required' end
        local players,source,counts=count_players(world,gm);status.player_count=players;status.player_count_source=source;status.player_counts=counts
        if players==nil or players<1 then return nil,'Player controllers are not ready','transient' end
        if players>SETTINGS.max_players then return nil,'At most six players are supported',session and 'transient' or nil end
        local permitted,network=network_info(world);status.network=network
        if not permitted then return nil,network.error,session and network.roster_transition and 'transient' or nil end
        local now=world_now(world)
        if not now then return nil,'World clock is unreadable' end
        local roster,alive,host={},{},nil
        local controller_names={}
        for index=0,players-1 do
            local got,pc=call(gs,'GetPlayerController',world,index)
            if not got or not valid(pc) or controller_names[name(pc) or ''] then return nil,'Player roster is changing','transient' end
            controller_names[name(pc) or '']=true
            local authority,a=call(pc,'HasAuthority')
            if not authority or a~=true then return nil,'Only the authoritative host may spawn zombies' end
            local local_pc,l=call(pc,'IsLocalController');if local_pc and l==true then host=host or pc end
            local p,why=participant(pc,index);if not p then return nil,why,'transient' end
            if valid(p.pawn) and p.alive and not (session and participants[p.key] and participants[p.key].eliminated) then
                local controlled,is_player=call(p.pawn,'IsPlayerControlled')
                if not controlled or is_player~=true then return nil,'Player pawn control is unreadable','transient' end
                alive[#alive+1]=p
            end
            roster[#roster+1]=p
        end
        if not host then return nil,'A local authoritative host controller is required' end
        sync_roster(roster)
        local anchor=alive[1]
        return {world=world,world_name=wn,host_controller=host,players=roster,alive_players=alive,
            player=anchor and anchor.pawn,player_name=anchor and anchor.pawn_name,position=anchor and anchor.position,now=now}
    end
    local function load_assets()
        if type(api.LoadAsset)~='function' then return false,'LoadAsset unavailable' end
        for k,path in pairs(ASSETS) do
            if not valid(loaded[k]) then
                loaded[k]=find(path)
                if not valid(loaded[k]) then
                    local ok,v=pcall(api.LoadAsset,path)
                    if ok and valid(v) then loaded[k]=v end
                end
            end
            status.assets[k]={path=path,loaded=valid(loaded[k])}
            if not valid(loaded[k]) then return false,'Required local asset unavailable: '..k end
        end
        return true
    end
    local function spawn_point(c)
        local alive=c.alive_players or {}
        if #alive==0 then return nil end
        local index=session and ((session.spawn_cursor or 0)%#alive)+1 or 1
        local origin=alive[index].position
        if session then session.spawn_cursor=(session.spawn_cursor or 0)+1 end
        local stages={{SETTINGS.min_player_distance,SETTINGS.max_spawn_distance},{1000,5000},{600,6500},{400,8000}}
        for stage,range in ipairs(stages) do
            status.spawn_search={stage=stage,min_distance_metres=range[1]/100,
                max_distance_metres=range[2]/100,relaxed=stage>1,attempts=0}
            for attempt=1,32 do
                status.spawn_search.attempts=attempt
                local out={}
                local ok,reachable=call(nav,'K2_GetRandomReachablePointInRadius',c.world,origin,out,range[2],nil,nil)
                local point=ok and reachable==true and vec(out)
                if point then
                    local dx,dy,dz=point.X-origin.X,point.Y-origin.Y,point.Z-origin.Z
                    local distance=math.sqrt(dx*dx+dy*dy)
                    if distance>=range[1] and distance<=range[2] and math.abs(dz)<300 then
                        local spaced=true
                        for _,p in ipairs(alive) do
                            local x,y,z=point.X-p.position.X,point.Y-p.position.Y,point.Z-p.position.Z
                            if x*x+y*y+z*z<range[1]^2 then spaced=false;break end
                        end
                        for _,entry in ipairs(owned) do
                            if spaced and valid(entry.actor) and dead(entry.actor)~=true then
                                local read,other=call(entry.actor,'K2_GetActorLocation');other=read and vec(other)
                                if not other then spaced=false;break end
                                local x,y=other.X-point.X,other.Y-point.Y
                                if x*x+y*y<400*400 then spaced=false;break end
                            end
                        end
                        if spaced then
                            point.Z=point.Z+100
                            return point,{min_distance=range[1],max_distance=range[2],stage=stage,relaxed=stage>1}
                        end
                    end
                end
            end
        end
        -- Only after all reachable-nav queries fail, consider native spawn points
        -- and collision-tested ground. These remain host-owned actor spawns.
        local function identical(a,b)
            if not valid(a) or not valid(b) then return false end
            if rawequal(a,b) then return true end
            local aa,av=call(a,'GetAddress');local ba,bv=call(b,'GetAddress')
            return aa and ba and type(av)=='number' and av~=0 and av==bv
        end
        local function unwrap(v)local ok,value=call(v,'get');return ok and value or v end
        local function belongs(actor)
            if not valid(actor) then return false end
            local n=name(actor) or ''
            if n:find('Default__',1,true) or n:find('Archetype',1,true) then return false end
            local ok,w=call(actor,'GetWorld');if ok and identical(w,c.world) then return true end
            local got,level=call(actor,'GetLevel');if not got or not valid(level) then return false end
            if identical(get(level,'OwningWorld'),c.world) then return true end
            local array=get(c.world,'Levels');local counted,count=call(array,'GetArrayNum')
            if not counted or not finite(count) or count<0 or count>512 or count%1~=0 then return false end
            local found,visited=false,0
            local iterated=call(array,'ForEach',function(_,element)
                visited=visited+1
                if identical(unwrap(element),level) then found=true;return true end
                return visited>=count
            end)
            if iterated then return found end
            for i=1,count do if identical(unwrap(get(array,i)),level) then return true end end
            return false
        end
        local function safe_center(point)
            local dx,dy,dz=point.X-origin.X,point.Y-origin.Y,point.Z-origin.Z
            if dx*dx+dy*dy<400^2 or dx*dx+dy*dy>8000^2 or math.abs(dz)>600 then return false end
            for _,p in ipairs(alive) do
                local x,y,z=point.X-p.position.X,point.Y-p.position.Y,point.Z-p.position.Z
                if x*x+y*y+z*z<400^2 then return false end
            end
            for _,entry in ipairs(owned) do
                if valid(entry.actor) and dead(entry.actor)~=true then
                    local read,other=call(entry.actor,'K2_GetActorLocation');other=read and vec(other)
                    if not other then return false end
                    local x,y=other.X-point.X,other.Y-point.Y
                    if x*x+y*y<400^2 then return false end
                end
            end
            return true
        end
        status.spawn_search={stage='player_start',min_distance_metres=4,max_distance_metres=80,
            relaxed=true,no_nav_fallback=true,attempts=0}
        local read,starts=false,nil
        if type(api.FindAllOf)=='function' then read,starts=pcall(api.FindAllOf,'PlayerStart') end
        if read and type(starts)=='table' then
            for i,start in ipairs(starts) do
                if i>256 then status.spawn_search.truncated=true;break end
                status.spawn_search.attempts=i
                if belongs(start) then
                    local got,point=call(start,'K2_GetActorLocation');point=got and vec(point)
                    -- Native PlayerStart location already is the actor's spawn centre.
                    if point and safe_center(point) then
                        return point,{min_distance=400,max_distance=8000,stage='player_start',relaxed=true,
                            no_nav_fallback=true,source='native_player_start'}
                    end
                end
            end
        elseif not read then status.spawn_search.player_start_error=tostring(starts or 'PlayerStart inventory unavailable'):sub(1,160) end
        local system=find('/Script/Engine.Default__KismetSystemLibrary')
        status.spawn_search={stage='ground_probe',min_distance_metres=4,max_distance_metres=80,
            relaxed=true,no_nav_fallback=true,attempts=0,floor_trace_channel=0}
        if not valid(system) or not valid(find('/Script/Engine.KismetSystemLibrary:LineTraceSingle')) then
            status.spawn_search.reason='Verified native ground-trace API is unavailable';return nil
        end
        local ignore={}
        for _,p in ipairs(alive) do if valid(p.pawn) then ignore[#ignore+1]=p.pawn end end
        for i,entry in ipairs(owned) do
            if i>64 then break end
            if valid(entry.actor) then ignore[#ignore+1]=entry.actor end
        end
        local color={R=0,G=0,B=0,A=1}
        for _,radius in ipairs({800,1600,3200,6000}) do
            for angle_index=0,15 do
                local angle=(angle_index/16)*2*math.pi+(index-1)*0.37
                local x,y=origin.X+radius*math.cos(angle),origin.Y+radius*math.sin(angle)
                local from={X=x,Y=y,Z=origin.Z+150};local to={X=x,Y=y,Z=origin.Z-700};local hit={}
                status.spawn_search.attempts=status.spawn_search.attempts+1
                local traced,blocking=call(system,'LineTraceSingle',c.world,from,to,0,false,ignore,0,hit,true,color,color,0.0)
                if not traced then
                    status.spawn_search.reason='Native ground trace failed: '..tostring(blocking):sub(1,160);return nil
                end
                local floor,normal=vec(get(hit,'Location')),vec(get(hit,'Normal'))
                if blocking==true and get(hit,'bBlockingHit')==true and get(hit,'bStartPenetrating')==false
                    and floor and normal and normal.Z>=0.5 and normal.Z<=1.01
                    and math.abs(floor.X-x)<10 and math.abs(floor.Y-y)<10
                    and floor.Z>=to.Z and floor.Z<=from.Z then
                    local point={X=floor.X,Y=floor.Y,Z=floor.Z+100}
                    if safe_center(point) then
                        return point,{min_distance=400,max_distance=8000,stage='ground_probe',relaxed=true,
                            no_nav_fallback=true,floor_checked=true,source='visibility_ground_trace'}
                    end
                end
            end
        end
        status.spawn_search.reason='No safe native PlayerStart or upward-facing blocking floor was found'
        return nil
    end
    local cleanup_validity_cdo,cleanup_validity_function
    local function gone(actor)
        if not valid(actor) then return true end
        if not valid(cleanup_validity_cdo) then cleanup_validity_cdo=find('/Script/Engine.Default__KismetSystemLibrary') end
        if not valid(cleanup_validity_function) then cleanup_validity_function=find('/Script/Engine.KismetSystemLibrary:IsValid') end
        if valid(cleanup_validity_cdo) and valid(cleanup_validity_function) then
            -- StaticFindObject constructs an unbound UFunction. It must be the
            -- CallFunction receiver; the CDO is its explicit calling context.
            local read,alive=call(cleanup_validity_function,'CallFunction',cleanup_validity_cdo,actor)
            if read and type(alive)=='boolean' then
                status.cleanup_validity_source='native_kismet';status.cleanup_native_validity_error=nil
                if not alive then return true end
                local ok,destroying=call(actor,'IsActorBeingDestroyed')
                return ok and destroying==true
            end
            status.cleanup_native_validity_error=tostring(alive):sub(1,180)
        end
        status.cleanup_validity_source='ue4ss_flags_fallback'
        local flags=api.EInternalObjectFlags or EInternalObjectFlags
        if type(flags)=='table' then
            for _,flag in pairs({flags.PendingKill,flags.Unreachable})do
                if type(flag)=='number' and flag>0 and flag%1==0 then
                    local read,pending=call(actor,'HasAnyInternalFlags',flag)
                    if read and pending==true then return true end
                end
            end
        end
        local ok,destroying=call(actor,'IsActorBeingDestroyed')
        return ok and destroying==true
    end
    local function destroy(entry)
        entry.cleanup_requested=true
        entry.actor_name=entry.actor_name or name(entry.actor)
        if not valid(entry.controller) and not gone(entry.actor) then
            local ok,c=call(entry.actor,'GetController')
            if ok and valid(c) and class_is(c,'AIC_Zombie_C') then entry.controller=c end
        end
        local pending=0
        entry.cleanup_quarantine=entry.cleanup_quarantine or {}
        for index,actor in ipairs({entry.actor,entry.controller}) do
            if not gone(actor) then
                call(actor,'StopMovement')
                local removed,result=call(actor,'K2_DestroyActor')
                if not removed or result==false then
                    entry.cleanup_error='K2_DestroyActor failed'
                    status.last_cleanup_error={actor=name(actor),operation='K2_DestroyActor',explicit_false=removed and result==false or false}
                end
                if not gone(actor) then
                    -- Keep both references until the engine confirms destruction.
                    -- Arm the fallback once: resetting a one-second lifespan on
                    -- every 250/500 ms retry would prevent it from ever expiring.
                    local mark=entry.cleanup_quarantine[index]
                    if not mark or mark.object~=actor then
                        mark={object=actor};entry.cleanup_quarantine[index]=mark
                        for _,request in ipairs({{'SetActorEnableCollision',false},{'SetActorHiddenInGame',true},{'SetLifeSpan',1.0}})do
                            local set,value=call(actor,request[1],request[2])
                            if not set or value==false then
                                entry.cleanup_error=request[1]..' failed'
                                status.last_cleanup_error={actor=name(actor),operation=request[1],explicit_false=set and value==false or false}
                            end
                        end
                    end
                    pending=pending+1
                end
            end
        end
        return pending
    end
    local function cleanup_owned()
        local retained={};local pending=0
        for _,entry in ipairs(owned)do
            pending=pending+destroy(entry)
            if not gone(entry.actor) or not gone(entry.controller) then retained[#retained+1]=entry
            else owned_by_name[entry.actor_name or '']=nil end
        end
        owned=retained;status.cleanup_pending=pending
        local alive=0
        for _,entry in ipairs(owned)do if not gone(entry.actor) and dead(entry.actor)==false then alive=alive+1 end end
        status.active=alive
        return pending
    end
    local function unregister_scoring()
        local failures=0
        for _,h in ipairs(hooks) do
            if type(unregister_hook)=='function' then
                local ok,result=pcall(unregister_hook,h.path,h.pre,h.post)
                if not ok or result==false then failures=failures+1 end
            else failures=failures+1 end
        end
        hooks={};status.scoring_hooks_active=false;status.hook_cleanup_failed=failures
        return failures
    end
    local function killer_key(instigator)
        instigator=unwrap(instigator)
        if not valid(instigator) then return nil end
        local visited={}
        local function resolve(o,depth)
            if depth>2 or not valid(o) then return nil end
            local n=name(o);if not n or visited[n] then return nil end;visited[n]=true
            local alias=participant_key_by_state[n]
            if alias and participants[alias] then return alias end
            if participants[n] then return n end
            if known_controllers[n] then return known_controllers[n] end
            local state=get(o,'PlayerState');local sn=name(state)
            if sn then
                local key=participant_key_by_state[sn] or participant_identity(state)
                if key and participants[key] then return key end
                if participants[sn] then return sn end
            end
            for _,method in ipairs({'GetInstigatorController','GetController','GetInstigator','GetOwner'}) do
                local ok,target=call(o,method)
                if ok and valid(target) then local key=resolve(target,depth+1);if key then return key end end
            end
        end
        return resolve(instigator,0)
    end
    owned_killer=function(instigator)
        instigator=unwrap(instigator)
        if not session or not session.scoring or status.phase~='RUNNING'or gone(instigator)then return nil end
        local function eligible(entry)
            if not entry or not entry.ready or entry.cleanup_requested or entry.generation~=session.generation
                or entry.death_finalized or entry.death_counted or gone(entry.actor)or gone(entry.controller)
                or dead(entry.actor)~=false then return nil end
            local controlled,controller=call(entry.actor,'GetController')
            local auth,a=call(entry.actor,'HasAuthority');local ca,c=call(entry.controller,'HasAuthority')
            if controlled and same_object(controller,entry.controller)and auth and a==true and ca and c==true then return entry end
        end
        local entry=owned_by_name[name(instigator)or '']
        if entry and same_object(entry.actor,instigator)then return eligible(entry)end
        -- Only a tracked zombie's actual current controller is an alternative
        -- exact instigator. No owner-chain, location or last-damager guesses.
        for _,candidate in ipairs(owned)do
            if valid(candidate.controller)and same_object(candidate.controller,instigator)then return eligible(candidate)end
        end
    end
    local function count_puppet_death(entry)
        if not session or not session.scoring or not puppet.enabled or status.phase~='RUNNING'
            or not entry.ready or entry.cleanup_requested or entry.generation~=session.generation
            or entry.death_counted or entry.puppet_death_counted then return false end
        local now=world_now(session.world)
        if not now or now<session.started_at or now>=session.deadline then return false end
        entry.puppet_death_counted=true;puppet.deaths=puppet.deaths+1
        return true
    end
    local function observe_death(actor,instigator,source)
        if not session or not session.scoring or status.phase~='RUNNING' then return end
        local now=world_now(session.world)
        if not now or now>=session.deadline or now<session.started_at then return end
        local entry=owned_by_name[name(actor) or '']
        if not entry or not same_object(entry.actor,actor)or not entry.ready or entry.cleanup_requested
            or entry.generation~=session.generation or entry.death_finalized then return end
        entry.death_finalized=true
        entry.fatal_observed=true
        count_puppet_death(entry)
        entry.death_counted=true;status.kills=status.kills+1
        local key=killer_key(instigator)
        if not key then
            entry.unresolved_source=source;entry.uncredited=true;status.uncredited=status.uncredited+1;write();return
        end
        entry.credited=true;entry.killer=key
        local p=participants[key]
        if p.eliminated then entry.uncredited=true;status.uncredited=status.uncredited+1;write();return end
        p.kills=p.kills+1;apply_points(key,SCORE_RULES.kill_points,'zombie_kill')
        status.last_score_event.source=source
        status.credited_kills=(status.credited_kills or 0)+1
        status.scoring_verified=true;write()
    end
    local function install_scoring()
        if type(register_hook)~='function' or type(unregister_hook)~='function' then return false,'Exact death hook and cleanup APIs are unavailable' end
        local expected=session.generation
        status.scoring_sources={}
        local function install(path,key,callback,required)
            local fn=find(path)
            if not fn then status.scoring_sources[key]={available=false};return not required end
            local wrapper=function(...)
                if not session or session.generation~=expected or generation~=expected or status.phase~='RUNNING' then return end
                local ok,err=pcall(callback,...)
                if not ok then status.scoring_capture_error=tostring(err):sub(1,240) end
                -- No return value: never override damage, health or death behavior.
            end
            local ok,pre,post=pcall(register_hook,path,wrapper)
            local registered=ok and type(pre)=='number' and type(post)=='number'
            status.scoring_sources[key]={available=true,registered=registered,path=path}
            if registered then hooks[#hooks+1]={path=path,pre=pre,post=post,callback=wrapper};return true end
            return not required
        end
        local main=install(DEATH_PATH,'out_of_health',function(c,instigator)
            local component=unwrap(c);local ok,actor=call(component,'GetOwner')
            if not ok or not valid(actor) then return end
            local pawn_name=name(actor) or '';local life=player_lives[pawn_name]
            if not life and class_is(actor,'Bodycam_Player_C') then
                local key=killer_key(actor)
                if key then life={key=key,generation=session.generation,seen_alive=true};player_lives[pawn_name]=life end
            end
            if life then player_penalty(life.key,pawn_name,instigator,true,killer_key)
            else observe_death(actor,instigator,'out_of_health') end
        end,true)
        if not main then unregister_scoring();return false,'The verified zombie/player death callback could not be registered' end
        status.scoring_hooks_active=true;return true
    end
    function self.stop(reason)
        local reset_spectators=session and session.scoring
        local previous_failures=cleanup_failure_latched and (status.cleanup_failed or 1) or 0
        generation=generation+1
        cleanup_token=cleanup_token+1;local token=cleanup_token
        local base_failures=previous_failures
        if prematch and prematch.timer then
            local ok,result=pcall(api.CancelDelayedAction,prematch.timer)
            if not ok or result==false then base_failures=base_failures+1 end
        end
        prematch=nil
        if cleanup_timer then
            local ok,result=pcall(api.CancelDelayedAction,cleanup_timer)
            if not ok or result==false then base_failures=base_failures+1 end
            cleanup_timer=nil
        end
        if session and session.timer and type(api.CancelDelayedAction)=='function' then
            local ok,result=pcall(api.CancelDelayedAction,session.timer)
            if not ok or result==false then base_failures=base_failures+1 end
        end
        base_failures=base_failures+unregister_scoring()
        session=nil;status.phase='STOPPED';status.reason=reason or 'Stopped by command'
        if reason=='Own module reload' and controls then
            local ok,result=pcall(controls.shutdown)
            if not ok or result==false then base_failures=base_failures+1 end
            controls=nil
        end
        if reset_spectators and type(elimination_reset)=='function' then
            local ok,result=pcall(elimination_reset,status.reason)
            if not ok or result==false then base_failures=base_failures+1;status.spectator_reset_failed=true end
        end
        if base_failures>0 then cleanup_failure_latched=true end
        cleanup_attempts=1
        local pending=cleanup_owned()
        status.cleanup_failed=base_failures+pending;status.cleanup_attempts=cleanup_attempts
        if pending>0 then
            local function retry_cleanup()
                if cleanup_token~=token then return end
                cleanup_attempts=cleanup_attempts+1
                local remaining=cleanup_owned()
                status.cleanup_failed=base_failures+remaining;status.cleanup_attempts=cleanup_attempts
                if remaining==0 or cleanup_attempts>=8 then
                    if remaining>0 then cleanup_failure_latched=true;status.cleanup_exhausted=true end
                    if cleanup_timer then
                        local ok,result=pcall(api.CancelDelayedAction,cleanup_timer)
                        if not ok or result==false then cleanup_failure_latched=true;status.cleanup_failed=status.cleanup_failed+1 end
                        cleanup_timer=nil
                    end
                end
                write()
            end
            local ok,handle=pcall(api.LoopInGameThreadWithDelay,250,retry_cleanup)
            if ok and type(handle)=='number' then cleanup_timer=handle
            else cleanup_failure_latched=true;status.cleanup_failed=status.cleanup_failed+1;status.cleanup_exhausted=true end
        end
        if cleanup_failure_latched then status.cleanup_failed=math.max(status.cleanup_failed,1) end
        write();log(status.reason)
        return true
    end
    local function spawn(c)
        local point,search=spawn_point(c)
        if not point then return false,'No reachable spawn point 4–80 metres away after staged search' end
        local transform={Rotation={X=0,Y=0,Z=0,W=1},Translation=point,Scale3D={X=1,Y=1,Z=1}}
        -- Collision mode 3: adjust if possible; otherwise refuse this spawn.
        local ok,actor=call(gs,'BeginDeferredActorSpawnFromClass',c.world,loaded.pawn,transform,3,nil,1)
        if not ok or not valid(actor) then return false,'Deferred zombie spawn failed' end
        local entry={actor=actor,actor_name=name(actor),spawned_at=c.now,no_nav_fallback=search.no_nav_fallback==true,
            generation=session and session.generation or prematch and prematch.generation,ready=false};owned[#owned+1]=entry
        owned_by_name[entry.actor_name or '']=entry
        local set,err=pcall(function()
            actor.PDA_Zombie=loaded.pda;actor['IsSprinter?']=false;actor['Debug?']=false
            actor.Speed=SETTINGS.zombie_speed;actor.ExpectedHealth=SETTINGS.zombie_health;actor.ShouldCommunicateDeath=false
            -- Keep the native distance-based speed adaptation at our chosen
            -- walk/run value; otherwise it accelerates distant walkers to 450.
            actor.AdaptiveSpeedMinDistance=10000000;actor.AdaptiveSpeedMaxDistance=10000001
            actor.AIControllerClass=loaded.controller
            -- Existing empty traits remain empty; do not write arbitrary containers.
        end)
        if not set then destroy(entry);return false,'Zombie preinitialization failed: '..tostring(err):sub(1,180) end
        local finished,result=call(gs,'FinishSpawningActor',actor,transform,1)
        if not finished or not valid(result) then destroy(entry);return false,'FinishSpawningActor failed' end
        local located,actual=call(actor,'K2_GetActorLocation');actual=located and vec(actual)
        if not actual then destroy(entry);return false,'Spawned zombie position is unreadable' end
        if search.no_nav_fallback then
            local dx,dy,dz=actual.X-point.X,actual.Y-point.Y,actual.Z-point.Z
            if dx*dx+dy*dy>100^2 or math.abs(dz)>100 then
                destroy(entry);return false,'Collision adjustment left the verified fallback spawn position'
            end
        end
        for _,player in ipairs(c.alive_players) do
            local x,y,z=actual.X-player.position.X,actual.Y-player.position.Y,actual.Z-player.position.Z
            if x*x+y*y+z*z<search.min_distance^2 then
                destroy(entry);return false,'Collision-adjusted spawn was too close to a living player'
            end
        end
        if session and session.scoring or prematch then
            local replicated=call(actor,'SetReplicates',true)
            local movement=call(actor,'SetReplicateMovement',true)
            if not replicated or not movement or get(actor,'bReplicates')~=true then
                destroy(entry);return false,'Zombie replication could not be enabled and verified'
            end
        end
        local controlled,controller=call(actor,'GetController')
        if not controlled or not valid(controller) then
            local made=call(actor,'SpawnDefaultController')
            controlled,controller=call(actor,'GetController')
            if not made or not controlled or not valid(controller) then
                destroy(entry);return false,'Zombie AI controller was not created'
            end
        end
        if not class_is(controller,'AIC_Zombie_C') then destroy(entry);return false,'Unexpected zombie AI controller' end
        entry.controller=controller
        -- Fail-safe actor lifetime even if a later Lua callback stops unexpectedly.
        call(actor,'SetLifeSpan',650.0);call(controller,'SetLifeSpan',650.0)
        entry.ready=true
        status.spawned=status.spawned+1;status.last_spawn={actor=name(actor),controller=name(controller),
            distance_metres=math.floor(math.sqrt((point.X-c.position.X)^2+(point.Y-c.position.Y)^2)/100),
            stage=search.stage,min_distance_metres=search.min_distance/100,relaxed=search.relaxed,no_nav_fallback=search.no_nav_fallback==true}
        return true
    end
    function self.probe()
        if prematch then return issue('The prematch countdown is already active') end
        if cleanup_failure_latched then return issue('Previous cleanup was incomplete; restart is required before another round') end
        if cleanup_timer or (status.cleanup_pending or 0)>0 then return issue('Previous zombies are still being removed') end
        if session then return issue('Stop the current session before probing') end
        local c,err=context()
        if not c then status.phase='BLOCKED';return issue(err) end
        if #c.alive_players==0 then status.phase='BLOCKED';return issue('At least one living player is required before starting') end
        status.world=c.world_name;status.player=c.player_name
        local ok,why=load_assets()
        if not ok then status.phase='BLOCKED';return issue(why) end
        local point=spawn_point(c)
        status.navigation_ready=point~=nil
        if not point then status.phase='BLOCKED';return issue('This player location has no suitable nearby navmesh spawn points') end
        status.phase='READY_FOR_ONE_ZOMBIE';status.reason='Probe succeeded; no actor was spawned';write()
        return true
    end
    function self.inspect()
        if not valid(gs) then gs=find('/Script/Engine.Default__GameplayStatics') end
        if not valid(nav) then nav=find('/Script/NavigationSystem.Default__NavigationSystemV1') end
        local world,why=current_world()
        local r={world=object_info(world),world_error=why,navigation={library=object_info(nav)},assets={}}
        r.navigation.random_reachable_symbol=valid(find('/Script/NavigationSystem.NavigationSystemV1:K2_GetRandomReachablePointInRadius'))
        r.navigation.project_point_symbol=valid(find('/Script/NavigationSystem.NavigationSystemV1:K2_ProjectPointToNavigation'))
        for k,path in pairs(ASSETS) do r.assets[k]={path=path,loaded=valid(loaded[k])} end
        if world then
            local gm=get(world,'AuthorityGameMode');r.authority_game_mode=object_info(gm)
            local count,source,counts=count_players(world,gm);r.player_counts=counts;r.player_count=count;r.player_count_source=source
            local _,network=network_info(world);r.network=network
            r.world_clock=call_info(gs,'GetRealTimeSeconds',world)
            local got,gi=call(gs,'GetGameInstance',world);r.game_instance=object_info(got and gi or nil)
            if got and valid(gi) then
                local field,err=reflected_field(gi,'gamemode');r.game_instance.mode_field=field;r.game_instance.reflection_error=err
                if field then r.game_instance.mode=read_info(gi,field) end
            end
            local reached,pc=call(gs,'GetPlayerController',world,0);pc=reached and pc or nil;r.player_controller=object_info(pc)
            r.player_controller.authority=call_info(pc,'HasAuthority');r.player_controller.local_controller=call_info(pc,'IsLocalController')
            local pawn=get(pc,'Pawn');r.pawn=object_info(pawn)
            r.pawn.authority=call_info(pawn,'HasAuthority');r.pawn.locally_controlled=call_info(pawn,'IsLocallyControlled')
            r.pawn.player_controlled=call_info(pawn,'IsPlayerControlled')
            local survivor=get(pawn,'WW_SurvivorStatus');r.pawn.survivor_status=object_info(survivor)
            r.pawn.death_property=read_info(survivor,'Death?');r.pawn.death=dead(pawn)
        end
        status.inspection=r;write();return true
    end
    function self.map()
        if cleanup_failure_latched then return issue('Previous cleanup was incomplete; restart is required before map travel') end
        if session then return issue('Stop the current session before requesting a map') end
        if not valid(gs) then gs=find('/Script/Engine.Default__GameplayStatics') end
        if not valid(gs) then return issue('Native gameplay library unavailable') end
        local world,world_error=current_world();if not world then return issue(world_error) end
        local wn=name(world) or ''
        if not wn:lower():find('/map/lobby/lobby',1,true) then return issue('The fixed map command is allowed only from the lobby') end
        local gm=get(world,'AuthorityGameMode')
        if not valid(gm) then return issue('Local lobby authority is required') end
        local got,pc=call(gs,'GetPlayerController',world,0)
        if not got or not valid(pc) then return issue('Local player controller unavailable') end
        local authoritative,a=call(pc,'HasAuthority')
        local local_pc,l=call(pc,'IsLocalController')
        if not authoritative or a~=true or not local_pc or l~=true then return issue('Local authoritative lobby controller is required') end
        local players,source,counts=count_players(world,gm);status.player_count=players;status.player_count_source=source;status.player_counts=counts
        if players==nil or players>1 then return issue('Other players are present or not safely countable') end
        local permitted,network=network_info(world);status.network=network
        if not permitted then return issue(network.error) end
        if (network.peer_count or 0)>0 then return issue('The practice map command is solo-only and will not disconnect peers') end
        local made,mapname=pcall(api.FName,'/Game/GM_Maps/DeathMatch/DM_CQB')
        if not made then return issue('FName constructor unavailable') end
        local reached,gi=call(gs,'GetGameInstance',world)
        if not reached or not valid(gi) or not class_is(gi,'BodycamGI_C') then
            return issue('A valid BodycamGI instance is required before local map travel')
        end
        local mode_field,reflection_error=reflected_field(gi,'gamemode')
        if not mode_field then return issue(reflection_error) end
        local previous=get(gi,mode_field)
        if not finite(previous) or previous<0 or previous>255 or previous%1~=0 then
            return issue('Original GameMode could not be safely preserved')
        end
        status.map_configuration={property=mode_field,previous=previous,requested=2,verified=false}
        local function restore_mode()
            local restored=pcall(function()gi[mode_field]=previous end)
            status.map_configuration.restored=restored and get(gi,mode_field)==previous
            status.map_configuration.restore_failed=not status.map_configuration.restored
            return status.map_configuration.restored
        end
        local configured=pcall(function()gi[mode_field]=2 end)
        if not configured or get(gi,mode_field)~=2 then
            restore_mode();return issue('Local Deathmatch GameMode could not be set and verified')
        end
        status.map_configuration.verified=true
        local opened,err=call(gs,'OpenLevel',world,mapname,true,'listen')
        if not opened then
            restore_mode();return issue('Map request failed: '..tostring(err):sub(1,180))
        end
        status.phase='MAP_REQUESTED';status.reason='Fixed local DM_CQB map requested; successful travel not yet verified';write()
        return true
    end
    local function finish_round()
        local result={completed=true,reason='time_limit',duration_seconds=SETTINGS.duration_seconds,
            finished_at=session.deadline,scoreboard={},winners={},tie=false,winning_points=0}
        local best;local winner_count=0
        local function finalist(key,p)
            result.scoreboard[key]={name=p.name,kills=p.kills,deaths=p.deaths,points=p.points,connected=p.connected,
                eliminated=p.eliminated==true,virtual=p.virtual==true,bot=p.bot==true}
            if not p.eliminated then
                if best==nil or p.points>best then best=p.points;result.winners={};winner_count=0 end
                if p.points==best then result.winners[key]={name=p.name,points=p.points,virtual=p.virtual==true};winner_count=winner_count+1 end
            end
        end
        for key,p in pairs(participants)do finalist(key,p)end
        if puppet.enabled then finalist(PUPPET_KEY,puppet_snapshot())end
        result.winning_points=winner_count>0 and best or nil;result.tie=winner_count>1;result.no_winner=winner_count==0
        self.stop('Five minutes completed')
        status.phase='FINISHED';status.remaining_seconds=0;status.final_result=result
        status.elapsed_seconds=SETTINGS.duration_seconds
        status.winners=result.winners;status.tie=result.tie;write()
    end
    local function cleanup_during_round(entry,reason)
        if gone(entry.actor) and gone(entry.controller) then
            owned_by_name[entry.actor_name or '']=nil;return true
        end
        if (entry.cleanup_attempts or 0)<8 then
            entry.cleanup_attempts=(entry.cleanup_attempts or 0)+1
            if destroy(entry)==0 then owned_by_name[entry.actor_name or '']=nil;return true end
        end
        if entry.cleanup_attempts>=8 then
            entry.cleanup_deferred=true
            status.last_cleanup_warning={actor=entry.actor_name,reason=reason,attempts=entry.cleanup_attempts}
        end
        return false
    end
    local function deferred_cleanup_count()
        local count=0
        for _,entry in ipairs(owned)do if entry.cleanup_deferred then count=count+1 end end
        status.cleanup_deferred=count
    end
    local function quarantine_npc(entry,reason)
        entry.cleanup_requested=true;entry.death_counted=true;entry.death_finalized=true;entry.uncredited=true
        status.last_npc_warning={actor=entry.actor_name,reason=reason,phase=status.phase}
        return cleanup_during_round(entry,reason)
    end
    function self.tick()
        if prematch then
            local world=current_world()
            if not world or name(world)~=prematch.world_name then self.stop('World changed during prematch');return end
            local now=world_now(world)
            if not now or now<prematch.started_at then self.stop('Prematch clock is unreadable or reset');return end
            status.prematch_remaining_seconds=math.max(0,math.ceil(prematch.deadline-now))
            local c,why,kind=context()
            if not c then
                if kind=='transient' then status.spawn_paused=why;write();return end
                self.stop(why);return
            end
            status.clock_seconds=c.now
            local active,retained=0,{}
            for _,entry in ipairs(owned) do
                if entry.cleanup_requested or gone(entry.actor) then
                    if not cleanup_during_round(entry,'Warmup zombie cleanup deferred until round end') then retained[#retained+1]=entry end
                else
                    local d=dead(entry.actor)
                    if d==nil then
                        if not quarantine_npc(entry,'Warmup zombie death state unreadable')then retained[#retained+1]=entry end
                    elseif d then
                        entry.dead_at=entry.dead_at or c.now
                        entry.death_counted=true;entry.death_finalized=true;entry.uncredited=true
                        if valid(entry.controller) then call(entry.controller,'StopMovement') end
                        if c.now-entry.dead_at>=4 then
                            if not cleanup_during_round(entry,'Warmup corpse cleanup deferred until round end') then retained[#retained+1]=entry end
                        else retained[#retained+1]=entry end
                    else
                        local controlled,controller=call(entry.actor,'GetController')
                        if not controlled or not valid(controller) or not valid(entry.controller)
                            or name(controller)~=name(entry.controller) or not class_is(controller,'AIC_Zombie_C') then
                            if not quarantine_npc(entry,'Warmup zombie AI controller disappeared or changed')then retained[#retained+1]=entry end
                        else
                            active=active+1;retained[#retained+1]=entry
                        end
                    end
                end
            end
            owned=retained;status.active=active;deferred_cleanup_count()
            if now>=prematch.deadline then
                local timer=prematch.timer;prematch=nil
                local ok,result=pcall(api.CancelDelayedAction,timer)
                if not ok or result==false then self.stop('Prematch timer could not be cancelled');return end
                begin_session(c,true,false,true,true)
            elseif #c.alive_players==0 then
                status.spawn_paused='Waiting for a living player; prematch clock continues';write()
            elseif c.now>=prematch.next_spawn and active<status.target_active then
                prematch.next_spawn=c.now+SETTINGS.spawn_interval
                local ok,why=spawn(c)
                if not ok then
                    prematch.failed_spawns=prematch.failed_spawns+1;status.reason=why
                    local delay=math.min(30,SETTINGS.spawn_interval*2^math.min(4,prematch.failed_spawns-1))
                    prematch.next_spawn=c.now+delay;status.spawn_paused=why;status.spawn_retry_seconds=delay
                else prematch.failed_spawns=0;status.active=active+1;status.spawn_paused=nil;status.spawn_retry_seconds=nil end
                write()
            else write() end
            return
        end
        if not session then return end
        local world=current_world()
        if not world or name(world)~=session.world_name then self.stop('World changed');return end
        local now=world_now(world)
        if not now or now<session.started_at then self.stop('World clock is unreadable or reset');return end
        if now>=session.deadline then
            if status.phase=='SMOKE_TEST' then self.stop('Smoke test timed out') else finish_round() end
            return
        end
        status.remaining_seconds=math.max(0,math.ceil(session.deadline-now))
        status.elapsed_seconds=math.max(0,now-session.started_at)
        status.clock_seconds=now
        local c,err,kind=context()
        if not c then
            if kind=='transient' then status.spawn_paused=err;write();return end
            self.stop(err);return
        end
        if not session then return end
        session.host_controller=c.host_controller;status.spawn_paused=nil
        local active,retained=0,{}
        for _,entry in ipairs(owned) do
            if entry.cleanup_requested or gone(entry.actor) then
                if not cleanup_during_round(entry,'Zombie cleanup deferred until round end') then retained[#retained+1]=entry end
            elseif valid(entry.actor) then
                local d=dead(entry.actor)
                if d==nil then
                    if status.phase=='SMOKE_TEST'then self.stop('Zombie death state unreadable');return end
                    if not quarantine_npc(entry,'Zombie death state unreadable')then retained[#retained+1]=entry end
                elseif d then
                    if not entry.dead_at then
                        entry.dead_at=c.now
                        if not entry.death_counted then count_puppet_death(entry);entry.death_counted=true;status.kills=status.kills+1 end
                        if session.scoring and not entry.credited and not entry.uncredited then
                            entry.uncredited=true;entry.death_finalized=true;status.uncredited=status.uncredited+1
                        end
                        if valid(entry.controller) then call(entry.controller,'StopMovement') end
                    end
                    if c.now-entry.dead_at>=4 then
                        if not cleanup_during_round(entry,'Corpse cleanup deferred until round end') then retained[#retained+1]=entry end
                    else retained[#retained+1]=entry end
                else
                    local controlled,controller=call(entry.actor,'GetController')
                    if not controlled or not valid(controller) or not valid(entry.controller)
                        or name(controller)~=name(entry.controller) or not class_is(controller,'AIC_Zombie_C') then
                        if status.phase=='SMOKE_TEST'then self.stop('Zombie AI controller disappeared or changed');return end
                        if not quarantine_npc(entry,'Zombie AI controller disappeared or changed')then retained[#retained+1]=entry end
                    else
                        active=active+1;retained[#retained+1]=entry
                        if status.phase=='SMOKE_TEST' then
                            local located,position=call(entry.actor,'K2_GetActorLocation')
                            local survivor=get(entry.actor,'WW_SurvivorStatus')
                            status.smoke_detail={actor=name(entry.actor),controller=name(controller),
                                position=located and vec(position) or nil,health=get(survivor,'Health'),dead=false}
                        end
                    end
                end
            end
        end
        owned=retained;status.active=active;deferred_cleanup_count()
        if status.phase=='SMOKE_TEST' then
            if active==1 and c.now-session.started_at>=2 then session.smoke_verified=true end
            status.smoke_actor_verified=session.smoke_verified==true
        elseif #c.alive_players==0 then
            status.spawn_paused='Waiting for a living player; round clock continues'
        elseif c.now>=session.next_spawn and active<status.target_active then
            session.next_spawn=c.now+SETTINGS.spawn_interval
            local ok,why=spawn(c)
            if not ok then
                session.failed_spawns=session.failed_spawns+1;status.reason=why
                local delay=math.min(30,SETTINGS.spawn_interval*2^math.min(4,session.failed_spawns-1))
                session.next_spawn=c.now+delay;status.spawn_paused=why;status.spawn_retry_seconds=delay
            else session.failed_spawns=0;status.active=active+1;status.spawn_paused=nil;status.spawn_retry_seconds=nil end
        end
        write()
    end
    begin_session=function(c,competition,smoke,allow_waiting_players,adopt_warmup)
        if type(api.LoopInGameThreadWithDelay)~='function' or type(api.CancelDelayedAction)~='function' then
            status.phase='BLOCKED';return issue('Safe game-thread loop/cancellation APIs unavailable')
        end
        if #c.alive_players==0 and not allow_waiting_players then return issue('Wait for at least one living player') end
        generation=generation+1
        participants={};known_controllers={};player_lives={};owned_by_name={}
        reset_puppet(competition)
        local ids_ok,ids_why=self.reset_participant_identities(c.players)
        if not ids_ok then return issue(ids_why or 'Player identities are not ready') end
        status.cleanup_pending=0;status.cleanup_failed=0;status.cleanup_exhausted=nil;status.cleanup_attempts=0
        local duration=smoke and 60 or SETTINGS.duration_seconds
        session={world=c.world,world_name=c.world_name,host_controller=c.host_controller,started_at=c.now,duration=duration,
            deadline=c.now+duration,next_spawn=c.now+SETTINGS.spawn_interval,failed_spawns=0,spawn_cursor=0,
            scoring=competition,generation=generation}
        status.world=c.world_name;status.player=c.player_name;status.final_result=nil;status.winners=nil;status.tie=nil
        status.spawned=0;status.kills=0;status.uncredited=0;status.credited_kills=0;status.active=0;status.smoke_actor_verified=false
        local adopted=0
        if adopt_warmup then
            for _,entry in ipairs(owned)do
                entry.generation=generation
                owned_by_name[entry.actor_name or name(entry.actor) or '']=entry
                if not gone(entry.actor) then
                    local d=dead(entry.actor)
                    if d==nil then quarantine_npc(entry,'Warmup zombie death state unreadable at match start')
                    elseif d then
                        entry.dead_at=entry.dead_at or c.now
                        entry.death_counted=true;entry.death_finalized=true;entry.uncredited=true
                    elseif not entry.cleanup_requested then adopted=adopted+1 end
                end
            end
        end
        status.active=adopted;status.adopted_warmup=adopted
        status.scoring_verified=false;status.competition=competition;status.remaining_seconds=duration
        status.elapsed_seconds=0;status.started_at=c.now;status.deadline=session.deadline;status.clock_seconds=c.now
        status.phase=smoke and 'SMOKE_TEST' or 'RUNNING';sync_roster(c.players)
        if competition then
            local hooked,why=install_scoring()
            if not hooked then self.stop(why);return false,why end
        end
        if #c.alive_players>0 and adopted==0 then
            local ok,err=spawn(c)
            if not ok then
                if competition then
                    session.failed_spawns=1;session.next_spawn=c.now+SETTINGS.spawn_interval
                    status.spawn_paused=err;status.spawn_retry_seconds=SETTINGS.spawn_interval
                else self.stop(err);return false,err end
            else status.active=1 end
        elseif #c.alive_players==0 then status.spawn_paused='Waiting for a living player; round clock continues' end
        status.reason=smoke and 'One test zombie; repeat start after verification' or 'Five-minute zombie competition started'
        local expected=generation
        local made,timer=pcall(api.LoopInGameThreadWithDelay,500,function()
            if not session or session.generation~=expected or generation~=expected then return end
            local healthy,failure=pcall(self.tick)
            if not healthy then self.stop('Session callback failed: '..tostring(failure):sub(1,180)) end
        end)
        if not made or type(timer)~='number' then self.stop('Game-thread session timer could not start');return false end
        session.timer=timer;write();return true
    end
    function self.start()
        if prematch then return issue('The prematch countdown is already active') end
        if cleanup_failure_latched then return issue('Previous cleanup was incomplete; restart is required before another round') end
        if session then
            if status.phase~='SMOKE_TEST' then return issue('Session already running') end
            if status.smoke_actor_verified~=true then return issue('The first zombie has not passed the two-second actor/controller check') end
            local c,why=context();if not c then self.stop(why);return false,why end
            session.started_at=c.now;session.duration=SETTINGS.duration_seconds;session.deadline=c.now+SETTINGS.duration_seconds
            session.next_spawn=c.now+SETTINGS.spawn_interval
            status.started_at=c.now;status.deadline=session.deadline;status.elapsed_seconds=0
            status.phase='RUNNING';status.reason='Five-minute legacy test started; scoring is not enabled';write();return true
        end
        if status.phase~='READY_FOR_ONE_ZOMBIE' then return issue('Run probe first') end
        local c,why=context();if not c then status.phase='BLOCKED';return issue(why) end
        return begin_session(c,false,true)
    end
    function self.play()
        if prematch then return issue('The prematch countdown is already active') end
        if cleanup_failure_latched then return issue('Previous cleanup was incomplete; restart is required before another round') end
        if cleanup_timer or (status.cleanup_pending or 0)>0 then return issue('Previous zombies are still being removed') end
        if session then return issue('A round is already running') end
        if SCORE_RULES.elimination_enabled and type(elimination_handler)~='function' then
            return issue('The required spectator transition adapter is unavailable')
        end
        local ok,why=self.probe();if not ok then return false,why end
        local c,err=context();if not c then return issue(err) end
        return begin_session(c,true,false)
    end
    function self.prepare()
        if prematch then return true end
        if session then return issue('A round is already running') end
        if cleanup_failure_latched then return issue('Previous cleanup was incomplete; restart is required before another round') end
        if cleanup_timer or (status.cleanup_pending or 0)>0 then return issue('Previous zombies are still being removed') end
        if type(elimination_handler)~='function' then return issue('The required spectator transition adapter is unavailable') end
        local c,why=context();if not c then return issue(why) end
        local loaded_ok,err=load_assets();if not loaded_ok then return issue(err) end
        if type(api.LoopInGameThreadWithDelay)~='function' or type(api.CancelDelayedAction)~='function' then return issue('Safe prematch timer APIs unavailable') end
        generation=generation+1;local expected=generation
        participants={};known_controllers={};player_lives={}
        reset_puppet(true)
        local ids_ok,ids_why=self.reset_participant_identities(c.players)
        if not ids_ok then return issue(ids_why) end
        sync_roster(c.players)
        prematch={world=c.world,world_name=c.world_name,started_at=c.now,deadline=c.now+SETTINGS.prematch_seconds,
            generation=expected,next_spawn=c.now+SETTINGS.spawn_interval,failed_spawns=0}
        status.world=c.world_name;status.phase='PREMATCH';status.prematch_remaining_seconds=SETTINGS.prematch_seconds
        status.prematch_started_at=c.now;status.prematch_deadline=prematch.deadline
        status.started_at=nil;status.remaining_seconds=SETTINGS.duration_seconds;status.elapsed_seconds=0;status.clock_seconds=c.now
        publish_scoreboard();status.final_result=nil;status.winners=nil;status.tie=nil
        status.active=0;status.spawned=0;status.kills=0;status.reason='Thirty-second prematch; deaths do not reset the clock'
        local ok,timer=pcall(api.LoopInGameThreadWithDelay,500,function()
            if not prematch or generation~=expected or prematch.generation~=expected then return end
            local healthy,failure=pcall(self.tick)
            if not healthy then self.stop('Prematch callback failed: '..tostring(failure):sub(1,180)) end
        end)
        if not ok or type(timer)~='number' then prematch=nil;return issue('Prematch timer could not start') end
        prematch.timer=timer
        if #c.alive_players>0 then
            local spawned,reason=spawn(c)
            if not spawned then
                prematch.failed_spawns=1;prematch.next_spawn=c.now+SETTINGS.spawn_interval
                status.spawn_paused=reason;status.spawn_retry_seconds=SETTINGS.spawn_interval
            else status.active=1 end
        else status.spawn_paused='Waiting for a living player; prematch clock continues' end
        write();return true
    end
    function self.command(command)
        if command=='inspect' then return self.inspect()
        elseif command=='environment' then
            local ok,module=pcall(dofile,SCRIPT_DIR..'environment_probe.lua')
            if not ok or type(module)~='table' or type(module.new)~='function' then return issue('Own environment probe unavailable') end
            local made,probe=pcall(module.new,self,api)
            if not made or type(probe)~='table' then return issue('Own environment probe initialization failed') end
            local read,report=pcall(probe.report)
            if not read or type(report)~='table' then return issue('Environment inspection failed') end
            status.environment=report;write();return true
        elseif command=='controls' then return self.enable_controls()
        elseif command=='map' then return self.map()
        elseif command=='probe' then return self.probe()
        elseif command=='start' then return self.start()
        elseif command=='play' then return self.prepare()
        elseif command=='stop' then return self.stop('Stopped by command') end
        return issue('Unknown command; allowed: controls, inspect, map, probe, start, play, stop')
    end
    function self.set_elimination_handler(handler,reset)
        if type(handler)~='function' then return false,'Spectator adapter must be a function' end
        if reset~=nil and type(reset)~='function' then return false,'Spectator reset adapter must be a function' end
        elimination_handler=handler;elimination_reset=reset;status.capabilities.spectator_adapter=true;return true
    end
    function self.get_controller()
        if session and valid(session.host_controller) then return session.host_controller end
        if not valid(gs) then gs=find('/Script/Engine.Default__GameplayStatics') end
        local world=current_world();if not world then return nil end
        for index=0,SETTINGS.max_players-1 do
            local ok,pc=call(gs,'GetPlayerController',world,index)
            if ok and valid(pc) then local local_pc,l=call(pc,'IsLocalController');if local_pc and l==true then return pc end end
        end
    end
    function self.get_players()
        local result={}
        for _,p in ipairs(current_roster) do
            local score=participants[p.key] or {}
            result[#result+1]={key=p.key,controller=p.controller,player_state=p.player_state,pawn=p.pawn,name=p.name,
                kills=score.kills or 0,deaths=score.deaths or 0,points=score.points or 0,alive=p.alive and not score.eliminated,
                connected=true,eliminated=score.eliminated==true}
        end
        return result
    end
    function self.get_puppetmaster_status()return puppet_snapshot()end
    function self.is_owned_virtual_state(state)return virtual_state_matches(state)end
    -- Future native-row adapters may explicitly bind their own controllerless
    -- PlayerState for count exclusion. This core never creates one or claims
    -- that the game's native scoreboard can display this Lua aggregate.
    function self.set_virtual_opponent_state(state)
        if state==nil then virtual_state=nil;return true end
        if gone(state)or not class_is(state,'PlayerState')then return false,'A live native PlayerState is required'end
        local world=current_world()
        if not world or not valid(get(world,'AuthorityGameMode'))then return false,'A current authoritative host world is required'end
        local permitted=network_info(world);if not permitted then return false,'A remote client cannot bind a virtual opponent'end
        local auth,a=call(state,'HasAuthority');local located,w=call(state,'GetWorld')
        if not auth or a~=true or not located or not valid(w)or name(w)~=name(world)then return false,'Virtual PlayerState authority or world does not match'end
        local controlled,pc=call(state,'GetPlayerController')
        if not controlled or valid(pc)then return false,'The virtual opponent must not own a player controller'end
        for _,p in ipairs(current_roster)do
            if same_object(state,p.player_state)then return false,'A human PlayerState cannot be registered as virtual'end
        end
        local named=name(state);local got,address=call(state,'GetAddress')
        if not named or type(state)~='table'and (not got or not finite(address)or address<=0)then return false,'Exact virtual PlayerState identity is unavailable'end
        virtual_state={object=type(state)=='table'and state or nil,address=got and address or nil,name=named,world=name(world)}
        return true
    end
    function self.release_for_travel()
        if status.phase~='FINISHED' or session or prematch or cleanup_timer or cleanup_failure_latched
            or status.cleanup_pending~=0 or status.cleanup_failed~=0 or status.active~=0 or next(owned)~=nil
            or next(hooks)~=nil then
            return false,'Only a fully cleaned finished round may release travel references'
        end
        -- No UObject access: world-owned classes and player wrappers must not be
        -- reused after the engine has unloaded the previous map.
        loaded={};current_roster={};known_controllers={};player_lives={};owned_by_name={};virtual_state=nil
        return true
    end
    function self.get_zombies()
        local result={}
        if not session and not prematch or status.phase~='RUNNING' and status.phase~='PREMATCH' then return result end
        for _,entry in ipairs(owned)do
            if #result>=SETTINGS.max_active then break end
            if entry.ready and not entry.cleanup_requested and not gone(entry.actor) and dead(entry.actor)==false then
                result[#result+1]={key=entry.actor_name,actor=entry.actor,controller=entry.controller,generation=entry.generation,
                    no_nav_fallback=entry.no_nav_fallback==true}
            end
        end
        return result
    end
    function self.public_status()return status end
    function self.enable_controls()
        if controls then return true end
        if not SCRIPT_DIR then return false,'Own script directory unavailable' end
        local ok,module=pcall(dofile,SCRIPT_DIR..'controls.lua')
        if not ok or type(module)~='table' or type(module.new)~='function' then
            status.controls={ready=false,error='Own controls module is unavailable'};write();return false
        end
        local made,result=pcall(module.new,self,api,{log=log,directory=SCRIPT_DIR})
        if not made or type(result)~='table' or type(result.start)~='function' then
            status.controls={ready=false,error='Own controls initialization failed'};write();return false
        end
        local started,accepted=pcall(result.start)
        if not started or accepted==false then
            if type(result.shutdown)=='function' then pcall(result.shutdown) end
            status.controls={ready=false,error='Own controls could not start'};write();return false
        end
        controls=result;status.controls={ready=true};write();return true
    end
    function self.status()return status end
    status.capabilities.spectator_adapter=type(elimination_handler)=='function'
    if SCRIPT_DIR and type(io)=='table' and type(io.open)=='function' then
        local f=io.open(SCRIPT_DIR..'controls.lua','rb')
        if f then f:close();self.enable_controls() end
    end
    write();return self
end
return Module
