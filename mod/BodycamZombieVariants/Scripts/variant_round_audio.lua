-- Round-boundary audio bridge. No wave/spawn hooks and no gameplay mutations.
-- The default cue is a staged candidate pending the user's listening check.
local M={}
M.PHASE_PATH='/Game/GM/GT_Base.GT_Base_C:BP_HandleCurrentPhaseChanged'
M.DEFAULT_SOUND='/Game/Ultimate_SFX/GameSounds/Events/WaveEnd_Cue.WaveEnd_Cue'
M.CLIENT_RPC='/Script/Engine.PlayerController:ClientPlaySound'
local GT='/Game/GM/GT_Base.GT_Base_C'
local PC='/Script/Engine.PlayerController'
local START='Game.Phase.StartRound'
local END='Game.Phase.EndRound'
local MATCH_END='Game.Phase.EndMatch'
local function get(o,k)if o~=nil then local ok,v=pcall(function()return o[k]end);if ok then return v end end end
local function call(o,k,...)
    local f=get(o,k);if f==nil then return false end
    return pcall(f,o,...)
end
local function unwrap(v)local ok,r=call(v,'get');if ok then return r end;return v end
local function finite(v)return type(v)=='number'and v==v and v~=math.huge and v~=-math.huge end
local function text(v)
    v=unwrap(v);if type(v)=='string'then return v end
    local ok,s=call(v,'ToString');return ok and type(s)=='string'and s or nil
end
local function tag(v)return text(get(unwrap(v),'TagName'))or text(v)end
function M.new(runtime,api,options)
    assert(type(runtime)=='table','Runtime is required')
    api,options=api or {},options or {}
    local self={};local sound,pcclass,gtclass;local hook;local running=false;local version=0
    local epochs={};local order={};local supplied
    local info={ready=false,starts=0,ends=0,client_calls=0,errors=0,duplicates=0,
        source='native_phase_event_and_scoped_legacy_status',guest_mod_required=false,
        guest_audio_live_verified=false,cue_confirmed=options.sound_confirmed==true,
        awaiting_sound=options.sound_confirmed~=true,muted_boundaries=0,
        sound_path=options.sound_path or M.DEFAULT_SOUND}
    local function live(o)return o~=nil and runtime.live(o)==true end
    local function playback_ready()
        return not info.cue_confirmed or(live(sound)and live(pcclass))
    end
    local function fail(message)
        info.errors=info.errors+1;info.last_error=tostring(message):sub(1,300)
        if options.on_error then pcall(options.on_error,info.last_error)end
    end
    local function load(path)
        local obj=runtime.find(path)
        if not live(obj)and runtime.load_asset then pcall(runtime.load_asset,path);obj=runtime.find(path)end
        return live(obj)and obj or nil
    end
    local function is_a(o,cl)local ok,r=call(o,'IsA',cl);return ok and r==true end
    local function scoped(c)
        if type(c)~='table'or c.authority~=true or c.active~=true or c.owner~='BodycamZombieVariants'
            or type(c.variant)~='table'or not finite(c.generation)or not live(c.world)then return nil end
        local wk=c.world_id or c.world_key
        if type(wk)~='string'or wk==''or runtime.key(c.world)~=wk then return nil end
        local gm=c.gamemode or c.game_mode
        if not live(gm)or not runtime.belongs(gm,c.world)then return nil end
        local ok,a=call(gm,'HasAuthority');if not ok or a~=true then return nil end
        if get(c.world,'AuthorityGameMode')~=gm and runtime.key(get(c.world,'AuthorityGameMode'))~=runtime.key(gm)then return nil end
        return c
    end
    local function context()
        if options.get_context then local ok,c=pcall(options.get_context);if ok then return scoped(c)end;return nil end
        return scoped(supplied)
    end
    local function epoch(c)
        local id=(c.world_id or c.world_key)..'#'..string.format('%.0f',c.generation)
        if not epochs[id]then
            epochs[id]={seen={},round_order={}};order[#order+1]=id
            if #order>16 then epochs[table.remove(order,1)]=nil end
        end
        return epochs[id]
    end
    local function record(e,id)
        if not e.seen[id]then
            e.seen[id]={};e.round_order[#e.round_order+1]=id
            if #e.round_order>256 then e.seen[table.remove(e.round_order,1)]=nil end
        end
        return e.seen[id]
    end
    local function play(c,e,id,kind)
        local row=record(e,id)
        if row[kind]then info.duplicates=info.duplicates+1;return false end
        -- Consume before RPC dispatch: a thrown/partial RPC must never be replayed.
        row[kind]=true
        if not info.cue_confirmed then info.muted_boundaries=info.muted_boundaries+1;return false end
        if kind=='start'then info.starts=info.starts+1 else info.ends=info.ends+1 end
        local ok,controllers=pcall(runtime.find_all,'PlayerController',256)
        if not ok or type(controllers)~='table'then fail('Native player-controller roster is unavailable');return false end
        local sent={}
        for _,pc in pairs(controllers)do
            if live(pc)and is_a(pc,pcclass)and runtime.belongs(pc,c.world)then
                local auth,a=call(pc,'HasAuthority');local key=runtime.key(pc)
                if auth and a==true and key and not sent[key]then
                    sent[key]=true
                    local delivered,result=call(pc,'ClientPlaySound',sound,1.0,1.0)
                    if delivered and result~=false then info.client_calls=info.client_calls+1
                    else fail('Native ClientPlaySound dispatch failed for a scoped controller')end
                end
            end
        end
        info.last_boundary=kind;info.last_round=id;return true
    end
    local function gs_for(c)
        local gs=c.gamestate or c.game_state or get(c.world,'GameState')
        if live(gs)and is_a(gs,gtclass)and runtime.belongs(gs,c.world)then return gs end
    end
    local function native_phase(c,gs,phase,event)
        if c.audio_legacy==true then return end
        local e=epoch(c);local start=get(gs,'RoundStartTime');local round=get(gs,'CurrentRound')
        if not finite(start)or start<0 or not finite(round)or round%1~=0 or round<0 then return end
        local id='native:'..tostring(runtime.key(gs))..':'..string.format('%.0f',round)..':'..string.format('%.17g',start)
        if phase==START then
            local row=record(e,id)
            if not row.start then
                -- A startup/suspension in the middle of a round must not replay
                -- its opening. The synchronous native event is authoritative;
                -- polling catches a very recent event during world activation.
                local ok,now=call(gs,'GetServerWorldTimeSeconds')
                if event or(ok and finite(now)and now>=start and now-start<=2.0)then play(c,e,id,'start')
                else row.start=true;row.primed=true end
            end
            e.native_open=id
        elseif phase==END or phase==MATCH_END then
            local opened=e.native_open
            if opened then
                local row=e.seen[opened]
                if row and row.start and not row['end']then play(c,e,opened,'end')end
            end
        end
    end
    local function legacy_phase(c)
        local s=c.audio_legacy_status
        if type(s)~='table'then return end
        local e=epoch(c);local started,deadline=s.started_at,s.deadline
        if not finite(started)or not finite(deadline)or deadline<=started then return end
        local id='legacy:'..string.format('%.17g',started)..':'..string.format('%.17g',deadline)
        if s.phase=='FINISHED'then
            -- Only a round observed during this session can end. Old status
            -- files / a late attach never cause a catch-up finishing sound.
            local row=e.seen[id]
            if row and row.start and not row['end']then play(c,e,id,'end')end
        elseif c.audio_legacy==true and s.phase=='RUNNING'then
            if not finite(c.now)or not finite(s.clock_seconds)or c.now<s.clock_seconds-0.25
                or c.now-s.clock_seconds>2.0 then return end
            local row=record(e,id)
            if not row.start then
                if c.now>=started and c.now-started<=2.0 then play(c,e,id,'start')
                else row.start=true;row.primed=true end
            end
        end
    end
    local function observe(c)
        if not running or not info.ready or not playback_ready()then return end
        c=scoped(c);if not c then return end
        legacy_phase(c)
        local gs=gs_for(c);if not gs then return end
        local ok,phase=call(gs,'GetCurrentPhase')
        if ok then native_phase(c,gs,tag(phase),false)end
    end
    function self.start()
        if running and info.ready and playback_ready()and live(gtclass)then return true end
        if hook and not running then return false,'Previous round-audio hook cleanup is incomplete'end
        if type(api.RegisterHook)~='function'or type(api.UnregisterHook)~='function'then
            info.startup_error='Round-audio hook API is unavailable';return false,info.startup_error end
        info.ready=false
        local required={GT,M.PHASE_PATH}
        if info.cue_confirmed then
            required[#required+1]=PC;required[#required+1]=info.sound_path;required[#required+1]=M.CLIENT_RPC
        end
        for _,path in ipairs(required)do
            if not load(path)then info.startup_error='Native round-audio object is unavailable: '..path;return false,info.startup_error end
        end
        gtclass=load(GT)
        if info.cue_confirmed then pcclass=load(PC);sound=load(info.sound_path)end
        if hook then info.ready=true;info.startup_error=nil;return true end
        version=version+1;local captured=version
        local ok,a,b=pcall(api.RegisterHook,M.PHASE_PATH,function(ctx,phase)
            if not running or captured~=version or not info.ready or not playback_ready()then return end
            local c=context();if not c then return end
            local gs=unwrap(ctx);local expected=gs_for(c)
            if not expected or not live(gs)or runtime.key(gs)~=runtime.key(expected)then return end
            native_phase(c,gs,tag(phase),true)
        end)
        -- IDs are opaque: observed script registrations return an equal pair.
        if not ok or not finite(a)or a<0 or not finite(b)then
            info.startup_error='Native round phase observer did not register';return false,info.startup_error end
        hook={a,b};running=true;info.ready=true;info.startup_error=nil
        return true
    end
    function self.tick(c)supplied=c;observe(c);return info.ready end
    function self.stop()
        running=false;info.ready=false;supplied=nil;version=version+1
        if hook then
            local ok,result=pcall(api.UnregisterHook,M.PHASE_PATH,hook[1],hook[2])
            if not ok or result==false then info.last_error='Round-audio hook cleanup failed';return false,info.last_error end
            hook=nil
        end
        return true
    end
    function self.snapshot()
        if info.ready and(not playback_ready()or not live(gtclass))then info.ready=false end
        local out={};for k,v in pairs(info)do out[k]=v end;return out
    end
    return self
end
return M
