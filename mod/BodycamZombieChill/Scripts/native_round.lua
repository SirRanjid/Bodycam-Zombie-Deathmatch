-- Host-only score-cap, backed-up runtime phase duration and optional minimum-player CVar.
-- No player score, package-file, raw round-clock or TimerManager writes.
local M={}
local LIMIT=2147483647
local DURATION=300
local FORCE_CVAR='bc.ForceMinimalPlayerCountMeetCriteria'
local WAITING='Game.Phase.WaitingForPlayers'
local WARMUP='Game.Phase.RoundWarmup'
local PLAYING='Game.Phase.StartRound'
local function get(o,k)local ok,v=pcall(function()return o[k]end);if ok then return v end end
local function call(o,k,...)
    if o==nil then return false end
    local args=table.pack(...);local ok,f=pcall(function()return o[k]end)
    if ok and f~=nil then return pcall(f,o,table.unpack(args,1,args.n)) end
    local read,mt=pcall(getmetatable,o);f=read and type(mt)=='table' and rawget(mt,k)
    if type(f)=='function' then return pcall(f,o,table.unpack(args,1,args.n)) end
    return false
end
local function valid(o)local ok,v=call(o,'IsValid');return ok and v==true end
local function name(o)local ok,v=call(o,'GetFullName');return ok and type(v)=='string' and v or nil end
local function integer(v,a,b)return type(v)=='number' and v==v and v%1==0 and v>=a and v<=b end
local function finite(v)return type(v)=='number'and v==v and v~=math.huge and v~=-math.huge end
local function identity(o)local ok,v=call(o,'GetAddress');return ok and integer(v,1,math.maxinteger) and v or nil end
local function class_is(o,wanted)
    local ok,c=call(o,'GetClass');local seen={}
    for _=1,12 do
        local n=ok and name(c);if not n or seen[n] then return false end
        if n:match('([^./: ]+)$')==wanted then return true end
        seen[n]=true;ok,c=call(c,'GetSuperStruct')
    end
    return false
end
local function belongs(o,w)
    local got,level=call(o,'GetLevel');local read,owner=call(level,'GetOuter')
    local a,b=identity(owner),identity(w)
    return got and read and valid(owner) and a~=nil and a==b
end
function M.new(core,api,options)
    core,api,options=core or {},api or {},options or {}
    local self={};local state
    local info={active=false,restore_pending=false,duration_seconds=DURATION,
        native_timer_rewritten=false,native_timer_duration_verified=false,native_scores_written=false,configured_limit=LIMIT,
        game_thread_only=true,live_verified=false,criteria_source='native_engine_cvar',
        criteria_hook_registered=false,criteria_probe_calls=0,criteria_live_binding_verified=false,
        force_cvar_name=FORCE_CVAR,force_cvar_active=false,force_cvar_commands=0,
        force_cvar_optional=true,force_command_refused=false,native_start_unverified=true,
        phase_request_attempts=0,phase_bridge_attempts=0,phase_restore_pending=false}
    local function fail(s)info.error=s;if state then info.restore_pending=true end;return false,s end
    local function log(s)if type(options.log)=='function' then pcall(options.log,'[Z-Deathmatch native Runde] '..s)end end
    local validity_cdo,validity_function
    local function find(path)
        if type(api.StaticFindObject)~='function' then return nil end
        local ok,value=pcall(api.StaticFindObject,path);return ok and value or nil
    end
    local function gone(actor)
        if not valid(actor) then return true,'invalid' end
        if not valid(validity_cdo) then validity_cdo=find('/Script/Engine.Default__KismetSystemLibrary')end
        if not valid(validity_function) then validity_function=find('/Script/Engine.KismetSystemLibrary:IsValid')end
        if valid(validity_cdo) and valid(validity_function) then
            -- The UFunction is the receiver; its CDO is the explicit context.
            local read,alive=call(validity_function,'CallFunction',validity_cdo,actor)
            if read and type(alive)=='boolean' then
                info.validity_source='native_kismet';info.native_validity_error=nil
                if not alive then return true,'native_kismet_invalid' end
                local ok,destroying=call(actor,'IsActorBeingDestroyed')
                return ok and destroying==true,'IsActorBeingDestroyed'
            end
            info.native_validity_error=tostring(alive):sub(1,160)
        end
        info.validity_source='ue4ss_flags_fallback'
        -- UE4SS IsValid omits PendingKill. Use its engine-derived flag table and
        -- directly exposed flag query; never invent a numeric flag constant.
        local flags=api.EInternalObjectFlags or EInternalObjectFlags
        if type(flags)=='table' then
            for key,flag in pairs({PendingKill=flags.PendingKill,Unreachable=flags.Unreachable})do
                if type(flag)=='number' and flag>0 and flag%1==0 then
                    local read,pending=call(actor,'HasAnyInternalFlags',flag)
                    if read and pending==true then return true,key end
                end
            end
        end
        local ok,destroying=call(actor,'IsActorBeingDestroyed')
        return ok and destroying==true,'IsActorBeingDestroyed'
    end
    local function config_lives(object)
        if object==nil then return false end
        if not valid(validity_cdo)then validity_cdo=find('/Script/Engine.Default__KismetSystemLibrary')end
        if not valid(validity_function)then validity_function=find('/Script/Engine.KismetSystemLibrary:IsValid')end
        if not valid(validity_cdo)or not valid(validity_function)then return nil end
        -- Never look up a method on a cached old config before engine validity.
        local read,alive=call(validity_function,'CallFunction',validity_cdo,object)
        if read and type(alive)=='boolean'then return alive end
    end
    local function apply_duration(r)
        local asset=get(r.gs,'GameModeConfigDataAsset')
        if config_lives(asset)~=true then return false,'Native phase config validity is unavailable'end
        local n=name(asset);local id=identity(asset)
        if not id or not class_is(asset,'GameModeConfigDataAsset')or not n
            or not(n:match('/Game/GM/DATA/DataAsset/DA_GameModeDeathmatch%.DA_GameModeDeathmatch$')
                or n:match('/Game/GM/DATA/DataAsset/DA_GameModeTeamDeathmatch%.DA_GameModeTeamDeathmatch$'))then
            return false,'Only the current native Deathmatch phase config may be changed'
        end
        local phase=get(asset,'PhaseConfig');local current=get(phase,'PhaseDuration')
        if not finite(current)or current< -1 or current>86400 then return false,'Native phase duration is unreadable'end
        r.duration_configs=r.duration_configs or {}
        local backup=r.duration_configs[id]
        if not backup then
            backup={asset=asset,id=id,name=n,previous=current,changed=false};r.duration_configs[id]=backup
        elseif current~=DURATION and current~=backup.previous then
            return false,'Another system changed the backed-up native phase duration'
        end
        if current~=DURATION then
            backup.changed=true
            local wrote=pcall(function()phase.PhaseDuration=DURATION end)
            if not wrote or get(phase,'PhaseDuration')~=DURATION then return false,'Native phase duration write did not verify'end
        end
        local read,value=call(r.gs,'GetPhaseDuration')
        info.native_phase_duration_read=read and finite(value)
        info.native_phase_duration_seconds=finite(value)and value or nil
        if not read or value~=DURATION then return false,'Native GetPhaseDuration did not confirm three hundred seconds'end
        info.native_duration_config=n;info.native_duration_override_active=true
        info.native_duration_restore_pending=false
        return true
    end
    local function restore_duration(r)
        local failed=false
        for _,backup in pairs(r.duration_configs or {})do
            if backup.changed then
                local alive=config_lives(backup.asset)
                if alive==false then backup.changed=false
                elseif alive~=true then failed=true
                elseif identity(backup.asset)~=backup.id or name(backup.asset)~=backup.name then failed=true
                else
                    local phase=get(backup.asset,'PhaseConfig');local current=get(phase,'PhaseDuration')
                    if current==backup.previous then backup.changed=false
                    elseif current~=DURATION then failed=true
                    else
                        local wrote=pcall(function()phase.PhaseDuration=backup.previous end)
                        if wrote and get(phase,'PhaseDuration')==backup.previous then backup.changed=false else failed=true end
                    end
                end
            end
        end
        info.native_duration_restore_pending=failed
        if not failed then info.native_duration_override_active=false;return true end
        return false,'Original native phase duration could not be safely restored'
    end
    local function context(w)
        if not valid(w) or not name(w) or not identity(w) then return nil,'World unavailable' end
        local wn=name(w):lower()
        if wn:find('/lobby',1,true) or wn:find('mainmenu',1,true) or wn:find('default__',1,true) then return nil,'A gameplay world is required' end
        local gm,gs=get(w,'AuthorityGameMode'),get(w,'GameState')
        if not valid(gm) or not valid(gs) or not identity(gm) or not identity(gs)
            or not class_is(gm,'BodycamGameMode') or not class_is(gs,'BodycamGameState') then return nil,'Current native Bodycam authority objects unavailable' end
        if not belongs(gm,w) or not belongs(gs,w) then return nil,'Native authority objects belong to another world' end
        local a,ga=call(gm,'HasAuthority');local b,sa=call(gs,'HasAuthority')
        if not a or ga~=true or not b or sa~=true then return nil,'Host authority is required' end
        local raw=get(gs,'OverridenScoreLimit');local ok,effective=call(gs,'GetScoreLimit')
        if not integer(raw,-1,LIMIT) or not ok or not integer(effective,0,LIMIT) then return nil,'Native score-limit state is unreadable' end
        return {world=w,world_name=name(w),world_id=identity(w),gm=gm,gm_id=identity(gm),gs=gs,gs_id=identity(gs),gs_name=name(gs),previous=raw,previous_effective=effective}
    end
    local function round_status()
        if type(core.public_status)~='function' then return nil end
        local ok,s=pcall(core.public_status)
        if ok and type(s)=='table' and s.mode_name=='Z-Deathmatch'
            and (s.phase=='PREMATCH' or s.phase=='RUNNING') then return s end
    end
    local system_functions={}
    local function system_call(method,...)
        if not valid(validity_cdo) then validity_cdo=find('/Script/Engine.Default__KismetSystemLibrary')end
        local fn=system_functions[method]
        if not valid(fn) then fn=find('/Script/Engine.KismetSystemLibrary:'..method);system_functions[method]=fn end
        if not valid(validity_cdo) or not valid(fn) then return false end
        return call(fn,'CallFunction',validity_cdo,...)
    end
    local function read_force()
        local ok,value=system_call('GetConsoleVariableBoolValue',FORCE_CVAR)
        info.force_cvar_read=ok and type(value)=='boolean'
        if type(value)=='boolean'then info.force_cvar_value=value else info.force_cvar_value=nil end
        if ok and type(value)=='boolean' then return true,value end
        return false
    end
    local function current_world()
        if type(api.FindAllOf)~='function' then return nil end
        local found,vps=pcall(api.FindAllOf,'GameViewportClient')
        if found and type(vps)=='table' then for i,vp in ipairs(vps)do
            if i>8 then break end
            local w=get(vp,'World');if valid(w)then return w end
        end end
    end
    local function console_context(w,restoring)
        if not restoring and not round_status() then return nil,'The scoped Z-Deathmatch round is not active' end
        if not valid(w) or identity(w)~=identity(current_world())then return nil,'The bound world is not the current viewport world' end
        local gm,gs=get(w,'AuthorityGameMode'),get(w,'GameState')
        if gone(gm)or gone(gs)or not belongs(gm,w)or not belongs(gs,w)then return nil,'Current host authority objects unavailable' end
        local ga,g=call(gm,'HasAuthority');local sa,s=call(gs,'HasAuthority')
        if not ga or g~=true or not sa or s~=true then return nil,'A verified authoritative host is required' end
        local pub,public=call(gm,'IsPublicLobby');info.criteria_lobby_public_read=pub
        if pub and type(public)=='boolean'then info.criteria_lobby_public=public else info.criteria_lobby_public=nil end
        local lib=find('/Script/Engine.Default__GameplayStatics')
        local got,gi=call(lib,'GetGameInstance',w)
        if not got or not valid(gi)or not class_is(gi,'BodycamGI_C')then return nil,'Current Bodycam host GameInstance is unavailable' end
        local mode=get(gi,'GameMode');if mode==nil then mode=get(gi,'Gamemode')end
        local maximum=get(gi,'Session Max Players');info.criteria_game_mode=mode;info.criteria_max_players=maximum
        if mode~=2 or maximum~=6 then return nil,'The Z host Deathmatch and six-player session configuration is not verified' end
        local counted,count=call(lib,'GetNumPlayerControllers',w);local local_ok,locals=call(lib,'GetNumLocalPlayerControllers',w)
        info.criteria_player_count=counted and count or nil;info.criteria_local_count=local_ok and locals or nil
        if not counted or not integer(count,1,6)or not local_ok or not integer(locals,1,count)then return nil,'Host player count is unavailable or exceeds six' end
        local net_ok,driver=pcall(function()return w.NetDriver end)
        if not net_ok then return nil,'World networking is unreadable' end
        if valid(driver)then
            local read,server=pcall(function()return driver.ServerConnection end)
            if not read or valid(server)then return nil,'Remote client worlds are refused' end
            local peers_ok,peers=call(get(driver,'ClientConnections'),'GetArrayNum')
            info.criteria_peer_count_read=peers_ok and integer(peers,0,5)or false
            info.criteria_peer_count=peers_ok and peers or nil
            -- NetConnections and replicated controller counts settle on different
            -- frames during a join/leave. Bound each independently; their temporary
            -- difference does not change this verified world's host authority.
            if not peers_ok or not integer(peers,0,5)then return nil,'Host peer count is not safely bounded' end
        end
        for i=0,count-1 do
            local read,pc=call(lib,'GetPlayerController',w,i)
            if read and valid(pc)and belongs(pc,w)then
                local local_read,is_local=call(pc,'IsLocalController');local authority_read,authority=call(pc,'HasAuthority')
                if local_read and is_local==true and authority_read and authority==true then return {world=w,pc=pc,gm=gm,gs=gs}end
            end
        end
        return nil,'The local authoritative host controller is unavailable'
    end
    local function set_force(c,value)
        info.force_cvar_commands=info.force_cvar_commands+1
        local ok=system_call('ExecuteConsoleCommand',c.world,FORCE_CVAR..(value and ' 1'or ' 0'),c.pc)
        local read,actual=read_force()
        if not read or actual~=value then
            return false,ok and 'The native minimum-player CVar command was refused or unreadable'or 'The native console command failed',read,actual
        end
        info.force_cvar_write_verified=true
        return true,nil,read,actual
    end
    local function restore_force(r,next_world)
        -- A refused/unavailable optional command owns no CVar change. Do not
        -- overwrite another system's later value or execute a needless restore.
        if not r.force_changed and not r.force_uncertain then info.force_cvar_active=false;info.force_cvar_owned=false;return true end
        local read,value=read_force()
        if not read then return false,'The original minimum-player CVar is unreadable' end
        if value==r.previous_force then info.force_cvar_active=false;info.force_cvar_owned=false;return true end
        if value~=true or r.previous_force~=false then return false,'Another system changed the minimum-player CVar; refusing to overwrite it' end
        -- Console variables outlive old worlds. Restore only through the current
        -- verified local authoritative host, including a new host world on travel.
        local c,why=console_context(next_world or current_world(),true)
        if not c then return false,why end
        local ok,err=set_force(c,r.previous_force)
        if ok then info.force_cvar_active=false;info.force_cvar_owned=false end
        return ok,err
    end
    local function verify_criteria(r)
        info.criteria_probe_calls=info.criteria_probe_calls+1
        local read,result=call(r.gm,'MinimalPlayerCountMeetCriteria')
        info.criteria_effective_read=read;info.criteria_effective=read and result==true
        info.criteria_live_binding_verified=read and result==true
        info.native_start_unverified=not info.criteria_live_binding_verified
        info.native_start_pending=info.native_start_unverified
        if not info.criteria_live_binding_verified then return false,'The concrete native minimum-player criterion did not become true' end
        return true
    end
    local function tag_text(tag)
        local n=get(tag,'TagName');if type(n)=='string'then return n end
        local ok,s=call(n,'ToString');if ok and type(s)=='string'then return s end
    end
    local function phase_of(gs)
        local ok,tag=call(gs,'GetCurrentPhase');local actual=ok and tag_text(tag)or nil
        if actual and tag_text(get(gs,'CurrentPhase'))==actual then return actual end
    end
    local function write_phase(gs,tag)
        local make=api.FName or FName
        if make==nil then return false end
        local ok,n=pcall(make,tag);if not ok or n==nil then return false end
        local wrote=pcall(function()gs.CurrentPhase={TagName=n}end)
        return wrote and phase_of(gs)==tag
    end
    local function phase_issue(reason)
        info.native_phase_error=reason;info.native_start_unverified=true;info.native_start_pending=true
        return false,reason
    end
    local function countdown_snapshot(r,key)
        local component=get(r.gs,key)
        -- Missing or PendingKill components must be rejected before a native
        -- property/function lookup on that component can dereference it.
        if gone(component)or not identity(component)or not class_is(component,'CountdownComponent')then
            return nil,key..' component is unavailable'
        end
        local owner,actor=call(component,'GetOwner')
        local active,is_active=call(component,'IsTimerActive')
        local remaining,time=call(component,'GetRemainingTime')
        local ending=get(component,'CountdownEndTime')
        if not owner or identity(actor)~=r.gs_id
            or not active or type(is_active)~='boolean'or not finite(ending)
            or not remaining or not finite(time)then return nil,key..' state is unavailable' end
        return {key=key,component=component,id=identity(component),ending=ending,active=is_active,remaining=time}
    end
    local function same_countdown(r,t)
        if gone(t.component)then return false end
        local owner,actor=call(t.component,'GetOwner')
        return identity(get(r.gs,t.key))==t.id
            and identity(t.component)==t.id and owner and identity(actor)==r.gs_id
    end
    local function restore_phase(r)
        local backup=r.phase_restore
        if not backup then info.phase_restore_pending=false;return true end
        if gone(r.gs)then r.phase_restore=nil;info.phase_restore_pending=false;return true end
        if identity(r.gs)~=r.gs_id or identity(get(r.world,'GameState'))~=r.gs_id or not belongs(r.gs,r.world)then
            info.phase_restore_pending=true;return false,'Native phase backup belongs to an unavailable world'
        end
        local auth,authority=call(r.gs,'HasAuthority')
        if not auth or authority~=true then info.phase_restore_pending=true;return false,'Native phase restoration lost authority' end
        local current=phase_of(r.gs)
        if current==PLAYING then
            r.phase_restore=nil;info.phase_restore_pending=false;info.phase_backup_superseded_by_native_start=true
            return true
        end
        if backup.staged and current==WARMUP and backup.original_phase==WAITING then
            if not write_phase(r.gs,backup.original_phase)then info.phase_restore_pending=true;return false,'Original native phase tag did not restore'end
            current=phase_of(r.gs)
        end
        if current~=backup.original_phase then
            info.phase_restore_pending=true;return false,'Another system changed the staged native phase; refusing to overwrite it'
        end
        for _,t in ipairs(backup.timers)do
            if t.changed then
                if not same_countdown(r,t)then info.phase_restore_pending=true;return false,'Original countdown identity changed'end
                local read,active=call(t.component,'IsTimerActive');local ending=get(t.component,'CountdownEndTime')
                if not read or type(active)~='boolean'then info.phase_restore_pending=true;return false,'Original countdown activity is unreadable'end
                if ending~=t.ending or active~=t.active then
                    if ending~=0 and ending~=t.ending then info.phase_restore_pending=true;return false,'Another system changed the stopped countdown'end
                    local wrote=pcall(function()t.component.CountdownEndTime=t.ending end)
                    -- Do not reactivate a timer that was originally inactive.
                    if t.active then call(t.component,'OnRep_CountdownEndTime')end
                    local checked,actual=call(t.component,'IsTimerActive')
                    if not wrote or get(t.component,'CountdownEndTime')~=t.ending or not checked or actual~=t.active then
                        info.phase_restore_pending=true;return false,'Original countdown state did not restore'
                    end
                end
            end
        end
        r.phase_restore=nil;info.phase_restore_pending=false;return true
    end
    local function try_phase_start(r,status,w)
        local s=round_status()
        if type(status)~='table'or status.phase~='RUNNING'or not s or s.phase~='RUNNING'then return end
        local started,prematch,clock=s.started_at,s.prematch_started_at,s.clock_seconds
        if not finite(started)or not finite(prematch)or not finite(clock)
            or started<prematch+30 or clock<started then return end
        local key=tostring(r.world_id)..'|'..tostring(prematch)
        info.native_timer_duration_verified=r.native_timer_verified_key==key
        local phase=phase_of(r.gs);info.native_phase=phase
        local duration_read,duration=call(r.gs,'GetPhaseDuration')
        info.native_phase_duration_read=duration_read and finite(duration)
        info.native_phase_duration_seconds=finite(duration)and duration or nil
        if not duration_read or duration~=DURATION then return phase_issue('Native start requires a verified three-hundred-second duration')end
        if phase==PLAYING then
            info.native_start_unverified=false;info.native_start_pending=false;info.native_phase_error=nil
            if r.phase_restore then info.phase_backup_superseded_by_native_start=true end
            r.phase_restore=nil;info.phase_restore_pending=false
            if r.phase_round_key~=key then info.phase_start_source='observed_native_start_round' end
            r.phase_round_key=key;r.phase_attempted=true;return
        end
        if r.phase_round_key==key and r.phase_attempted then return end
        r.phase_round_key=key;r.phase_attempted=true
        info.native_phase_error=nil;info.phase_rollback_verified=nil
        if phase~=WAITING and phase~=WARMUP then return phase_issue('Native phase is not eligible for a scoped round-start request')end
        local c,why=console_context(w,false)
        if not c or identity(c.gm)~=r.gm_id or identity(c.gs)~=r.gs_id then return phase_issue(why or 'Native phase authority changed')end
        if (api.FName or FName)==nil then return phase_issue('Native phase FName constructor is unavailable')end
        local request=find('/Script/Bodycam.BodycamGameMode:RequestPhaseChange')
        if not valid(request)then return phase_issue('Native round-start request function is unavailable')end
        local timers={}
        for _,name in ipairs({'WaitingForPlayerCountdown','WarmupCountdown'})do
            local t,err=countdown_snapshot(r,name);if not t then return phase_issue(err)end
            timers[#timers+1]=t
        end
        local original_start=get(r.gs,'RoundStartTime')
        if not finite(original_start)then return phase_issue('Original native round-start time is unavailable')end
        -- Preserve strings/scalars, never a live CurrentPhase UScriptStruct view.
        r.phase_restore={original_phase=phase,staged=false,timers=timers}
        info.phase_original=phase;info.countdown_stop_source='native_game_countdown_stop_pattern'
        local function rollback(reason)
            local restored,err=restore_phase(r);info.phase_rollback_verified=restored
            return phase_issue(restored and reason or reason..'; '..tostring(err))
        end
        for _,t in ipairs(timers)do
            if t.active then
                t.changed=true
                local wrote=pcall(function()t.component.CountdownEndTime=0 end)
                -- This is the exact stop/update sequence in the native GS phase setter.
                local updated=wrote and call(t.component,'OnRep_CountdownEndTime')
                local read,active=call(t.component,'IsTimerActive')
                local remaining,time=call(t.component,'GetRemainingTime')
                if not updated or get(t.component,'CountdownEndTime')~=0 or not read or active~=false
                    or not remaining or time~=0 then return rollback('Native countdown stop did not verify')end
            end
        end
        info.waiting_countdown_inactive=true;info.warmup_countdown_inactive=true
        if phase==WAITING then
            r.phase_restore.staged=true;info.phase_bridge_attempts=info.phase_bridge_attempts+1
            if not write_phase(r.gs,WARMUP)then return rollback('Native phase staging did not verify')end
        end
        local make=api.FName or FName;local created,n=pcall(make,PLAYING)
        if not created or n==nil then return rollback('Native round-start tag construction failed')end
        info.phase_request_attempts=info.phase_request_attempts+1
        local called=call(request,'CallFunction',r.gm,{TagName=n})
        local actual=phase_of(r.gs);info.native_phase=actual;info.phase_request_call_ok=called
        if actual~=PLAYING then return rollback('The native GameMode did not enter StartRound')end
        -- The real native setter owns RoundStartTime, delegates and replication.
        -- Once it has entered play, never raw-write an older phase on mod cleanup.
        r.phase_restore=nil;info.phase_restore_pending=false;info.native_phase_error=nil
        info.phase_start_source=phase==WAITING and 'game_mode_request_with_reflected_waiting_bridge'or 'game_mode_request_from_native_warmup'
        info.native_round_start_time_before=original_start
        info.native_round_start_time=get(r.gs,'RoundStartTime')
        info.native_round_start_time_read=finite(info.native_round_start_time)
        info.native_start_unverified=false;info.native_start_pending=false
        r.native_timer_verified_key=key;info.native_timer_duration_verified=true
        log('Actual native StartRound entered through the scoped GameMode request')
    end
    function self.restore(next_world)
        if not state then info.active=false;info.restore_pending=false;return true end
        local r=state
        local phase_restored,phase_error=restore_phase(r)
        local force_restored,force_error=restore_force(r,next_world)
        local duration_restored,duration_error=restore_duration(r)
        -- Destroyed old-world instances need no restoration. Never find a new
        -- GameState by class/name during cleanup, which could touch another map.
        local removed,reason=gone(r.gs)
        if removed then
            if not phase_restored then return fail(phase_error)end
            if not force_restored then return fail(force_error) end
            if not duration_restored then return fail(duration_error)end
            state=nil;info.active=false;info.restore_pending=false;info.error=nil;info.restore_skipped_reason=reason
            return true
        end
        if not valid(r.world) or identity(r.world)~=r.world_id or identity(r.gs)~=r.gs_id
            or not belongs(r.gs,r.world) then return fail('Original GameState identity changed; map restart required') end
        local ok,authority=call(r.gs,'HasAuthority');if not ok or authority~=true then return fail('Original GameState no longer has authority') end
        local current=get(r.gs,'OverridenScoreLimit')
        if current~=LIMIT and current~=r.previous then return fail('Another system changed the score override; map restart required') end
        local wrote=current==r.previous or call(r.gs,'OverrideScoreLimit',r.previous)
        local read,value=call(r.gs,'GetScoreLimit')
        if not wrote or get(r.gs,'OverridenScoreLimit')~=r.previous or not read or value~=r.previous_effective then
            info.restore_pending=true;return fail('Original native score limit could not be restored')
        end
        if not force_restored then return fail(force_error..'; native score limit was restored') end
        if not phase_restored then return fail(phase_error..'; native score limit was restored')end
        if not duration_restored then return fail(duration_error..'; native score limit was restored')end
        state=nil;info.active=false;info.restore_pending=false;info.error=nil;info.restore_skipped_reason=nil
        log('Original per-world score limit restored')
        return true
    end
    function self.start(w)
        if not round_status()then return fail('The scoped Z-Deathmatch round is not active')end
        if state then
            if identity(w)==state.world_id and valid(state.gs) and identity(get(w,'GameState'))==state.gs_id
                and get(state.gs,'OverridenScoreLimit')==LIMIT then
                local valid_tick,tick_error=self.tick({phase='RUNNING'},w);if not valid_tick then return false,tick_error end
                verify_criteria(state)
                return true
            end
            local restored,why=self.restore(w);if not restored then return false,why end
        end
        local r,why=context(w);if not r then return fail(why) end
        local c,scope_error=console_context(w,false);if not c then return fail(scope_error)end
        if identity(c.gm)~=r.gm_id or identity(c.gs)~=r.gs_id then return fail('Native round identity changed')end
        local read_force_ok,previous_force=read_force()
        r.previous_force=previous_force;r.force_snapshot_read=read_force_ok
        state=r;info.restore_pending=true;info.restore_skipped_reason=nil;info.native_timer_duration_verified=false
        local duration_set,duration_error=apply_duration(r)
        if not duration_set then
            local restored=self.restore()
            return fail(restored and duration_error or duration_error..'; native cleanup pending')
        end
        info.force_cvar_original=previous_force;info.force_cvar_write_verified=false
        info.force_command_refused=false;info.force_cvar_warning=nil;info.force_cvar_owned=false
        local wrote=call(r.gs,'OverrideScoreLimit',LIMIT)
        local read,value=call(r.gs,'GetScoreLimit')
        if not wrote or get(r.gs,'OverridenScoreLimit')~=LIMIT or not read or value~=LIMIT then
            local restored=self.restore()
            return fail(restored and 'Native score-limit override was refused and restored' or 'Native score-limit override failed; cleanup pending')
        end
        local already_satisfied=verify_criteria(r)
        if read_force_ok and previous_force==false and not already_satisfied then
            local forced,force_error,read,actual=set_force(c,true)
            if not forced then
                if read and actual==false then
                    info.force_command_refused=true;info.force_cvar_warning=force_error
                    log('Optional native minimum-player command refused; independent mod round continues')
                else
                    r.force_uncertain=true
                    local restored=self.restore()
                    return fail(restored and 'Optional CVar outcome was unreadable and restored'or 'Optional CVar outcome is uncertain; native cleanup pending')
                end
            else
                r.force_changed=true;r.force_enforced=true;info.force_cvar_owned=true
            end
        elseif not read_force_ok then info.force_cvar_warning='Optional native minimum-player CVar is unavailable; no command attempted'
        elseif previous_force==true then r.force_enforced=true
        end
        info.force_cvar_active=r.force_enforced==true
        verify_criteria(r)
        info.active=true;info.restore_pending=false;info.error=nil;info.world=r.world_name
        info.previous_override=r.previous;info.previous_effective=r.previous_effective
        log('Per-world native score limit raised and phase duration set for the independent 300-second round')
        return true
    end
    function self.tick(status,w)
        if not state then return fail('Native round adapter is not active') end
        if type(status)~='table' or status.phase~='RUNNING' and status.phase~='PREMATCH' then return self.restore() end
        if identity(w)~=state.world_id or not valid(state.gs) or identity(get(w,'GameState'))~=state.gs_id
            or not valid(state.gm) or identity(get(w,'AuthorityGameMode'))~=state.gm_id
            or not belongs(state.gs,w) or not belongs(state.gm,w) then
            return fail('Native round changed world or GameState')
        end
        local ok,authority=call(state.gs,'HasAuthority');local a,gm_authority=call(state.gm,'HasAuthority')
        local read,value=call(state.gs,'GetScoreLimit')
        if not ok or authority~=true or not a or gm_authority~=true or not read or value~=LIMIT or get(state.gs,'OverridenScoreLimit')~=LIMIT then
            return fail('Native score-limit override no longer verified')
        end
        local c,why=console_context(w,true);if not c then return fail(why)end
        local duration_set,duration_error=apply_duration(state)
        if not duration_set then return fail(duration_error)end
        local force_read,forced=read_force()
        if state.force_enforced and (not force_read or forced~=true)then return fail('Native minimum-player CVar is no longer verified')end
        verify_criteria(state)
        try_phase_start(state,status,w)
        return true
    end
    function self.finish()
        -- Keep the native score cap disabled between our timed rounds, too.
        if not state then return false,'Native round adapter is not active' end
        return self.tick({phase='RUNNING'},state.world)
    end
    function self.shutdown()return self.restore()end
    function self.status()return info end
    return self
end
return M
