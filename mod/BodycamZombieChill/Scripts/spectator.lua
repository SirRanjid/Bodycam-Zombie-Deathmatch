-- Current Bodycam build: remove eliminated participants from play until round end.
-- Uses replicated PlayerState flags and the native client spectator state. No drone.
local M={}
local PC_FIELD='PC_29_393D49BA423796C6CE182396A61CA949'
local GM='/Game/GM/GM_Bodycam.GM_Bodycam_C:'
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
local function unwrap(o)local ok,v=call(o,'get');return ok and v or o end
local function class_is(o,wanted)
    local ok,c=call(o,'GetClass');local seen={}
    for _=1,12 do
        local n=ok and name(c);if not n or seen[n] then return false end
        if n:match('([^./: ]+)$')==wanted then return true end
        seen[n]=true;ok,c=call(c,'GetSuperStruct')
    end
    return false
end
local function player_pawn(o)return class_is(o,'Bodycam_Player_C')end
function M.new(core,api,options)
    api,options=api or {},options or {}
    local self={};local records={};local hooks={};local timer;local started=false
    local info={ready=false,eliminated=0,respawns_blocked=0,game_thread_only=true,native_spectator_live_verified=false}
    local register=api.RegisterHook or RegisterHook;local unregister=api.UnregisterHook or UnregisterHook
    local loop=api.LoopInGameThreadWithDelay or LoopInGameThreadWithDelay;local cancel=api.CancelDelayedAction or CancelDelayedAction
    local make_name=api.FName or FName
    local function log(s)if options.log then pcall(options.log,'[Z-Deathmatch Zuschauer] '..tostring(s)) end end
    local function find(p)local ok,v=pcall(api.StaticFindObject,p);return ok and valid(v) and v or nil end
    local gs=find('/Script/Engine.Default__GameplayStatics')
    local function world()
        local ok,list=pcall(api.FindAllOf,'GameViewportClient')
        if ok and type(list)=='table' then for _,v in ipairs(list)do local w=get(v,'World');if valid(w) then return w end end end
    end
    local function same_world(r)local w=world();return valid(w) and name(w)==r.world_name end
    local function record(pc)local r=records[name(unwrap(pc)) or ''];return r and same_world(r) and r or nil end
    local function set_flags(r,a,b)
        if not valid(r.state) then return false end
        local ok=pcall(function()r.state.bIsSpectator=a;r.state.bOnlySpectator=b end)
        return ok and get(r.state,'bIsSpectator')==a and get(r.state,'bOnlySpectator')==b
    end
    local function goto_state(pc,state)
        if make_name==nil then return false end
        local ok,n=pcall(function()return make_name(state)end)
        return ok and call(pc,'ClientGotoState',n)
    end
    local function detach(r,force_client)
        if r.busy then return true end
        r.busy=true
        local function perform()
        if not valid(r.controller) or not same_world(r) then return false end
        if not set_flags(r,true,true) then return false end
        local got,pawn=call(r.controller,'K2_GetPawn')
        if not got then return false end
        if valid(pawn) and player_pawn(pawn) then
            -- No health damage and no synthetic kill event. The core suppresses this life.
            r.client_sent=false
            call(pawn,'DisableInput',r.controller)
            if not call(r.controller,'UnPossess') then return false end
            local read,current=call(r.controller,'K2_GetPawn')
            if not read or (valid(current) and name(current)==name(pawn)) then return false end
            if not call(pawn,'K2_DestroyActor') then return false end
            r.removed_pawn=name(pawn);r.detached=true
        elseif valid(pawn) then
            -- Keep spectator cameras intact; a perk/drone cannot give an eliminated
            -- player control. Unpossess that foreign pawn, never destroy it.
            if class_is(pawn,'SpectatorPawn') or class_is(pawn,'SpectatorCamera_C') then
                if force_client then
                    if not goto_state(r.controller,'Spectating') then return false end
                    r.client_sent=true
                end
                return true
            end
            if not call(r.controller,'UnPossess') then return false end
            r.client_sent=false
        end
        if force_client or not r.client_sent then
            if not goto_state(r.controller,'Spectating') then return false end
            r.client_sent=true
        end
        return true
        end
        local ok,result=pcall(perform);r.busy=false
        return ok and result==true
    end
    local function hook(path,pre,post)
        if hooks[path] then return true end
        if type(register)~='function' or not find(path) then return false end
        local ok,a,b=pcall(register,path,pre,post)
        if ok and type(a)=='number' and type(b)=='number' then hooks[path]={a,b};return true end
        return false
    end
    local function install_hooks()
        hook('/Script/Engine.GameModeBase:PlayerCanRestart',function(_,pc)if record(pc) then return false end end)
        hook('/Script/Engine.GameModeBase:MustSpectate',function(_,pc)if record(pc) then return true end end)
        hook('/Script/Engine.PlayerController:CanRestartPlayer',function(pc)if record(pc) then return false end end)
        -- Native hooks have real pre/post slots. Bodycam's direct Respawn bypasses
        -- Engine.RestartPlayer, but its Possess call is native: detach in its POST
        -- before another frame can process player input. No Blueprint pre-veto.
        hook('/Script/Engine.Controller:Possess',function()end,function(context)
            local r=record(context)
            if r and not r.busy then
                if detach(r,true) then info.respawns_blocked=info.respawns_blocked+1
                else info.error='Bodycam spectator possession guard failed' end
            end
        end)
        -- In this UE4SS build the FIRST Blueprint callback runs POST. This second
        -- assertion also follows any Bodycam actions after its Possess call.
        hook(GM..'Respawn',function(_,_,raw_info)
            local r=record(get(unwrap(raw_info),PC_FIELD))
            if r and not detach(r,true) then info.error='Bodycam spectator respawn guard failed' end
        end)
        info.restart_guard=hooks['/Script/Engine.Controller:Possess']~=nil and hooks[GM..'Respawn']~=nil
        return info.restart_guard
    end
    local function normal_respawn(r)
        local w=world();if not valid(w) or name(w)~=r.world_name then return true end
        local gm=get(w,'AuthorityGameMode');if not valid(gm) then return false end
        local got,pc_pawn=call(r.controller,'K2_GetPawn');if got and valid(pc_pawn) and player_pawn(pc_pawn) then return true end
        local read,state=call(gs,'GetGameState',w);if not read or not valid(state) then state=get(w,'GameState') end
        local list=get(state,'Player Connected');local matched
        local walked=call(list,'ForEach',function(_,raw)
            local row=unwrap(raw)
            if name(get(row,PC_FIELD))==name(r.controller) then matched=row;return true end
        end)
        if walked and matched then return call(gm,'Respawn',0.0,matched) end
        -- Engine fallback is a normal restart, never a custom character spawn.
        return call(gm,'RestartPlayer',r.controller)
    end
    function self.eliminate(ref)
        if type(ref)~='table' or not valid(ref.controller) or not valid(ref.player_state) then return false end
        local w=world();if not valid(w) or not valid(get(w,'AuthorityGameMode')) then return false end
        if name(get(ref.controller,'PlayerState'))~=name(ref.player_state) then return false end
        local got,level=call(ref.controller,'GetLevel');local read,owner=call(level,'GetOuter')
        if not got or not read or name(owner)~=name(w) then return false end
        local key=name(ref.controller);if not key then return false end
        local r=records[key]
        if not r then
            local a,b=get(ref.player_state,'bIsSpectator'),get(ref.player_state,'bOnlySpectator')
            if type(a)~='boolean' or type(b)~='boolean' then return false end
            r={controller=ref.controller,state=ref.player_state,world_name=name(w),was_spectator=a,was_only_spectator=b}
            records[key]=r;info.eliminated=info.eliminated+1
        end
        if not install_hooks() then info.error='Bodycam spectator respawn hooks unavailable';return false end
        return detach(r)
    end
    function self.reset(reason)
        -- Remove records first, so a normal reset respawn is accepted by our hooks.
        local old=records;records={};info.eliminated=0
        local failed=0
        for _,r in pairs(old) do
            if valid(r.state) then
                if not set_flags(r,r.was_spectator,r.was_only_spectator) then failed=failed+1 end
            end
            if valid(r.controller) and same_world(r) then
                if not r.was_spectator and not r.was_only_spectator then
                    if not goto_state(r.controller,'Playing') then failed=failed+1 end
                    if not normal_respawn(r) then failed=failed+1 end
                end
            end
        end
        info.error=failed>0 and 'Spectator reset needs a normal map restart' or nil
        return failed==0
    end
    function self.tick()
        install_hooks()
        local bad=false
        for k,r in pairs(records)do
            if not same_world(r) then
                -- A persistent PlayerState can survive travel: clear our old flags.
                if valid(r.state) then set_flags(r,r.was_spectator,r.was_only_spectator) end
                records[k]=nil
            elseif not valid(r.controller) then records[k]=nil
            elseif not detach(r) then bad=true end
        end
        if bad and type(core.stop)=='function' then core.stop('An eliminated player could not remain a spectator') end
    end
    function self.start()
        if started then return true end
        if type(loop)~='function' or type(cancel)~='function' or type(register)~='function' or type(unregister)~='function' then return false end
        local ok,id=pcall(loop,200,function()
            if not started then return end
            self.tick()
        end)
        if not ok or type(id)~='number' then return false end
        timer=id;started=true;info.ready=true
        if type(core.set_elimination_handler)~='function' then self.shutdown();return false end
        return core.set_elimination_handler(self.eliminate,self.reset)
    end
    function self.shutdown()
        local reset=self.reset('Adapter shutdown');local failed=0
        started=false
        if timer then local ok,result=pcall(cancel,timer);if not ok or result==false then failed=failed+1 end end
        timer=nil
        for p,ids in pairs(hooks)do local ok,result=pcall(unregister,p,ids[1],ids[2]);if not ok or result==false then failed=failed+1 end end
        hooks={};info.ready=false;info.cleanup_failed=failed+(reset and 0 or 1);return reset and failed==0
    end
    function self.status()return info end
    self.info=self.status
    self.restore_all=self.reset
    return self
end
return M
