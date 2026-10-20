-- Z-Deathmatch weather: host-only, caller-clocked, no timers and no OnRep calls.
local Module={}
local DURATION=300
local RAIN='/Game/UltraDynamicSky/Blueprints/Weather_Effects/Weather_Presets/Rain.Rain'
local function read(o,k)
    if o==nil then return false,nil end
    return pcall(function()return o[k]end)
end
local function get(o,k)local ok,v=read(o,k);if ok then return v end end
local function call(o,k,...)
    if o==nil then return false,'missing receiver' end
    local args=table.pack(...);local got,member=read(o,k)
    if got and member~=nil then return pcall(member,o,table.unpack(args,1,args.n)) end
    local ok,mt=pcall(getmetatable,o);local method=ok and type(mt)=='table' and rawget(mt,k)
    if type(method)=='function' then return pcall(method,o,table.unpack(args,1,args.n)) end
    return false,tostring(member or 'method unavailable'):sub(1,200)
end
local function valid(o)local ok,v=call(o,'IsValid');return ok and v==true end
local function name(o)local ok,v=call(o,'GetFullName');return ok and type(v)=='string' and v or nil end
local function finite(n)return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function identical(a,b)
    if not valid(a) or not valid(b) then return false end
    if rawequal(a,b) then return true end
    local aa,av=call(a,'GetAddress');local ba,bv=call(b,'GetAddress')
    return aa and ba and type(av)=='number' and av~=0 and av==bv
end
local function unwrap(v)local ok,result=call(v,'get');return ok and result or v end
local function level_in_world(level,world)
    local array=get(world,'Levels');local counted,n=call(array,'GetArrayNum')
    if not counted or not finite(n) or n<0 or n>512 or n%1~=0 then return false,'World Levels count is unavailable or exceeds512' end
    local found,visited=false,0
    local iterated=call(array,'ForEach',function(_,element)
        visited=visited+1
        if identical(unwrap(element),level) then found=true;return true end
        return visited>=n
    end)
    if iterated then return found,found and 'world_levels' or 'Level is absent from the active World Levels' end
    -- Native TArray methods may be masked by __index; call() already tries its metatable.
    for i=1,n do if identical(unwrap(get(array,i)),level) then return true,'world_levels' end end
    return false,'Level is absent from the active World Levels'
end
local function same(a,b)
    if a==nil or not valid(a) then return b==nil or not valid(b) end
    return valid(b) and name(a)==name(b)
end
function Module.new(api,options)
    api,options=api or {},options or {}
    local self={};local state;local closed=false
    local report={version='0.2.1',phase='IDLE',active=false,restore_pending=false,
        method='caller_realtime_1hz_original_sky_tick',duration_seconds=DURATION,start_time=1800,end_time=600,rain_path=RAIN,
        rain_available=false,rain_verified=false}
    local function fail(reason)
        report.reason=reason
        if options.log then pcall(options.log,'Weather: '..reason) end
        return false,reason
    end
    local find_all=api.FindAllOf or FindAllOf
    local find_object=api.StaticFindObject or StaticFindObject
    local load_asset=api.LoadAsset or LoadAsset
    local function current_world()
        if type(find_all)~='function' then return nil end
        local ok,list=pcall(find_all,'GameViewportClient')
        if ok and type(list)=='table' then
            for i,vp in ipairs(list) do if i>8 then break end;local w=get(vp,'World');if valid(w) then return w end end
        end
    end
    local function authoritative(world)
        if not valid(world) or not valid(get(world,'AuthorityGameMode')) then return false,'Local world authority is required' end
        local ok,driver=read(world,'NetDriver')
        if not ok then return false,'World network state is unreadable' end
        if valid(driver) then
            local got,server=read(driver,'ServerConnection')
            if not got or valid(server) then return false,'Remote clients cannot change round weather' end
        end
        return true
    end
    local function belongs(actor,world)
        if not valid(actor) or not valid(world) then return false,'Invalid actor or world' end
        local n=name(actor) or ''
        if n:find('Default__',1,true) or n:find('Archetype',1,true) then return false,'Template actor' end
        local ok,w=call(actor,'GetWorld')
        if ok and identical(w,world) then return true,'actor_world' end
        local got,level=call(actor,'GetLevel')
        if not got or not valid(level) then return false,'Actor Level is unavailable' end
        if identical(get(level,'OwningWorld'),world) then return true,'level_owning_world' end
        return level_in_world(level,world)
    end
    local function candidates(class,world)
        local result={};local details={loaded_count=0,world_count=0,truncated=false,membership={}}
        if type(find_all)~='function' then details.error='FindAllOf unavailable';return result,details end
        local ok,list=pcall(find_all,class)
        if ok and type(list)=='table' then
            details.loaded_count=#list;details.truncated=#list>64
            for i,actor in ipairs(list) do
                if i>64 then break end
                local accepted,proof=belongs(actor,world)
                details.membership['actor_'..i]={object=name(actor),accepted=accepted,proof=proof}
                if accepted then result[#result+1]=actor end
            end
        elseif not ok then details.error=tostring(list):sub(1,200)
        elseif list~=nil then details.error='Unexpected actor inventory result' end
        details.world_count=#result
        return result,details
    end
    local function discover(world)
        local skies,sky_info=candidates('Ultra_Dynamic_Sky_C',world)
        local weather,weather_info=candidates('Ultra_Dynamic_Weather_C',world)
        local details={sky=sky_info,weather=weather_info}
        if sky_info.truncated or sky_info.error then
            details.reason='Sky discovery is incomplete';return nil,nil,skies,weather,details
        end
        local pairs_found={}
        for _,sky in ipairs(skies) do for _,rain in ipairs(weather) do
            if same(get(rain,'UltraDynamicSky'),sky) or same(get(sky,'Ultra Dynamic Weather'),rain) then
                pairs_found[#pairs_found+1]={sky=sky,weather=rain}
            end
        end end
        if #pairs_found==1 and not weather_info.truncated and not weather_info.error then
            return pairs_found[1].sky,pairs_found[1].weather,skies,weather,details
        end
        if #skies==1 then
            if #weather==1 and not weather_info.truncated and not weather_info.error then
                return skies[1],weather[1],skies,weather,details
            end
            details.rain_reason=#weather==0 and 'No UDW weather actor in this world' or 'Weather actor selection is ambiguous or incomplete'
            return skies[1],nil,skies,weather,details
        end
        details.reason=#skies==0 and 'No UDS sky in the active world; this map has no supported day cycle'
            or 'Sky actor selection is ambiguous'
        return nil,nil,skies,weather,details
    end
    local function rain_snapshot(weather)
        if not valid(weather) then return nil,'No unique weather actor is available' end
        local wa,w=read(weather,'Weather');local ra,r=read(weather,'Random Weather Variation')
        local da,d=read(weather,'Transition Duration')
        if not wa or not ra or not finite(r) or r%1~=0 or r<0 or r>255 then return nil,'Weather preset/random-variation fields are unreadable' end
        if not da or not finite(d) then return nil,'Weather transition duration is unreadable' end
        local ua,u=call(weather,'HasAuthority')
        if not ua or u~=true then return nil,'Weather actor server authority is required' end
        return {weather=weather,preset=valid(w) and w or nil,random=r,transition_duration=d}
    end
    local function snapshot(world,sky,weather)
        local ta,t=read(sky,'Time of Day');local aa,a=read(sky,'Animate Time of Day')
        local ma,m=read(sky,'Sun Mobility');local ca,c=read(sky,'Transitioning Time')
        local sa,system=read(sky,'Use System Time');local da,disabled=read(sky,'Disable All Runtime Updating')
        if not ta or not finite(t) or not aa or type(a)~='boolean' then return nil,'Sky time/animation fields are unreadable' end
        if not ma or m~=2 then return nil,'The sky sun must already be movable (Sun Mobility=2)' end
        if not ca or type(c)~='boolean' then return nil,'Existing sky transition state is unreadable' end
        if c then return nil,'An existing sky time transition is still running' end
        if not sa or type(system)~='boolean' or not da or type(disabled)~='boolean' then
            return nil,'Sky system-clock/runtime-update switches are unreadable'
        end
        local auth,s=call(sky,'HasAuthority')
        if not auth or s~=true then return nil,'Sky actor server authority is required' end
        local backup={world=world,world_name=name(world),sky=sky,time=t,animate=a,system_time=system,
            runtime_disabled=disabled,last_step=-1,last_elapsed=0,touched=false}
        local rain,why=rain_snapshot(weather)
        if rain then for k,v in pairs(rain)do backup[k]=v end else backup.rain_reason=why end
        return backup
    end
    local function set(o,k,v)
        local ok,err=pcall(function()o[k]=v end)
        if not ok then return false,tostring(err):sub(1,200) end
        local got,actual=read(o,k)
        if not got or actual~=v then return false,'Field readback failed: '..k end
        return true
    end
    local recapture
    local function set_time(s,t,force_capture)
        local ok,why=set(s.sky,'Time of Day',t);if not ok then return false,why end
        local ticked,te=call(s.sky,'Tick Function')
        if not ticked then return false,'Original sky Tick Function failed: '..tostring(te):sub(1,160) end
        local synced,err=call(s.sky,'Update Replicated Time')
        if not synced then return false,'Update Replicated Time failed: '..tostring(err):sub(1,160) end
        local actual=get(s.sky,'Time of Day')
        if not finite(actual) or math.abs(actual-t)>0.001 then return false,'Another sky controller replaced the requested time during its original tick' end
        report.time_of_day=actual;report.visual_updates=(report.visual_updates or 0)+1
        report.last_frame_time_of_day=get(s.sky,'Last Frame Time of Day')
        recapture(s,t,force_capture)
        return true
    end
    function self.inspect(world)
        world=world or current_world()
        local out={phase=report.phase,active=report.active,restore_pending=report.restore_pending,
            world=name(world),ready=false,reason=report.reason,sky_candidates={},weather_candidates={}}
        local auth,why=authoritative(world);out.authority=auth
        if not auth then out.reason=why;return out end
        local sky,weather,skies,rains,details=discover(world);out.discovery=details
        report.discovery=details
        for i,o in ipairs(skies) do out.sky_candidates['sky_'..i]=name(o) end
        for i,o in ipairs(rains) do out.weather_candidates['weather_'..i]=name(o) end
        if not sky then out.reason=details.reason;return out end
        out.sky={object=name(sky),time=get(sky,'Time of Day'),animate=get(sky,'Animate Time of Day'),
            sun_mobility=get(sky,'Sun Mobility'),transitioning=get(sky,'Transitioning Time'),
            use_system_time=get(sky,'Use System Time'),runtime_disabled=get(sky,'Disable All Runtime Updating'),
            replicated_time=get(sky,'Replicated Time of Day'),last_frame_time=get(sky,'Last Frame Time of Day')}
        if weather then out.weather={object=name(weather),preset=name(get(weather,'Weather')),random=get(weather,'Random Weather Variation'),
            transition_duration=get(weather,'Transition Duration')} end
        local backup,err=snapshot(world,sky,weather)
        out.ready=backup~=nil;out.reason=err;out.rain_available=backup~=nil and backup.weather~=nil
        out.rain_reason=details.rain_reason or (backup and backup.rain_reason)
        return out
    end
    local restore_validity_cdo,restore_validity_function
    local function restore_actor_lives(actor,require_native)
        if not valid(actor) then return false end
        if type(find_object)=='function' then
            if not valid(restore_validity_cdo) then
                local ok,value=pcall(find_object,'/Script/Engine.Default__KismetSystemLibrary')
                if ok then restore_validity_cdo=value end
            end
            if not valid(restore_validity_function) then
                local ok,value=pcall(find_object,'/Script/Engine.KismetSystemLibrary:IsValid')
                if ok then restore_validity_function=value end
            end
        end
        if valid(restore_validity_cdo) and valid(restore_validity_function) then
            -- StaticFindObject returns an unbound UFunction; its CDO is the explicit calling context.
            local ok,alive=call(restore_validity_function,'CallFunction',restore_validity_cdo,actor)
            if ok and type(alive)=='boolean' then
                if not alive then return false end
                local read,retired=call(actor,'IsActorBeingDestroyed')
                return not (read and retired==true)
            end
        end
        if require_native then return false end
        local flags=api.EInternalObjectFlags or EInternalObjectFlags
        if type(flags)=='table' then
            for _,flag in pairs({flags.PendingKill,flags.Unreachable})do
                if type(flag)=='number' and flag>0 and flag%1==0 then
                    local ok,retired=call(actor,'HasAnyInternalFlags',flag)
                    if ok and retired==true then return false end
                end
            end
        end
        local ok,retired=call(actor,'IsActorBeingDestroyed')
        return not (ok and retired==true)
    end
    local capture_function
    recapture=function(s,t,force)
        local elapsed=s.last_elapsed or 0
        if not force and s.last_capture_elapsed and elapsed-s.last_capture_elapsed<30 then return end
        s.last_capture_elapsed=elapsed
        report.skylight_capture_interval_seconds=30
        report.skylight_capture_attempts=(report.skylight_capture_attempts or 0)+1
        report.skylight_capture_visual_verified=false
        report.skylight_capture_requested=false
        local function warning(reason)
            report.skylight_capture_warning=reason
            if options.log and s.capture_warning~=reason then pcall(options.log,'Weather skylight: '..reason) end
            s.capture_warning=reason
        end
        if not restore_actor_lives(s.world,true) or not restore_actor_lives(s.sky,true) then
            warning('Native validity of the original sky and world could not be confirmed');return
        end
        local auth=authoritative(s.world)
        if not auth or not restore_actor_lives(get(s.world,'AuthorityGameMode'),true)
            or not belongs(s.sky,s.world) then warning('Sky capture requires its original authoritative world');return end
        local component=get(s.sky,'SkyLightComponent')
        if not restore_actor_lives(component,true) then warning('The UDS SkyLightComponent is unavailable');return end
        local got_owner,owner=call(component,'GetOwner')
        if not got_owner or not restore_actor_lives(owner,true) or not identical(owner,s.sky) or not belongs(owner,s.world) then
            warning('The sky capture component does not belong to the original UDS actor');return
        end
        -- The exact component owner already proves world membership through
        -- belongs(). Streamed actors and their components can expose different
        -- World wrappers, and Component.GetWorld may not be reflected at all.
        local source,mobility=get(component,'SourceType'),get(component,'Mobility')
        report.skylight_source_type=type(source)=='number' and source or nil
        report.skylight_mobility=type(mobility)=='number' and mobility or nil
        if source~=0 or mobility~=2 then warning('Sky capture requires a movable CapturedScene skylight');return end
        if not valid(capture_function) and type(find_object)=='function' then
            local found,value=pcall(find_object,'/Script/Engine.SkyLightComponent:RecaptureSky')
            if found then capture_function=value end
        end
        if not valid(capture_function) then warning('Native SkyLightComponent.RecaptureSky is unavailable');return end
        -- Native instance UFunction: the verified component is its calling context.
        local called,result=call(capture_function,'CallFunction',component)
        if not called or result==false then warning('Native sky recapture failed: '..tostring(result):sub(1,120));return end
        report.skylight_component=name(component)
        report.skylight_capture_source='native_recapture_sky'
        report.skylight_capture_requested=true
        report.skylight_captures=(report.skylight_captures or 0)+1
        report.skylight_last_capture_time_of_day=t;report.skylight_last_capture_elapsed_seconds=elapsed
        report.skylight_capture_warning=nil;s.capture_warning=nil
    end
    function self.restore()
        if not state then report.active=false;report.rain_verified=false;report.restore_pending=false;return true end
        local s=state;local failures={}
        -- Actors from an unloaded world no longer have state to restore.
        local sky_lives,weather_lives=restore_actor_lives(s.sky),restore_actor_lives(s.weather)
        if not sky_lives and not weather_lives then state=nil;report.active=false;report.rain_verified=false;report.restore_pending=false;report.phase='RESTORED';report.reason=nil;return true end
        local auth,why=authoritative(s.world)
        if not auth then return fail('Weather restoration refused: '..why) end
        if sky_lives then
            if not belongs(s.sky,s.world) then failures[#failures+1]='Sky moved to a different world'
            else
                -- Restore the exact time before returning control to the map's own clock.
                local quiet,qe=set(s.sky,'Animate Time of Day',false)
                local sys,se=set(s.sky,'Use System Time',false)
                local active,ue=set(s.sky,'Disable All Runtime Updating',false)
                if quiet and sys and active then
                    local ok,err=set_time(s,s.time,true);if not ok then failures[#failures+1]=err end
                else failures[#failures+1]=qe or se or ue or 'Sky clock could not be paused for restoration' end
                local animated,ae=set(s.sky,'Animate Time of Day',s.animate);if not animated then failures[#failures+1]=ae end
                local system,se=set(s.sky,'Use System Time',s.system_time);if not system then failures[#failures+1]=se end
                local disabled,de=set(s.sky,'Disable All Runtime Updating',s.runtime_disabled);if not disabled then failures[#failures+1]=de end
            end
        end
        if weather_lives then
            if not belongs(s.weather,s.world) then failures[#failures+1]='Weather actor moved to a different world'
            else
                local ok,err=call(s.weather,'Change Weather',s.preset,s.transition_duration)
                if not ok or not same(get(s.weather,'Weather'),s.preset) then failures[#failures+1]='Original weather preset could not be restored: '..tostring(err or '') end
                local random,re=set(s.weather,'Random Weather Variation',s.random);if not random then failures[#failures+1]=re end
                local duration,de=set(s.weather,'Transition Duration',s.transition_duration);if not duration then failures[#failures+1]=de end
            end
        end
        report.active=false;report.rain_verified=false
        if #failures>0 then report.phase='RESTORE_FAILED';report.restore_pending=true;return fail(table.concat(failures,'; ')) end
        state=nil;report.phase='RESTORED';report.restore_pending=false;report.reason=nil;return true
    end
    function self.start(world)
        if closed then return fail('Weather adapter is shut down') end
        if state then local restored,why=self.restore();if not restored then return false,why end end
        world=world or current_world()
        local live=current_world()
        if not live or not same(live,world) then return fail('The requested weather world is not the active viewport world') end
        local auth,why=authoritative(world);if not auth then return fail(why) end
        report.rain_available=false;report.rain_verified=false;report.rain_reason=nil
        local sky,weather,_,_,details=discover(world);report.discovery=details
        if not sky then return fail(details.reason) end
        local backup,err=snapshot(world,sky,weather);if not backup then return fail(err) end
        local rain
        if backup.weather then
            if type(find_object)=='function' then local ok,v=pcall(find_object,RAIN);if ok and valid(v) then rain=v end end
            if not rain and type(load_asset)=='function' then local ok,v=pcall(load_asset,RAIN);if ok and valid(v) then rain=v end end
            if not rain then backup.weather=nil;backup.rain_reason='The installed Rain weather preset could not be loaded' end
        end
        state=backup;state.rain=rain;state.touched=true
        local animated,ae=set(sky,'Animate Time of Day',false)
        local system,se=set(sky,'Use System Time',false)
        local disabled,de=set(sky,'Disable All Runtime Updating',false)
        local random,re,changed,ce=true,nil,true,nil
        if state.weather then
            random,re=set(state.weather,'Random Weather Variation',0)
            changed,ce=call(state.weather,'Change Weather',rain,2.0)
        end
        local time,te=set_time(state,1800.0,true)
        if not animated or not system or not disabled or not random or not changed
            or (state.weather and not same(get(state.weather,'Weather'),rain)) or not time then
            local reason=ae or se or de or re or (not changed and tostring(ce)) or te or 'Rain preset readback failed'
            self.restore();return fail('Weather setup failed: '..reason)
        end
        state.last_step=0;report.phase='RUNNING';report.active=true;report.restore_pending=true;report.reason=nil
        report.world=name(world);report.elapsed_seconds=0;report.rain_available=state.weather~=nil
        report.rain_verified=state.weather~=nil;report.rain_reason=details.rain_reason or state.rain_reason;return true
    end
    function self.tick(elapsed)
        if not state or not report.active then return false,'Weather is not active' end
        if not finite(elapsed) or elapsed<0 then return fail('Invalid round elapsed time') end
        local world=current_world()
        if not world then return fail('Active viewport world is unavailable') end
        if not same(world,state.world) then self.restore();return fail('Round weather world changed') end
        local auth,why=authoritative(state.world);if not auth then report.active=false;return fail(why) end
        if not belongs(state.sky,state.world) or (state.weather and not belongs(state.weather,state.world)) then report.active=false;return fail('Weather actors are no longer in the original world') end
        elapsed=math.min(DURATION,elapsed)
        if elapsed<state.last_elapsed then return fail('Round elapsed time moved backwards') end
        state.last_elapsed=elapsed;report.elapsed_seconds=elapsed
        local step=math.floor(elapsed)
        if step==state.last_step then return true end
        if get(state.sky,'Animate Time of Day')~=false or get(state.sky,'Use System Time')~=false
            or get(state.sky,'Disable All Runtime Updating')~=false
            or (state.weather and (get(state.weather,'Random Weather Variation')~=0 or not same(get(state.weather,'Weather'),state.rain))) then
            state.corrections=(state.corrections or 0)+1;report.conflict_corrections=state.corrections
            if state.corrections>3 then report.active=false;report.rain_verified=false;return fail('Another weather controller repeatedly overrides the round settings') end
            local a,ae=set(state.sky,'Animate Time of Day',false)
            local s,se=set(state.sky,'Use System Time',false)
            local d,de=set(state.sky,'Disable All Runtime Updating',false)
            local r,re,w,we=true,nil,true,nil
            if state.weather then
                r,re=set(state.weather,'Random Weather Variation',0)
                if not same(get(state.weather,'Weather'),state.rain) then w,we=call(state.weather,'Change Weather',state.rain,2.0) end
            end
            if not a or not s or not d or not r or not w or (state.weather and not same(get(state.weather,'Weather'),state.rain)) then
                report.active=false;report.rain_verified=false;return fail(ae or se or de or re or tostring(we or 'Rain restoration failed'))
            end
        end
        report.rain_verified=state.weather~=nil
        local t=(1800.0+1200.0*(step/DURATION))%2400.0
        local ok,err=set_time(state,t,elapsed>=DURATION)
        if not ok then report.active=false;return fail(err) end
        state.last_step=step
        if elapsed>=DURATION then report.active=false;report.phase='FINISHED' end
        return true
    end
    function self.finish()
        if not state then return false,'Weather has not started' end
        if report.phase=='FINISHED' then return true end
        return self.tick(DURATION)
    end
    function self.shutdown()
        local ok,why=self.restore();if ok then closed=true end;return ok,why
    end
    function self.status()return report end
    return self
end
return Module
