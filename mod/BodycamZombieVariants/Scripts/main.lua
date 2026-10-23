-- Cold-start bootstrap for the separate native-mode extension.
local source=debug.getinfo(1,'S').source
local dir=source:sub(1,1)=='@' and source:sub(2):match('^(.*[/\\])')
if not dir then return end
local function log(message)print('[BodycamZombieVariants] '..tostring(message)..'\n')end
local function json(v,seen)
    local t=type(v)
    if t=='nil' then return 'null' end
    if t=='boolean' then return v and 'true' or 'false' end
    if t=='number' then return v==v and v~=math.huge and v~=-math.huge and tostring(v) or 'null' end
    if t=='string' then return '"'..v:gsub('[%z\1-\31\\"]',function(c)
        if c=='"' then return '\\"' elseif c=='\\' then return '\\\\' end
        return string.format('\\u%04x',c:byte())
    end)..'"' end
    if t~='table' then return 'null' end
    seen=seen or {};if seen[v]then return 'null'end;seen[v]=true
    local length=#v;local array=length>0
    for k in pairs(v)do if type(k)~='number'or k%1~=0 or k<1 or k>length then array=false;break end end
    if array then
        local out={};for i=1,length do out[i]=json(v[i],seen)end
        seen[v]=nil;return '['..table.concat(out,',')..']'
    end
    local out={};for k,item in pairs(v)do if type(k)=='string'then out[#out+1]=json(k)..':'..json(item,seen)end end
    table.sort(out);seen[v]=nil;return '{'..table.concat(out,',')..'}'
end
local function status(value)
    local f=io.open(dir..'status.json','wb');if f then f:write(json(value),'\n');f:close()end
end
if type(LoopInGameThreadWithDelay)~='function' or type(CancelDelayedAction)~='function' then
    status({phase='BLOCKED',reason='Safe game-thread scheduler unavailable',blocker='Safe game-thread scheduler unavailable'});return
end
local modules={}
for _,name in ipairs({'runtime','ai','time','events','modes','native_ai','damage','score','round_audio','controller'})do
    local ok,m=pcall(dofile,dir..'variant_'..name..'.lua')
    if not ok or type(m)~='table'then
        local reason='Module unavailable: '..name..(not ok and(': '..tostring(m):sub(1,500))or' (module table missing)')
        status({phase='BLOCKED',reason=reason,blocker=reason});log(reason);return
    end
    modules[name]=m
end
-- Missing or malformed cosmetic audio must not disable playable variants.
do
    local ok,m=pcall(dofile,dir..'variant_vocals.lua')
    if ok and type(m)=='table'then modules.vocals=m
    else log('Optional zombie vocals unavailable: '..tostring(m):sub(1,240))end
end
-- Corpse presentation is optional and never blocks native gameplay guards.
do
    local ok,m=pcall(dofile,dir..'variant_corpses.lua')
    if ok and type(m)=='table'then modules.corpses=m
    else log('Optional player corpse cleanup unavailable: '..tostring(m):sub(1,240))end
end
-- The pinned native companion loads once, before the first controller is built.
-- Console commands never reload or replace a loaded module.
local native_call,native_error
if type(package)=='table'and type(package.loadlib)=='function'then
    local ok,entry,reason=pcall(package.loadlib,dir..'../Native/bodycam_variants_native.dll','bodycam_bridge_call')
    if ok and type(entry)=='function'then native_call=entry else native_error=tostring(reason or entry):sub(1,220)end
else native_error='Native library loader unavailable' end
if native_error then log('Native companion unavailable: '..native_error)end
local function legacy_status(c)
    local f=io.open(dir..'../../BodycamZombieChill/Scripts/status.json','rb');if not f then return false end
    local value=f:read(65536);f:close();if type(value)~='string'then return false end
    local phase=value:match('"phase"%s*:%s*"([A-Z_]+)"')
    local world=value:match('"world"%s*:%s*"([^"\\]*)"')
    local ok,name=pcall(function()return c.world:GetFullName()end)
    if not ok or type(world)~='string'or world~=name then return nil end
    local function number(field)
        local n=tonumber(value:match('"'..field..'"%s*:%s*([%d%.eE+%-]+)'))
        return type(n)=='number'and n==n and n>=0 and n~=math.huge and n or nil
    end
    return {phase=phase,started_at=number('started_at'),deadline=number('deadline'),
        clock_seconds=number('clock_seconds'),prematch_started_at=number('prematch_started_at')}
end
local function legacy_active(c)
    local s=legacy_status(c)
    return s and(s.phase=='PREMATCH'or s.phase=='RUNNING'or s.phase=='SMOKE_TEST')or false
end
local function legacy_audio_status(c)
    local s=legacy_status(c)
    if s and(s.phase=='PREMATCH'or s.phase=='RUNNING'or s.phase=='FINISHED')then return s end
end
local api={StaticFindObject=StaticFindObject,FindAllOf=FindAllOf,LoadAsset=LoadAsset,FName=FName,FText=FText,
    StaticConstructObject=StaticConstructObject,RegisterHook=RegisterHook,UnregisterHook=UnregisterHook,
    EInternalObjectFlags=EInternalObjectFlags}
local instance,handle;local initialized=false;local failed=false;local stopping=false;local finished=false;local last_reason
local heartbeat=0;local last_status_tick=-4;local last_status_phase,last_status_reason
local performance={clock='os.clock',status_interval_ms=2000,tick_samples=0,tick_total_ms=0,tick_max_ms=0,
    status_samples=0,status_total_ms=0,status_max_ms=0}
local function clock_now()
    if type(os)=='table'and type(os.clock)=='function'then return os.clock()end
end
local function measured(kind,before)
    local after=clock_now();if not before or not after or after<before then return end
    local ms=(after-before)*1000
    performance[kind..'_samples']=performance[kind..'_samples']+1
    performance[kind..'_total_ms']=performance[kind..'_total_ms']+ms
    performance[kind..'_last_ms']=ms
    performance[kind..'_max_ms']=math.max(performance[kind..'_max_ms'],ms)
end
local function finish_stop()
    if instance and instance.stop()~=true then status(instance.status());return false end
    finished=true;CancelDelayedAction(handle);return true
end
handle=LoopInGameThreadWithDelay(500,function()
    if finished then return end
    local ok,err=pcall(function()
        if stopping or failed then finish_stop();return end
        heartbeat=heartbeat+1;local tick_started=clock_now()
        if not initialized then
            initialized=true;instance=modules.controller.new(api,{modules=modules,log=log,native_call=native_call,
                native_load_error=native_error,legacy_active=legacy_active,legacy_audio_status=legacy_audio_status});instance.start()
        else instance.tick() end
        measured('tick',tick_started)
        local inspect,publish=false,false
        local f=io.open(dir..'command.txt','rb')
        if f then
            local command=f:read(128);f:close();command=command and command:match('^%s*(.-)%s*$')
            if command and command~='' then
                local clear=io.open(dir..'command.txt','wb');if clear then clear:close()
                    if command=='stop'then stopping=true;finish_stop();publish=true
                    elseif command=='reload'then log('Live reload is disabled; restart Bodycam for new files')
                    elseif command=='inspect'then inspect=true
                    else log('Unknown command: '..command)end
                end
            end
        end
        local phase,reason
        if type(instance.phase)=='function'then phase,reason=instance.phase()end
        if inspect or publish or heartbeat-last_status_tick>=4 or phase~=last_status_phase or reason~=last_status_reason then
            local status_started=clock_now();local s=instance.status(inspect);s.native_load_error=native_error
            local timing={};for k,v in pairs(performance)do timing[k]=v end;s.performance=timing;status(s)
            measured('status',status_started);last_status_tick=heartbeat;last_status_phase=phase;last_status_reason=reason
            if s.blocker~=last_reason then last_reason=s.blocker;if last_reason then log(last_reason)end end
        end
    end)
    if not ok then
        failed=true;stopping=true
        -- Keep the cleanup heartbeat running until owned actors and hooks are gone.
        local reason=tostring(err):sub(1,500)
        pcall(finish_stop);status({phase=instance and'CLEANUP_REQUIRED'or'BLOCKED',reason=reason,blocker=reason});log(err)
    end
end)
