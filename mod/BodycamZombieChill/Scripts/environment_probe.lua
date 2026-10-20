-- Read-only current-world environment inventory; never loads assets or calls sky setters.
local Module={}
local function read(o,k)
    if o==nil then return false,nil end
    return pcall(function()return o[k]end)
end
local function get(o,k)local ok,v=read(o,k);if ok then return v end end
local function call(o,k,...)
    local a=table.pack(...);local ok,f=read(o,k)
    if ok and f~=nil then return pcall(f,o,table.unpack(a,1,a.n)) end
    local mt_ok,mt=pcall(getmetatable,o);f=mt_ok and type(mt)=='table' and rawget(mt,k)
    if type(f)=='function' then return pcall(f,o,table.unpack(a,1,a.n)) end
    return false,'method unavailable'
end
local function valid(o)local ok,v=call(o,'IsValid');return ok and v==true end
local function name(o)local ok,v=call(o,'GetFullName');return ok and type(v)=='string' and v or nil end
local function identical(a,b)
    if not valid(a)or not valid(b)then return false end
    if rawequal(a,b)then return true end
    local aa,av=call(a,'GetAddress');local ba,bv=call(b,'GetAddress')
    return aa and ba and type(av)=='number'and av~=0 and av==bv
end
local function unwrap(v)local ok,result=call(v,'get');return ok and result or v end
local function membership(actor,world)
    local detail={}
    local got,w=call(actor,'GetWorld');detail.get_world_ok=got;detail.world=name(w)
    if got and identical(w,world)then detail.proof='actor_world';return true,detail end
    local read,level=call(actor,'GetLevel');detail.get_level_ok=read;detail.level=name(level)
    if not read or not valid(level)then detail.reason='Actor Level is unavailable';return false,detail end
    local owner=get(level,'OwningWorld');detail.level_owning_world=name(owner)
    if identical(owner,world)then detail.proof='level_owning_world';return true,detail end
    local array=get(world,'Levels');local counted,n=call(array,'GetArrayNum')
    if not counted or type(n)~='number'or n<0 or n>512 or n%1~=0 then
        detail.reason='World Levels count is unavailable or exceeds512';return false,detail
    end
    detail.world_levels_count=n;local found,visited=false,0
    local iterated=call(array,'ForEach',function(_,element)
        visited=visited+1
        if identical(unwrap(element),level)then found=true;return true end
        return visited>=n
    end)
    if not iterated then
        for i=1,n do if identical(unwrap(get(array,i)),level)then found=true;break end end
    end
    if found then detail.proof='world_levels';return true,detail end
    detail.reason='Level is absent from the active World Levels';return false,detail
end
local function field(o,k)
    local ok,v=read(o,k);local r={read_ok=ok,type=ok and type(v) or nil}
    if not ok then r.error=tostring(v):sub(1,200)
    elseif type(v)=='string' or type(v)=='boolean' or type(v)=='number' then r.value=v
    elseif valid(v) then r.object=name(v)end
    return r
end
function Module.new(core,api)
    api=api or {};local self={}
    local find_all=api.FindAllOf or FindAllOf
    local find_object=api.StaticFindObject or StaticFindObject
    local function all(class)
        if type(find_all)~='function' then return {},'FindAllOf unavailable' end
        local ok,v=pcall(find_all,class)
        if not ok then return {},tostring(v):sub(1,200)end
        if v==nil then return {}end
        if type(v)~='table' then return {},'Unexpected FindAllOf result type' end
        return v
    end
    local function scan(class,world,fields,symbols)
        local list,err=all(class)
        local r={class=class,loaded_count=#list,matching_world_count=0,actors={},scan_error=err,truncated=#list>64}
        for i,o in ipairs(list)do
            if i>64 then break end
            local n=name(o);local entry={valid=valid(o),object=n,fields={}}
            local accepted,proof=membership(o,world)
            for k,v in pairs(proof)do entry[k]=v end
            entry.same_world=accepted
            entry.template=n~=nil and (n:find('Default__',1,true)~=nil or n:find('Archetype',1,true)~=nil)
            if entry.valid and entry.same_world and not entry.template then
                r.matching_world_count=r.matching_world_count+1
                for _,k in ipairs(fields)do entry.fields[k]=field(o,k)end
                local auth,a=call(o,'HasAuthority');entry.authority_read=auth;entry.authority=a==true
                local dying,d=call(o,'IsActorBeingDestroyed');entry.destroying_read=dying;entry.destroying=dying and d==true
                local life,l=call(o,'GetLifeSpan');entry.lifespan_read=life;entry.lifespan=life and type(l)=='number' and l or nil
                entry.internal_flags={}
                local flag_table=api.EInternalObjectFlags or EInternalObjectFlags
                if type(flag_table)=='table' then for _,key in ipairs({'PendingKill','Unreachable','Garbage'})do
                    local flag=flag_table[key]
                    if type(flag)=='number' then
                        local got,value=call(o,'HasAnyInternalFlags',flag)
                        entry.internal_flags[key]={flag=flag,read=got,value=got and value==true or false}
                    end
                end end
                local cn,c=call(o,'GetClass');entry.class=cn and name(c)or nil
                entry.symbols={}
                for key,path in pairs(symbols)do
                    local ok,f=false,nil
                    if type(find_object)=='function' then ok,f=pcall(find_object,path)end
                    entry.symbols[key]=ok and valid(f)
                end
                if class=='Ultra_Dynamic_Sky_C'then
                    entry.light_components={}
                    for _,key in ipairs({'Sun_LightComponent','Moon_LightComponent','SkyLightComponent'})do
                        local component=get(o,key)
                        local owned,owner=call(component,'GetOwner')
                        local light={object=name(component),same_owner=owned and identical(owner,o),fields={}}
                        if light.same_owner then
                            local world_read,component_world=call(component,'GetWorld')
                            light.component_world_read=world_read
                            light.component_world=world_read and name(component_world) or nil
                            light.component_world_error=not world_read and tostring(component_world):sub(1,160) or nil
                            for _,property in ipairs({'Intensity','Mobility','bVisible','bAffectsWorld','bRealTimeCapture','SourceType','Cubemap'})do
                                light.fields[property]=field(component,property)
                            end
                            local rotated,rotation=call(component,'K2_GetComponentRotation')
                            light.rotation_read=rotated
                            if rotated then
                                light.rotation={pitch=get(rotation,'Pitch'),yaw=get(rotation,'Yaw'),roll=get(rotation,'Roll')}
                            end
                        end
                        entry.light_components[key]=light
                    end
                end
            end
            r.actors['actor_'..i]=entry
        end
        return r
    end
    function self.report(requested_world)
        local out={version='0.1.0',read_only=true,viewports={},world_found=false}
        local vps,err=all('GameViewportClient');out.viewport_error=err
        local world
        for i,vp in ipairs(vps)do
            if i>8 then out.viewports_truncated=true;break end
            local w=get(vp,'World');out.viewports['viewport_'..i]={object=name(vp),world=name(w),valid_world=valid(w)}
            if not world and valid(w)then world=w end
        end
        if requested_world~=nil then
            if not valid(requested_world) or not world or name(requested_world)~=name(world)then
                out.reason='Requested world is not the active viewport world';return out
            end
            world=requested_world
        end
        if not world then out.reason='No active viewport world';return out end
        out.world_found=true;out.world=name(world);out.authority_game_mode=name(get(world,'AuthorityGameMode'))
        out.network={driver=name(get(world,'NetDriver')),server_connection=name(get(get(world,'NetDriver'),'ServerConnection'))}
        local state=get(world,'GameState');local limit_read,limit=call(state,'GetScoreLimit')
        local remaining_read,remaining=call(state,'GetRoundRemainingTime')
        out.native_round={game_state=name(state),score_limit_read=limit_read,
            effective_score_limit=limit_read and type(limit)=='number' and limit or nil,
            score_limit_override=field(state,'OverridenScoreLimit'),
            remaining_read=remaining_read,remaining_seconds=remaining_read and type(remaining)=='number' and remaining or nil,
            game_mode_config=name(get(get(world,'AuthorityGameMode'),'ConfigDataAsset')),
            game_state_config=name(get(state,'GameModeConfigDataAsset'))}
        local phase_read,phase=call(state,'GetCurrentPhase')
        local phase_name=phase_read and get(phase,'TagName') or nil
        local phase_string,phase_text=call(phase_name,'ToString')
        out.native_round.phase_read=phase_read
        out.native_round.phase=phase_string and phase_text or type(phase_name)=='string' and phase_name or nil
        out.native_round.countdowns={}
        for _,key in ipairs({'WaitingForPlayerCountdown','WarmupCountdown'})do
            local component=get(state,key)
            local active_read,active=call(component,'IsTimerActive')
            local time_read,seconds=call(component,'GetRemainingTime')
            out.native_round.countdowns[key]={object=name(component),
                end_time=field(component,'CountdownEndTime'),active_read=active_read,
                active=active_read and active==true,remaining_read=time_read,
                remaining_seconds=time_read and type(seconds)=='number' and seconds or nil}
        end
        local criteria_ok,criteria=call(get(world,'AuthorityGameMode'),'MinimalPlayerCountMeetCriteria')
        local empty_ok,empty=call(state,'HasTeamWithoutHumanPlayer')
        out.native_round.minimum_players_read=criteria_ok;out.native_round.minimum_players_met=criteria_ok and criteria==true
        out.native_round.empty_team_read=empty_ok;out.native_round.has_team_without_human=empty_ok and empty==true
        local duration_read,duration=call(state,'GetPhaseDuration')
        out.native_round.duration_read=duration_read
        if type(duration)=='number' then out.native_round.duration_seconds=duration end
        out.native_round.round_start_time=field(state,'RoundStartTime')
        out.native_round.round_configuration={}
        for _,method in ipairs({'GetMaxRound','GetCurrentRound','GetEndRoundDuration'})do
            local ok,value=call(state,method)
            out.native_round.round_configuration[method]={read=ok,value=type(value)=='number' and value or nil}
        end
        local ui=get(state,'GamemodeUIData')
        local tabs=get(ui,'EndGameTabs_45_E1C78F2B43BFBA40A7E27290A64036EC')
        local tag_array=get(tabs,'GameplayTags')
        local counted,tag_count=call(tag_array,'GetArrayNum')
        out.native_round.end_game_ui={data_type=type(ui),tabs_type=type(tabs),tags_read=counted,tags={}}
        if counted and type(tag_count)=='number' and tag_count>=0 and tag_count<=32 then
            call(tag_array,'ForEach',function(i,element)
                local tag=unwrap(element);local read,value=call(get(tag,'TagName'),'ToString')
                if read and type(value)=='string' then out.native_round.end_game_ui.tags['tag_'..tostring(i)]=value end
            end)
        end
        for _,key in ipairs({'bIsVotingOpen','VoteMapTimerMax','EndVoteTimestamp'})do
            out.native_round.end_game_ui[key]=field(state,key)
        end
        local maps_read,maps_count=call(get(state,'MapsToVote'),'GetArrayNum')
        out.native_round.end_game_ui.maps_read=maps_read
        out.native_round.end_game_ui.maps_count=type(maps_count)=='number' and maps_count or nil
        local driver=get(world,'NetDriver')
        local peer_read,peers=call(get(driver,'ClientConnections'),'GetArrayNum')
        out.native_round.peer_count_read=peer_read
        out.native_round.peer_count=type(peers)=='number' and peers or nil
        local lib_found,lib=false,nil
        if type(find_object)=='function' then lib_found,lib=pcall(find_object,'/Script/Engine.Default__GameplayStatics')end
        if lib_found and valid(lib)then
            local counted,players=call(lib,'GetNumPlayerControllers',world)
            out.native_round.player_count_read=counted
            out.native_round.player_count=type(players)=='number' and players or nil
        end
        local gm=get(world,'AuthorityGameMode');local public_read,is_public=call(gm,'IsPublicLobby')
        out.native_round.public_lobby_read=public_read
        if type(is_public)=='boolean' then out.native_round.public_lobby=is_public end
        if type(find_object)=='function' then
            local path='/Script/Bodycam.BodycamGameMode:MinimalPlayerCountMeetCriteria'
            local found,fn=pcall(find_object,path)
            out.native_round.criteria_symbol_found=found and valid(fn)
            out.native_round.criteria_symbol=found and name(fn) or nil
        end
        local flag_table=api.EInternalObjectFlags or EInternalObjectFlags
        out.cleanup_api={flags_type=type(flag_table),flags={}}
        if type(flag_table)=='table' then for _,key in ipairs({'PendingKill','Unreachable','Garbage'})do
            out.cleanup_api.flags[key]={type=type(flag_table[key]),value=type(flag_table[key])=='number' and flag_table[key] or nil}
        end end
        if type(find_object)=='function' then
            local found_cdo,cdo=pcall(find_object,'/Script/Engine.Default__KismetSystemLibrary')
            local found_fn,fn=pcall(find_object,'/Script/Engine.KismetSystemLibrary:IsValid')
            if found_cdo and found_fn and valid(cdo) and valid(fn) then
                local force_read,force_value=call(cdo,'GetConsoleVariableBoolValue','bc.ForceMinimalPlayerCountMeetCriteria')
                out.native_round.force_minimum_read=force_read
                if type(force_value)=='boolean' then out.native_round.force_minimum_value=force_value end
                local read,value=call(fn,'CallFunction',cdo,state)
                local null_read,null_value=call(fn,'CallFunction',cdo,nil)
                out.cleanup_api.native_valid_state={read=read,type=type(value),value=type(value)=='boolean' and value or nil,error=not read and tostring(value):sub(1,200) or nil}
                out.cleanup_api.native_valid_null={read=null_read,type=type(null_value),value=type(null_value)=='boolean' and null_value or nil,error=not null_read and tostring(null_value):sub(1,200) or nil}
                if type(value)=='boolean' then out.cleanup_api.native_valid_state.value=value end
                if type(null_value)=='boolean' then out.cleanup_api.native_valid_null.value=null_value end
            end
        end
        out.zombie_actors=scan('BP_NormalZombie_C',world,{'WW_SurvivorStatus','bReplicates'}, {})
        out.zombie_controllers=scan('AIC_Zombie_C',world,{}, {})
        if type(core)=='table' and type(core.public_status)=='function'then
            local got,s=pcall(core.public_status)
            if got and type(s)=='table'then out.round={phase=s.phase,mode=s.mode_name,world=s.world,elapsed_seconds=s.elapsed_seconds}end
        end
        out.sky=scan('Ultra_Dynamic_Sky_C',world,
            {'Time of Day','Replicated Time of Day','Animate Time of Day','Transitioning Time','Sun Mobility',
             'Sky Light Mobility','bReplicates','bAlwaysRelevant','NetDormancy','Ultra Dynamic Weather','Run Context','Use System Time',
             'Disable All Runtime Updating','Last Frame Time of Day','Time Cycle Degrees','Sun Pitch','Sun Yaw','Simulate Real Sun',
             'Custom Sun Light Actor','Custom Sky Light Actor','Project Mode','Render Sun Directional Light','Render Sky Light',
             'Real Time Capture','Sky Light Mode','Lighting Brightness (Night)','Apply Exposure Settings','Exposure Bias Night',
             'Current Scene Lighting Brightness Scale','Dynamic Sky Light Multiplier'},
            {replicated_time='/Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Sky.Ultra_Dynamic_Sky_C:Update Replicated Time',
             time_transition='/Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Sky.Ultra_Dynamic_Sky_C:Transition Time of Day',
             tick_function='/Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Sky.Ultra_Dynamic_Sky_C:Tick Function',
             update_lights='/Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Sky.Ultra_Dynamic_Sky_C:Update Directional Light Rotations'})
        out.weather=scan('Ultra_Dynamic_Weather_C',world,
            {'Weather','Random Weather Variation','Transition Duration','Transition Active','bReplicates','bAlwaysRelevant','UltraDynamicSky'},
            {change_weather='/Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Weather.Ultra_Dynamic_Weather_C:Change Weather'})
        out.day_cycle_available=out.sky.matching_world_count==1 and not out.sky.truncated
        out.rain_available=out.weather.matching_world_count==1 and not out.weather.truncated
        if not out.day_cycle_available then out.reason=out.sky.matching_world_count==0 and 'No UDS sky in the active world' or 'Sky actor selection is ambiguous' end
        return out
    end
    return self
end
return Module
