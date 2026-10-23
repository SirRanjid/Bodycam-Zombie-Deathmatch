-- One daylight time per loaded World. Indoor maps retain their native lighting.
-- Prematch/match phases do not reseed the selected time.
local M={}
local START_MINUTE=18*60
local WINDOW_MINUTES=0
local INVENTORY_INTERVAL=5
local FOG_COLOR_FIELD='Fog Color Intensity Scale'
local FOG_COLOR_MULTIPLIER=0.5
local FOG_START_FIELD='Fog Start Distance when Clear'
-- Native non-Net input, preserving the density/interior-dependent fog curve.
-- At the observed density 0.07311 and native threshold 0.1: 17.66m -> about 10m.
local FOG_START_MULTIPLIER=0.5661619537183734
local FOG_RAMP_FIELDS={'Scale Fog Density','Fog Density where Start Distance Reaches Zero'}
local FOG_RAMP_MULTIPLIER=0.35
local SKYLIGHT_FIELD='Sky Light Intensity'
local SKYLIGHT_MULTIPLIER=1.10
-- Current native ExponentialHeightFogComponent reflection; all distances are cm.
local FOG_DISTANCE_FIELDS={{'bEnableVolumetricFog','component_volumetric','boolean'},
    {'StartDistance','start_cm'},{'EndDistance','end_cm'},{'FogCutoffDistance','cutoff_cm'},
    {'VolumetricFogStartDistance','volumetric_start_cm'},
    {'VolumetricFogNearFadeInDistance','volumetric_near_fade_cm'},
    {'VolumetricFogDistance','volumetric_view_cm'},
    {'FogDensity','density'},{'FogHeightFalloff','height_falloff'},{'FogMaxOpacity','max_opacity'}}
local WEATHER_CLASS='/Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Weather.Ultra_Dynamic_Weather_C'
local DIRTY='/Script/Engine.NetPushModelHelpers:MarkPropertyDirtyFromRepIndex'
local DIRTY_CDO='/Script/Engine.Default__NetPushModelHelpers'
-- Current pakchunk41 reflection: these six scalar fields are Net properties.
-- Keep the native profile, random weather and every other override untouched.
local WEATHER_FIELDS={{name='Cloud Coverage',index=11,value=10},{name='Cloud Coverage - Manual Override',index=12,value=true},
    {name='Rain',index=13,value=7.5},{name='Rain - Manual Override',index=14,value=true},
    {name='Fog',index=21,value=9},{name='Fog - Manual Override',index=22,value=true}}
local function finite(n)return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
function M.new(runtime,options)
    options=options or {};local self={};local world_id,minute,sky_id,backup;local last_update
    local weather_id,weather_backup,last_weather_update,weather_pending
    local sky_cache,weather_cache,next_weather_probe,weather_failures,last_weather_sky_id
    local color_id,color_original,color_target,color_pending,next_color_probe,color_failures
    local start_id,start_original,start_target,start_pending,next_start_probe,last_start_probe,start_failures
    local ramp_id,ramp_original,ramp_target,ramp_pending,next_ramp_probe,last_ramp_probe,ramp_failures
    local skylight_id,skylight_original,skylight_target,skylight_pending,next_skylight_probe,last_skylight_probe,skylight_failures
    local next_fog_distance_probe,last_fog_distance_probe
    local report={phase='IDLE',live_replication_verified=false,weather_phase='IDLE',weather_live_replication_verified=false,
        fog_color_phase='IDLE',fog_color_scope='HOST_ONLY',fog_color_replicated=false,fog_color_multiplier=FOG_COLOR_MULTIPLIER,
        fog_start_phase='IDLE',fog_start_scope='HOST_ONLY',fog_start_replicated=false,fog_start_multiplier=FOG_START_MULTIPLIER,
        fog_ramp_phase='IDLE',fog_ramp_scope='HOST_ONLY',fog_ramp_replicated=false,fog_ramp_multiplier=FOG_RAMP_MULTIPLIER,
        sky_light_phase='IDLE',sky_light_scope='HOST_ONLY',sky_light_replicated=false,sky_light_multiplier=SKYLIGHT_MULTIPLIER,
        fog_distance_phase='IDLE',fog_distance_scope='HOST_READBACK'}
    local get,call=runtime.get,runtime.call
    local function clear_fog_distance(phase,reason,reset_clock)
        report.fog_distance_phase=phase;report.fog_distance_reason=reason
        report.fog_distance_sky_id=nil;report.fog_distance_component_id=nil;report.fog_distance_owner_id=nil
        report.fog_distance_observed_at=nil;report.fog_distance_sky_volumetric=nil
        for _,field in ipairs(FOG_DISTANCE_FIELDS)do report['fog_distance_'..field[2]]=nil end
        if reset_clock then next_fog_distance_probe=nil;last_fog_distance_probe=nil end
    end
    local function observe_fog_distance(c,o)
        -- Follow the component UDS actually updates, including its supported custom actor.
        -- Never inventory fog actors or retain a component wrapper between observations.
        if not runtime.belongs(o,c.world)then return false,'Sky is not in the current world'end
        local component=get(o,'Height Fog Component')
        if not runtime.live(component)or not runtime.belongs(component,c.world)then
            return false,'Active height fog component is unavailable in the current world'
        end
        local ok,owner=call(component,'GetOwner')
        if not ok or not runtime.live(owner)or not runtime.belongs(owner,c.world)then
            return false,'Active height fog component owner is unavailable'
        end
        local owner_id=runtime.key(owner);local component_id=runtime.key(component)
        if not owner_id or not component_id then return false,'Active height fog identity is unavailable'end
        if owner_id~=sky_id then
            local custom=get(o,'Custom Height Fog Actor')
            if not runtime.live(custom)or not runtime.belongs(custom,c.world)or runtime.key(custom)~=owner_id then
                return false,'Active height fog component has an unrelated owner'
            end
        end
        report.fog_distance_sky_id=sky_id;report.fog_distance_component_id=component_id
        report.fog_distance_owner_id=owner_id;report.fog_distance_observed_at=c.now
        local unreadable
        local read,value=pcall(get,o,'Use Volumetric Fog')
        if read and type(value)=='boolean'then report.fog_distance_sky_volumetric=value
        else unreadable='Use Volumetric Fog'end
        for _,field in ipairs(FOG_DISTANCE_FIELDS)do
            read,value=pcall(get,component,field[1])
            if read and ((field[3]=='boolean'and type(value)=='boolean')or(field[3]~='boolean'and finite(value)))then
                report['fog_distance_'..field[2]]=value
            else unreadable=unreadable or field[1]end
        end
        if unreadable then return false,'Native fog field is unreadable: '..unreadable end
        return true
    end
    local function update_fog_distance(c,o)
        if next_fog_distance_probe and c.now>=last_fog_distance_probe and c.now<next_fog_distance_probe then return end
        clear_fog_distance('UNAVAILABLE',nil)
        last_fog_distance_probe=c.now;next_fog_distance_probe=c.now+INVENTORY_INTERVAL
        local called,ok,why=pcall(observe_fog_distance,c,o)
        if called and ok then report.fog_distance_phase='OBSERVED'
        else report.fog_distance_reason=tostring(called and why or ok):sub(1,200)end
    end
    local function set(o,k,v)
        local ok=pcall(function()o[k]=v end);return ok and get(o,k)==v
    end
    local function cached(entry,c)
        -- World changes discard these wrappers before this function can run.
        -- Validate current native liveness/world and exact identity on every reuse.
        return entry and entry.world_id==c.world_id and c.now>=entry.at and c.now-entry.at<INVENTORY_INTERVAL
            and runtime.belongs(entry.object,c.world)and runtime.key(entry.object)==entry.id and entry.object or nil
    end
    local function remember(o,c)
        if not o then return nil end
        local id=runtime.key(o);if not id then return nil end
        return {object=o,id=id,world_id=c.world_id,at=c.now}
    end
    local function sky(c,force)
        local previous=not force and cached(sky_cache,c)
        if previous then return previous end
        sky_cache=nil
        local found
        for _,o in ipairs(runtime.find_all('Ultra_Dynamic_Sky_C',64)) do
            if runtime.belongs(o,c.world) then if found then return nil,'Multiple active sky actors' end;found=o end
        end
        sky_cache=remember(found,c)
        return found,not found and 'Map has no supported sky' or nil
    end
    local function apply(o,t)
        if not set(o,'Animate Time of Day',false) or not set(o,'Use System Time',false)
            or not set(o,'Disable All Runtime Updating',false) or not set(o,'Time of Day',t) then return false end
        local ticked=call(o,'Tick Function');local synced=call(o,'Update Replicated Time')
        local actual=get(o,'Time of Day')
        if not ticked or not synced or not finite(actual) or math.abs(actual-t)>0.001 then return false end
        call(o,'ForceNetUpdate');return true
    end
    local function reset_color()
        color_id=nil;color_original=nil;color_target=nil;color_pending=nil;next_color_probe=nil;color_failures=nil
        report.fog_color_phase='IDLE';report.fog_color_reason=nil;report.fog_color_actor_id=nil
        report.fog_color_original=nil;report.fog_color_target=nil;report.fog_color_current=nil
    end
    local function color_failed(c,phase,why)
        report.fog_color_phase=phase;report.fog_color_reason=tostring(why):sub(1,200)
        color_failures=math.min((color_failures or 0)+1,4)
        next_color_probe=c.now+2^(color_failures-1)
    end
    local function prepare_color(c,o)
        -- This current UDS DoubleProperty is NOT Net. It changes host rendering
        -- only; rain/fog density continue through the separate native Net path.
        if next_color_probe and c.now<next_color_probe then return false end
        local id=runtime.key(o);local actual=get(o,FOG_COLOR_FIELD)
        report.fog_color_current=finite(actual)and actual or nil
        if not id or not finite(actual)or actual<0 then
            color_failed(c,'UNAVAILABLE','Native fog color intensity is unreadable');return false
        end
        if color_id~=id then
            color_id=id;color_original=actual;color_target=actual*FOG_COLOR_MULTIPLIER;color_pending=true
            report.fog_color_actor_id=id;report.fog_color_original=actual;report.fog_color_target=color_target
        end
        if color_pending or math.abs(actual-color_target)>0.000001 then
            local ok,authority=call(o,'HasAuthority')
            if not ok or authority~=true then color_failed(c,'UNAVAILABLE','Sky authority unavailable for fog color');return false end
            -- Keep the first original scalar, including after a partial failure.
            color_pending=true
            if not set(o,FOG_COLOR_FIELD,color_target)then color_failed(c,'FAILED','Fog color intensity write failed');return false end
            report.fog_color_phase='WAITING';report.fog_color_reason='Native fog color update pending'
            return true
        end
        report.fog_color_phase='HELD';report.fog_color_reason=nil
        color_failures=0;next_color_probe=nil
        return false
    end
    local function tick_once(o,update)
        if not update.done then
            update.done=true;update.ok=false
            local ok,value=call(o,'Tick Function');update.ok=ok and value~=false
        end
        return update.ok
    end
    local function finish_color(c,o,needs_tick,update)
        if not needs_tick then return end
        -- Coalesce the initial color change with the clock's existing native tick.
        -- Stable ticks only read scalars; neither color nor time is reapplied.
        if not tick_once(o,update)then color_failed(c,'FAILED','Native fog color update failed');return end
        local actual=get(o,FOG_COLOR_FIELD)
        report.fog_color_current=finite(actual)and actual or nil
        if not finite(actual)or math.abs(actual-color_target)>0.000001 then
            color_failed(c,'FAILED','Native fog color intensity did not verify');return
        end
        color_pending=false;color_failures=0;next_color_probe=c.now+1
        report.fog_color_phase='HELD';report.fog_color_reason=nil
    end
    local function reset_start()
        start_id=nil;start_original=nil;start_target=nil;start_pending=nil
        next_start_probe=nil;last_start_probe=nil;start_failures=nil
        report.fog_start_phase='IDLE';report.fog_start_reason=nil;report.fog_start_actor_id=nil
        report.fog_start_original=nil;report.fog_start_target=nil;report.fog_start_current=nil
    end
    local function start_failed(c,phase,why)
        report.fog_start_phase=phase;report.fog_start_reason=tostring(why):sub(1,200)
        start_failures=math.min((start_failures or 0)+1,4)
        last_start_probe=c.now;next_start_probe=c.now+math.max(INVENTORY_INTERVAL,2^(start_failures-1))
    end
    local function prepare_start(c,o)
        if next_start_probe and c.now>=last_start_probe and c.now<next_start_probe then return false end
        last_start_probe=c.now;next_start_probe=c.now+INVENTORY_INTERVAL
        local id=runtime.key(o);local actual=get(o,FOG_START_FIELD)
        report.fog_start_current=finite(actual)and actual or nil
        if not id or not finite(actual)or actual<0 then
            start_failed(c,'UNAVAILABLE','Native fog start input is unreadable');return false
        end
        if start_id~=id then
            start_id=id;start_original=actual;start_target=actual*FOG_START_MULTIPLIER;start_pending=true
            report.fog_start_actor_id=id;report.fog_start_original=actual;report.fog_start_target=start_target
        end
        if start_pending or math.abs(actual-start_target)>0.000001 then
            local ok,authority=call(o,'HasAuthority')
            if not ok or authority~=true then start_failed(c,'UNAVAILABLE','Sky authority unavailable for fog start');return false end
            start_pending=true
            if not set(o,FOG_START_FIELD,start_target)then start_failed(c,'FAILED','Fog start input write failed');return false end
            report.fog_start_phase='WAITING';report.fog_start_reason='Native fog start input update pending'
            return true
        end
        report.fog_start_phase='INPUT_HELD';report.fog_start_reason=nil;start_failures=0
        return false
    end
    local function finish_start(c,o,needs_tick,update)
        if not needs_tick then return end
        if not tick_once(o,update)then start_failed(c,'FAILED','Native fog start update failed');return end
        local actual=get(o,FOG_START_FIELD)
        report.fog_start_current=finite(actual)and actual or nil
        if not finite(actual)or math.abs(actual-start_target)>0.000001 then
            start_failed(c,'FAILED','Native fog start input did not verify');return
        end
        start_pending=false;start_failures=0
        -- The existing native cache/height-fog path owns the rendered distance;
        -- INPUT_HELD verifies only this input. The separate readback observes it.
        report.fog_start_phase='INPUT_HELD';report.fog_start_reason=nil
    end
    local function reset_ramp()
        ramp_id=nil;ramp_original=nil;ramp_target=nil;ramp_pending=nil
        next_ramp_probe=nil;last_ramp_probe=nil;ramp_failures=nil
        report.fog_ramp_phase='IDLE';report.fog_ramp_reason=nil;report.fog_ramp_actor_id=nil
        for _,name in ipairs({'scale','threshold'})do
            report['fog_ramp_'..name..'_original']=nil;report['fog_ramp_'..name..'_target']=nil;report['fog_ramp_'..name..'_current']=nil
        end
    end
    local function ramp_failed(c,phase,why)
        report.fog_ramp_phase=phase;report.fog_ramp_reason=tostring(why):sub(1,200)
        ramp_failures=math.min((ramp_failures or 0)+1,4)
        last_ramp_probe=c.now;next_ramp_probe=c.now+math.max(INVENTORY_INTERVAL,2^(ramp_failures-1))
    end
    local function write_ramp(o,values)
        -- Always attempt both fields, including rollback after a partial failure.
        local good=true
        for i,field in ipairs(FOG_RAMP_FIELDS)do
            local ok,verified=pcall(set,o,field,values[i]);good=ok and verified and good
        end
        return good
    end
    local function read_ramp(o)
        local a,b=get(o,FOG_RAMP_FIELDS[1]),get(o,FOG_RAMP_FIELDS[2])
        report.fog_ramp_scale_current=finite(a)and a or nil;report.fog_ramp_threshold_current=finite(b)and b or nil
        if finite(a)and a>=0 and finite(b)and b>0 then return {a,b}end
    end
    local function prepare_ramp(c,o)
        if next_ramp_probe and c.now>=last_ramp_probe and c.now<next_ramp_probe then return false end
        last_ramp_probe=c.now;next_ramp_probe=c.now+INVENTORY_INTERVAL
        local id=runtime.key(o);local actual=read_ramp(o)
        if not id or not actual then ramp_failed(c,'UNAVAILABLE','Native fog density/threshold inputs are unreadable');return false end
        if ramp_id~=id then
            ramp_id=id;ramp_original=actual;ramp_target={actual[1]*FOG_RAMP_MULTIPLIER,actual[2]*FOG_RAMP_MULTIPLIER};ramp_pending=true
            report.fog_ramp_actor_id=id
            for i,name in ipairs({'scale','threshold'})do
                report['fog_ramp_'..name..'_original']=actual[i];report['fog_ramp_'..name..'_target']=ramp_target[i]
            end
        end
        if ramp_pending or actual[1]~=ramp_target[1]or actual[2]~=ramp_target[2]then
            local ok,authority=call(o,'HasAuthority')
            if not ok or authority~=true then ramp_failed(c,'UNAVAILABLE','Sky authority unavailable for fog ramp');return false end
            -- Scaling density and this threshold equally preserves their ratio in
            -- the native start-distance curve. Fog9 and all lighting inputs stay put.
            ramp_pending=true
            if not write_ramp(o,ramp_target)then
                local restored=write_ramp(o,actual)
                ramp_failed(c,'FAILED',restored and'Coupled fog input write failed; prior values restored'or'Coupled fog input write and rollback did not verify')
                return false
            end
            report.fog_ramp_phase='WAITING';report.fog_ramp_reason='Native fog density input update pending';return true
        end
        report.fog_ramp_phase='INPUT_HELD';report.fog_ramp_reason=nil;ramp_failures=0;return false
    end
    local function finish_ramp(c,o,needs_tick,update)
        if not needs_tick then return end
        if not tick_once(o,update)then ramp_failed(c,'FAILED','Native fog density input update failed');return end
        local actual=read_ramp(o)
        if not actual or actual[1]~=ramp_target[1]or actual[2]~=ramp_target[2]then
            ramp_failed(c,'FAILED','Coupled native fog inputs did not verify');return
        end
        ramp_pending=false;ramp_failures=0;report.fog_ramp_phase='INPUT_HELD';report.fog_ramp_reason=nil
    end
    local function reset_skylight()
        skylight_id=nil;skylight_original=nil;skylight_target=nil;skylight_pending=nil
        next_skylight_probe=nil;last_skylight_probe=nil;skylight_failures=nil
        report.sky_light_phase='IDLE';report.sky_light_reason=nil;report.sky_light_actor_id=nil
        report.sky_light_original=nil;report.sky_light_target=nil;report.sky_light_current=nil
    end
    local function skylight_failed(c,phase,why)
        report.sky_light_phase=phase;report.sky_light_reason=tostring(why):sub(1,200)
        skylight_failures=math.min((skylight_failures or 0)+1,4)
        last_skylight_probe=c.now;next_skylight_probe=c.now+math.max(INVENTORY_INTERVAL,2^(skylight_failures-1))
    end
    local function prepare_skylight(c,o)
        if next_skylight_probe and c.now>=last_skylight_probe and c.now<next_skylight_probe then return false end
        last_skylight_probe=c.now;next_skylight_probe=c.now+INVENTORY_INTERVAL
        local id=runtime.key(o);local actual=get(o,SKYLIGHT_FIELD)
        report.sky_light_current=finite(actual)and actual or nil
        if not id or not finite(actual)or actual<0 or not finite(actual*SKYLIGHT_MULTIPLIER)then
            skylight_failed(c,'UNAVAILABLE','Native sky light intensity is unreadable');return false
        end
        if skylight_id~=id then
            skylight_id=id;skylight_original=actual;skylight_target=actual*SKYLIGHT_MULTIPLIER;skylight_pending=true
            report.sky_light_actor_id=id;report.sky_light_original=actual;report.sky_light_target=skylight_target
        end
        if skylight_pending or actual~=skylight_target then
            local ok,authority=call(o,'HasAuthority')
            if not ok or authority~=true then skylight_failed(c,'UNAVAILABLE','Sky authority unavailable for sky light');return false end
            skylight_pending=true
            if not set(o,SKYLIGHT_FIELD,skylight_target)then skylight_failed(c,'FAILED','Sky light intensity write failed');return false end
            report.sky_light_phase='WAITING';report.sky_light_reason='Native sky light input update pending';return true
        end
        report.sky_light_phase='INPUT_HELD';report.sky_light_reason=nil;skylight_failures=0;return false
    end
    local function finish_skylight(c,o,needs_tick,update)
        if not needs_tick then return end
        -- UDS caches this non-Net scalar as Float54 and updates its existing
        -- SkyLightComponent. No recapture or extra native cache rebuild is needed.
        if not tick_once(o,update)then skylight_failed(c,'FAILED','Native sky light update failed');return end
        local actual=get(o,SKYLIGHT_FIELD);report.sky_light_current=finite(actual)and actual or nil
        if not finite(actual)or actual~=skylight_target then
            skylight_failed(c,'FAILED','Sky light intensity input did not verify');return
        end
        skylight_pending=false;skylight_failures=0
        report.sky_light_phase='INPUT_HELD';report.sky_light_reason=nil
    end
    local function weather(c,force)
        local previous=not force and cached(weather_cache,c)
        if previous then return previous end
        weather_cache=nil
        local found
        for _,o in ipairs(runtime.find_all('Ultra_Dynamic_Weather_C',64))do
            if runtime.belongs(o,c.world)then
                local typed,class=call(o,'GetClass');local named,name=false,nil
                if typed and runtime.live(class)then named,name=call(class,'GetFullName')end
                if named and type(name)=='string'and name:match('^%S+ (/.+)$')==WEATHER_CLASS then
                    if found then return nil,'Multiple active weather actors'end
                    found=o
                end
            end
        end
        weather_cache=remember(found,c)
        return found,not found and 'Map has no supported weather actor'or nil
    end
    local function weather_api(o)
        if type(runtime.find)~='function'or type(runtime.native)~='function'then return nil,'Weather replication API unavailable'end
        local cdo,fn=runtime.find(DIRTY_CDO),runtime.find(DIRTY)
        if not cdo or not fn then return nil,'Weather replication helper unavailable'end
        local update=runtime.find(WEATHER_CLASS..':Update Current Global And Local Weather State')
        if not update then return nil,'Native weather update unavailable'end
        local names={};local constructor=options.fname or rawget(_G,'FName')
        for i,f in ipairs(WEATHER_FIELDS)do
            -- FName is callable userdata in the installed UE4SS build.
            local ok,name=pcall(constructor,f.name)
            if not ok or name==nil or type(name)=='string'then return nil,'FName constructor unavailable'end
            names[i]=name
        end
        local ok,authority=call(o,'HasAuthority')
        if not ok or authority~=true or get(o,'bReplicates')~=true then return nil,'Weather authority/replication unavailable'end
        -- Transient Weather State belongs to Generate Weather State At Location,
        -- which assigns its caller-supplied Settings Object before using it.
        -- Our native update takes the local branch and does not need that cache.
        for _,field in ipairs({'Manual Weather State','Global Weather State','Local Weather State'})do
            if not runtime.live(get(o,field))then return nil,'Weather state is not initialized: '..field end
        end
        return {cdo=cdo,names=names}
    end
    local function write_weather(o,values,api)
        local flushed,value=call(o,'FlushNetDormancy')
        if not flushed or value==false then return false,'Weather dormancy flush failed'end
        -- Native dirty marking is required for push-model replicated properties.
        -- The native update rebuilds its manual state from these scalar inputs.
        for i,f in ipairs(WEATHER_FIELDS)do
            if not set(o,f.name,values[i])then return false,'Weather field write failed: '..f.name end
            local ok,result=runtime.native(DIRTY,api.cdo,o,f.index,api.names[i])
            if not ok or result==false then return false,'Weather replication failed: '..f.name end
        end
        local ok,result=call(o,'Update Current Global And Local Weather State')
        if not ok or result==false then return false,'Native weather update failed'end
        ok,result=call(o,'ForceNetUpdate')
        if not ok or result==false then return false,'Weather network update failed'end
        return true
    end
    local function hold_weather(c,active_sky)
        report.weather_native_replication_requested=false
        report.cloud_coverage=nil;report.rain=nil;report.fog=nil
        report.cloud_coverage_uds=nil;report.sky_cloud_coverage=nil;report.sky_local_cloud_coverage=nil;report.sky_local_overcast=nil
        report.sky_directional_light_dimming=nil;report.sky_dim_directional_lights_with_clouds=nil;report.sky_use_cloud_shadows=nil
        local o,why=weather(c)
        if not o then report.weather_phase='UNAVAILABLE';report.weather_reason=why;return end
        if not active_sky or runtime.key(get(o,'UltraDynamicSky'))~=runtime.key(active_sky)then
            report.weather_phase='UNAVAILABLE';report.weather_reason='Weather is not linked to the active sky';return
        end
        local id=runtime.key(o);if not id then report.weather_phase='UNAVAILABLE';report.weather_reason='Weather identity unavailable';return end
        local api
        if weather_id~=id then
            api,why=weather_api(o)
            if not api then report.weather_phase='UNAVAILABLE';report.weather_reason=why;return end
            local original={}
            for i,f in ipairs(WEATHER_FIELDS)do
                local v=get(o,f.name)
                if (type(f.value)=='number'and not finite(v))or(type(f.value)=='boolean'and type(v)~='boolean')then
                    report.weather_phase='UNAVAILABLE';report.weather_reason='Weather field unreadable: '..f.name;return
                end
                original[i]=v
            end
            weather_id=id;weather_backup=original;last_weather_update=nil;weather_pending=true
        end
        report.weather_actor_id=id
        local drift=false;local values={}
        for i,f in ipairs(WEATHER_FIELDS)do values[i]=f.value;if get(o,f.name)~=f.value then drift=true end end
        if last_weather_update==nil or ((drift or weather_pending)and c.now-last_weather_update>=1)then
            if not api then api,why=weather_api(o)end
            if not api then report.weather_phase='UNAVAILABLE';report.weather_reason=why;return end
            last_weather_update=c.now
            weather_pending=true
            local ok;ok,why=write_weather(o,values,api)
            if not ok then report.weather_phase='FAILED';report.weather_reason=why;return end
            weather_pending=false
        elseif drift or weather_pending then
            report.weather_phase='WAITING';report.weather_reason='Weather correction will retry';return
        end
        local state=get(o,'Local Weather State')
        if not runtime.live(state)then
            weather_pending=true;report.weather_phase='UNAVAILABLE';report.weather_reason='Local weather state is not initialized';return
        end
        local clouds,rain,fog=get(state,'Cloud Coverage'),get(state,'Rain'),get(state,'Fog')
        -- Optional downstream sky diagnostics only. Native camera/painting/range
        -- changes may affect these values; they never trigger apply or readiness.
        for _,field in ipairs({{o,'UDS Cloud Coverage','cloud_coverage_uds'},
            {active_sky,'Cloud Coverage','sky_cloud_coverage'},{active_sky,'Local Cloud Coverage','sky_local_cloud_coverage'},
            {active_sky,'Local Overcast 0-1','sky_local_overcast'},
            {active_sky,'Cached Directional Light Dimming','sky_directional_light_dimming'},
            {active_sky,'Dim Directional Lights with Cloud Coverage','sky_dim_directional_lights_with_clouds','boolean'},
            {active_sky,'Use Cloud Shadows','sky_use_cloud_shadows','boolean'}})do
            local ok,value=pcall(get,field[1],field[2])
            if ok and ((field[4]=='boolean'and type(value)=='boolean')or(field[4]~='boolean'and finite(value)))then report[field[3]]=value end
        end
        if not finite(clouds)or math.abs(clouds-10)>0.001 or not finite(rain)or not finite(fog)
            or math.abs(rain-7.5)>0.001 or math.abs(fog-9)>0.001 then
            weather_pending=true
            report.weather_phase='WAITING';report.weather_reason='Native local weather state has not applied clouds/rain/fog';return
        end
        report.weather_phase='HELD';report.weather_reason=nil
        report.cloud_coverage=10;report.rain=7.5;report.fog=9;report.weather_native_replication_requested=true
    end
    local function update_weather(c,active_sky)
        -- Weather is optional capability: failures never block indoor spawning.
        if not active_sky then
            report.weather_phase='UNAVAILABLE';report.weather_reason='Map has no supported sky'
            report.weather_native_replication_requested=false;report.rain=nil;report.fog=nil
            report.cloud_coverage=nil;report.cloud_coverage_uds=nil;report.sky_cloud_coverage=nil;report.sky_local_cloud_coverage=nil;report.sky_local_overcast=nil
            report.sky_directional_light_dimming=nil;report.sky_dim_directional_lights_with_clouds=nil;report.sky_use_cloud_shadows=nil
            next_weather_probe=nil;last_weather_sky_id=nil;return
        end
        if next_weather_probe and last_weather_sky_id==sky_id and c.now<next_weather_probe then return end
        last_weather_sky_id=sky_id
        local ok,why=pcall(hold_weather,c,active_sky)
        if not ok then report.weather_phase='FAILED';report.weather_reason=tostring(why):sub(1,200)end
        if report.weather_phase=='UNAVAILABLE'or report.weather_phase=='FAILED'then
            weather_failures=math.min((weather_failures or 0)+1,4)
            next_weather_probe=c.now+2^(weather_failures-1)
        else
            weather_failures=0;next_weather_probe=c.now+1
        end
    end
    function self.tick(c)
        if not c or not c.authority or not c.enabled or c.zdm_active==true then
            clear_fog_distance('IDLE',nil,true);return false,'Variant world ownership required'
        end
        if not runtime.live(c.world) then clear_fog_distance('UNAVAILABLE','World is retired',true);return false,'World is retired' end
        if world_id~=c.world_id then
            -- Drop all old-world state without dereferencing previous sky wrappers.
            world_id=c.world_id;sky_id=nil;backup=nil;last_update=nil
            sky_cache=nil;weather_cache=nil;next_weather_probe=nil;weather_failures=nil;last_weather_sky_id=nil
            weather_id=nil;weather_backup=nil;last_weather_update=nil;weather_pending=nil
            reset_color()
            reset_start()
            reset_ramp()
            reset_skylight()
            clear_fog_distance('IDLE',nil,true)
            report.weather_actor_id=nil;report.rain=nil;report.fog=nil;report.weather_phase='IDLE';report.weather_reason=nil
            report.cloud_coverage=nil;report.cloud_coverage_uds=nil;report.sky_cloud_coverage=nil;report.sky_local_cloud_coverage=nil;report.sky_local_overcast=nil
            report.sky_directional_light_dimming=nil;report.sky_dim_directional_lights_with_clouds=nil;report.sky_use_cloud_shadows=nil
            report.weather_native_replication_requested=false
            report.world_id=c.world_id;report.minute_of_day=nil;report.time=nil
            report.native_replication_requested=false
            local ok,value=pcall(options.random or math.random,0,WINDOW_MINUTES)
            if not ok or not finite(value) or value%1~=0 or value<0 or value>WINDOW_MINUTES then
                minute=nil;report.phase='BLOCKED';report.reason='Invalid random time';return false,report.reason
            end
            minute=START_MINUTE+value
        end
        if not minute then return false,'No time selected for this world' end
        local o,why=sky(c)
        if not o then
            clear_fog_distance('UNAVAILABLE',why)
            if why=='Map has no supported sky' then
                -- A clock is not required for indoor maps such as The Backrooms.
                -- Keep checking each tick so a late outdoor sky still gets daylight.
                report.phase='NATIVE_LIGHTING';report.world_id=world_id
                report.minute_of_day=nil;report.time=nil;report.native_replication_requested=false
                report.reason='Map has no supported sky; native lighting is preserved'
                report.fog_color_phase='UNAVAILABLE';report.fog_color_reason='Map has no supported sky';report.fog_color_current=nil
                report.fog_start_phase='UNAVAILABLE';report.fog_start_reason='Map has no supported sky';report.fog_start_current=nil
                report.fog_ramp_phase='UNAVAILABLE';report.fog_ramp_reason='Map has no supported sky'
                report.fog_ramp_scale_current=nil;report.fog_ramp_threshold_current=nil
                report.sky_light_phase='UNAVAILABLE';report.sky_light_reason='Map has no supported sky';report.sky_light_current=nil
                update_weather(c,nil)
                return true
            end
            report.phase='UNAVAILABLE';report.reason=why;return false,why
        end
        local id=runtime.key(o);if not id then return false,'Sky identity unavailable' end
        if sky_id~=id then
            clear_fog_distance('WAITING','New sky observation pending')
            local ok,auth=call(o,'HasAuthority')
            if not ok or auth~=true or get(o,'Sun Mobility')~=2 or get(o,'Transitioning Time')~=false then
                return false,'Sky authority/mobility/transition not ready'
            end
            local original={time=get(o,'Time of Day'),animate=get(o,'Animate Time of Day'),
                system=get(o,'Use System Time'),disabled=get(o,'Disable All Runtime Updating')}
            if not finite(original.time) or type(original.animate)~='boolean' or type(original.system)~='boolean'
                or type(original.disabled)~='boolean' then return false,'Sky fields unreadable' end
            -- A newly validated native sky owns its own clock and color baseline.
            -- Do not retain the previous actor's color retry/restore identity.
            reset_color();reset_start();reset_ramp();reset_skylight();backup=original;sky_id=id;last_update=nil
        end
        -- UDS H/M/S/MS to Time of Day uses Hours*100 + Minutes*(100/60).
        -- The field is a linear 0..2400 clock, not an HHMM integer.
        local value=minute*100/60
        local actual=get(o,'Time of Day')
        local drift=not finite(actual)or math.abs(actual-value)>0.001 or get(o,'Animate Time of Day')~=false
            or get(o,'Use System Time')~=false or get(o,'Disable All Runtime Updating')~=false
        local needs=last_update==nil or drift
        local color_ok,color_needs=pcall(prepare_color,c,o)
        if not color_ok then color_failed(c,'FAILED',color_needs);color_needs=false end
        local start_ok,start_needs=pcall(prepare_start,c,o)
        if not start_ok then start_failed(c,'FAILED',start_needs);start_needs=false end
        local ramp_ok,ramp_needs=pcall(prepare_ramp,c,o)
        if not ramp_ok then ramp_failed(c,'FAILED',ramp_needs);ramp_needs=false end
        local skylight_ok,skylight_needs=pcall(prepare_skylight,c,o)
        if not skylight_ok then skylight_failed(c,'FAILED',skylight_needs);skylight_needs=false end
        if needs then
            if not apply(o,value) then report.phase='FAILED';report.reason='Native time update did not verify';return false,report.reason end
            last_update=c.now
        end
        local update={done=needs,ok=needs}
        local finished,color_why=pcall(finish_color,c,o,color_needs,update)
        if not finished then color_failed(c,'FAILED',color_why)end
        local start_finished,start_why=pcall(finish_start,c,o,start_needs,update)
        if not start_finished then start_failed(c,'FAILED',start_why)end
        local ramp_finished,ramp_why=pcall(finish_ramp,c,o,ramp_needs,update)
        if not ramp_finished then ramp_failed(c,'FAILED',ramp_why)end
        local skylight_finished,skylight_why=pcall(finish_skylight,c,o,skylight_needs,update)
        if not skylight_finished then skylight_failed(c,'FAILED',skylight_why)end
        report.phase='HELD';report.world_id=world_id;report.minute_of_day=minute
        report.time=string.format('%02d:%02d',math.floor(minute/60),minute%60);report.native_replication_requested=true;report.reason=nil
        update_weather(c,o)
        update_fog_distance(c,o)
        return true
    end
    function self.release(c)
        clear_fog_distance('IDLE',nil,true)
        -- Current-world opt-out restores only the exact sky this adapter changed.
        if c and c.world_id==world_id and c.authority and runtime.live(c.world)and weather_backup then
            local o,why=weather(c,true)
            if not o or runtime.key(o)~=weather_id then
                why=why or 'Original weather actor is not currently available'
                report.weather_phase='RESTORE_WAITING';report.weather_reason=why
                return false,why
            end
            if o and runtime.key(o)==weather_id then
                local api;api,why=weather_api(o)
                if not api then return false,why end
                local called,ok;called,ok,why=pcall(write_weather,o,weather_backup,api)
                if not called then why=tostring(ok):sub(1,200);ok=false end
                if not ok then report.weather_phase='RESTORE_FAILED';report.weather_reason=why;return false,why end
            end
        end
        if c and c.world_id==world_id and c.authority and runtime.live(c.world)and (backup or color_original~=nil or start_original~=nil or ramp_original or skylight_original~=nil)then
            local o,why=sky(c,true)
            if skylight_original~=nil and(not o or runtime.key(o)~=skylight_id)then
                report.sky_light_phase='RESTORE_WAITING';report.sky_light_reason=why or'Original sky actor is not currently available'
                return false,report.sky_light_reason
            end
            if ramp_original and(not o or runtime.key(o)~=ramp_id)then
                report.fog_ramp_phase='RESTORE_WAITING';report.fog_ramp_reason=why or'Original sky actor is not currently available'
                return false,report.fog_ramp_reason
            end
            if start_original~=nil and (not o or runtime.key(o)~=start_id)then
                report.fog_start_phase='RESTORE_WAITING';report.fog_start_reason=why or 'Original sky actor is not currently available'
                return false,report.fog_start_reason
            end
            if color_original~=nil and (not o or runtime.key(o)~=color_id)then
                report.fog_color_phase='RESTORE_WAITING';report.fog_color_reason=why or 'Original sky actor is not currently available'
                return false,report.fog_color_reason
            end
            if o and runtime.key(o)==sky_id then
                if skylight_original~=nil then
                    local restored,ok=pcall(set,o,SKYLIGHT_FIELD,skylight_original)
                    if not restored or not ok then
                        report.sky_light_phase='RESTORE_FAILED';report.sky_light_reason='Original sky light intensity restoration failed'
                        return false,report.sky_light_reason
                    end
                end
                if ramp_original and not write_ramp(o,ramp_original)then
                    report.fog_ramp_phase='RESTORE_FAILED';report.fog_ramp_reason='Original fog density inputs did not restore'
                    return false,report.fog_ramp_reason
                end
                if start_original~=nil then
                    local restored,ok=pcall(set,o,FOG_START_FIELD,start_original)
                    if not restored or not ok then
                        report.fog_start_phase='RESTORE_FAILED';report.fog_start_reason='Original fog start restoration failed'
                        return false,report.fog_start_reason
                    end
                end
                if color_original~=nil and not set(o,FOG_COLOR_FIELD,color_original)then
                    report.fog_color_phase='RESTORE_FAILED';report.fog_color_reason='Original fog color restoration failed'
                    return false,report.fog_color_reason
                end
                if backup then
                    if not apply(o,backup.time) then return false,'Original sky time restoration failed' end
                    if not set(o,'Animate Time of Day',backup.animate) or not set(o,'Use System Time',backup.system)
                        or not set(o,'Disable All Runtime Updating',backup.disabled) then return false,'Original sky switches restoration failed' end
                elseif color_original~=nil or start_original~=nil or ramp_original or skylight_original~=nil then
                    local ok,value=call(o,'Tick Function')
                    if not ok or value==false then
                        report.fog_color_phase='RESTORE_FAILED';report.fog_color_reason='Native fog color restoration failed'
                        return false,report.fog_color_reason
                    end
                end
                if skylight_original~=nil then
                    local read,value=pcall(get,o,SKYLIGHT_FIELD)
                    if not read or value~=skylight_original then
                        report.sky_light_phase='RESTORE_FAILED';report.sky_light_reason='Original sky light intensity did not verify after native update'
                        return false,report.sky_light_reason
                    end
                end
                if ramp_original then
                    local read,values=pcall(read_ramp,o)
                    if not read or not values or values[1]~=ramp_original[1]or values[2]~=ramp_original[2]then
                        report.fog_ramp_phase='RESTORE_FAILED';report.fog_ramp_reason='Original fog density inputs did not verify after native update'
                        return false,report.fog_ramp_reason
                    end
                end
                if start_original~=nil then
                    local read,value=pcall(get,o,FOG_START_FIELD)
                    if not read or value~=start_original then
                        report.fog_start_phase='RESTORE_FAILED';report.fog_start_reason='Original fog start did not verify after native update'
                        return false,report.fog_start_reason
                    end
                end
                if color_original~=nil and get(o,FOG_COLOR_FIELD)~=color_original then
                    report.fog_color_phase='RESTORE_FAILED';report.fog_color_reason='Original fog color did not verify after native update'
                    return false,report.fog_color_reason
                end
            end
        end
        sky_id=nil;backup=nil;last_update=nil;report.phase='IDLE'
        sky_cache=nil;weather_cache=nil;next_weather_probe=nil;weather_failures=nil;last_weather_sky_id=nil
        weather_id=nil;weather_backup=nil;last_weather_update=nil;weather_pending=nil
        reset_color()
        reset_start()
        reset_ramp()
        reset_skylight()
        report.weather_phase='IDLE';report.weather_reason=nil;report.weather_actor_id=nil
        report.rain=nil;report.fog=nil;report.weather_native_replication_requested=false
        report.cloud_coverage=nil;report.cloud_coverage_uds=nil;report.sky_cloud_coverage=nil;report.sky_local_cloud_coverage=nil;report.sky_local_overcast=nil
        report.sky_directional_light_dimming=nil;report.sky_dim_directional_lights_with_clouds=nil;report.sky_use_cloud_shadows=nil
        -- Retain the scalar world/time so resuming on the same loaded map cannot reroll.
        return true
    end
    function self.snapshot()local copy={};for k,v in pairs(report)do copy[k]=v end;return copy end
    return self
end
return M
