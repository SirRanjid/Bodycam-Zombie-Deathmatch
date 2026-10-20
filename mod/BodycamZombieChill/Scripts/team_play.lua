-- One real native team, with an existing team-capable config reference for peers.
-- No weapon, damage, health, friendly-fire or scoring-award APIs are changed.
local M={}
local TEAM_CONFIG='/Game/GM/DATA/DataAsset/DA_GameModeTeamDeathmatch.DA_GameModeTeamDeathmatch'
local function get(o,k)local ok,v=pcall(function()return o[k]end);if ok then return v end end
local function call(o,k,...)
    if o==nil then return false end
    local a=table.pack(...);local ok,f=pcall(function()return o[k]end)
    if ok and f~=nil then return pcall(f,o,table.unpack(a,1,a.n)) end
    local read,mt=pcall(getmetatable,o);f=read and type(mt)=='table' and rawget(mt,k)
    if type(f)=='function' then return pcall(f,o,table.unpack(a,1,a.n)) end
    return false
end
local function valid(o)local ok,v=call(o,'IsValid');return ok and v==true end
local function name(o)local ok,v=call(o,'GetFullName');return ok and type(v)=='string' and v or nil end
local function integer(v)return type(v)=='number' and v==v and v%1==0 and v>=-1 and v<=2147483647 end
function M.new(core,api,options)
    api,options=api or {},options or {}
    local self={};local started=false;local scope;local tdm
    local info={ready=false,applied=false,team_id=0,assigned=0,game_thread_only=true,
        replicated_config=true,guest_markers_live_verified=false,friendly_fire_live_verified=false,
        damage_settings_changed=false}
    local make_name=api.FName or FName
    local function log(s)if options.log then pcall(options.log,'[Z-Deathmatch Team] '..tostring(s)) end end
    local function find(p)local ok,v=pcall(api.StaticFindObject,p);return ok and valid(v) and v or nil end
    local gs_lib=find('/Script/Engine.Default__GameplayStatics')
    local team_lib=find('/Script/Bodycam.Default__BodycamGameModeLibrary')
    local kismet=find('/Script/Engine.Default__KismetSystemLibrary')
    local push=find('/Script/Engine.Default__NetPushModelHelpers')
    local interface=find('/Script/Bodycam.BodycamTeamInterface')
    local setter=find('/Script/Bodycam.BodycamTeamInterface:SetTeamId')
    local function dirty(o,field)
        if not valid(push) or make_name==nil then return false end
        local ok,n=pcall(function()return make_name(field)end)
        if not ok or not call(push,'MarkPropertyDirty',o,n) then return false end
        call(o,'FlushNetDormancy')
        return call(o,'ForceNetUpdate')
    end
    local function read_team(ps)
        local ok,id=call(team_lib,'GetPlayerTeamID',ps)
        return ok and integer(id) and id or nil
    end
    local function set_team(ps,id)
        if not valid(ps) or not integer(id) then return false end
        local checked,implements=call(kismet,'DoesImplementInterface',ps,interface)
        if not checked or implements~=true then return false end
        local member=get(ps,'SetTeamId');local ok
        if type(member)=='function' or valid(member) then
            -- Never retry a mutating UFunction after a real call failure.
            ok=pcall(member,ps,id)
        elseif valid(setter) then
            -- UE4SS LuaUObject.cpp supports standalone UFunction(context,args).
            -- Native BodycamPlayerState implements this exact interface (+0x360).
            ok=pcall(setter,ps,id)
        else return false end
        if not ok or read_team(ps)~=id then return false end
        return dirty(ps,'TeamId')
    end
    local function controller_in_world(pc,world)
        local got,level=call(pc,'GetLevel');local read,owner=call(level,'GetOuter')
        local authority,a=call(pc,'HasAuthority')
        return got and read and name(owner)==name(world) and authority and a==true
    end
    local function restore()
        if not scope then info.applied=false;return true end
        local old=scope;local failures=0
        for _,r in pairs(old.players)do
            if valid(r.state) and valid(r.controller) and controller_in_world(r.controller,old.world)
                and name(get(r.controller,'PlayerState'))==name(r.state)
                and (read_team(r.state)==0 or r.restore_pending and read_team(r.state)==r.team_id) then
                r.restore_pending=true
                if not set_team(r.state,r.team_id) then failures=failures+1 else r.restore_pending=nil end
            end
        end
        if valid(old.gm) and name(get(old.gm,'ConfigDataAsset'))==name(tdm) then
            local ok=pcall(function()old.gm.ConfigDataAsset=old.gm_config end)
            if not ok then failures=failures+1 end
        end
        if valid(old.state) and (name(get(old.state,'GameModeConfigDataAsset'))==name(tdm) or old.state_restore_pending) then
            old.state_restore_pending=true
            local ok=pcall(function()old.state.GameModeConfigDataAsset=old.state_config end)
            if not ok or not dirty(old.state,'GameModeConfigDataAsset') then failures=failures+1 else old.state_restore_pending=nil end
        end
        if valid(tdm) then
            local cfg=get(tdm,'TeamConfig')
            local ok=pcall(function()
                if get(cfg,'TeamMaxSize')==6 then cfg.TeamMaxSize=old.team_max_size end
                if get(cfg,'MaxPlayers')==6 then cfg.MaxPlayers=old.max_players end
            end)
            if not ok then failures=failures+1 end
        end
        info.applied=false;info.assigned=0;info.host_team_verified=false;info.cleanup_failed=failures
        if failures==0 then scope=nil end
        return failures==0
    end
    local function configure(world)
        local gm=get(world,'AuthorityGameMode');local got,state=call(gs_lib,'GetGameState',world)
        if not got or not valid(state) then state=get(world,'GameState') end
        if not valid(gm) or not valid(state) then return false,'Native authoritative game state is not ready' end
        local gm_config=get(gm,'ConfigDataAsset');local state_config=get(state,'GameModeConfigDataAsset')
        if not valid(gm_config) or not valid(state_config) then return false,'Native config references are not ready' end
        if not valid(tdm) then
            tdm=find(TEAM_CONFIG)
            if not tdm and type(api.LoadAsset)=='function' then local ok,v=pcall(api.LoadAsset,TEAM_CONFIG);if ok and valid(v) then tdm=v end end
        end
        if not valid(tdm) or not (name(tdm) or ''):find(TEAM_CONFIG,1,true) then return false,'Installed team config asset is unavailable' end
        local cfg=get(tdm,'TeamConfig');local max_size,max_players=get(cfg,'TeamMaxSize'),get(cfg,'MaxPlayers')
        if not integer(max_size) or max_size<2 or not integer(max_players) or max_players<6 then return false,'Installed native team config is unexpected' end
        scope={world=world,world_name=name(world),gm=gm,state=state,gm_config=gm_config,state_config=state_config,
            team_max_size=max_size,max_players=max_players,players={}}
        local changed=pcall(function()
            cfg.TeamMaxSize=6;cfg.MaxPlayers=6
            gm.ConfigDataAsset=tdm;state.GameModeConfigDataAsset=tdm
        end)
        local checked,is_team=call(state,'IsMatchTeamBased')
        if not changed or not checked or is_team~=true or not dirty(state,'GameModeConfigDataAsset') then
            restore();return false,'Native team config could not be applied and marked for replication'
        end
        info.applied=true;info.world=scope.world_name;info.config=name(tdm)
        log('Native team configuration applied; guest markers still require a live check')
        return true
    end
    function self.start()
        if started then return true end
        if not valid(gs_lib) or not valid(team_lib) or not valid(kismet) or not valid(push) or not valid(interface)
            or make_name==nil or type(core.get_players)~='function' then return false end
        started=true;info.ready=true;return true
    end
    function self.tick(status,world)
        if not started then return false end
        if type(status)~='table' or status.phase~='RUNNING' and status.phase~='PREMATCH' then return restore() end
        if not valid(world) or not valid(get(world,'AuthorityGameMode')) then return false end
        if scope and scope.world_name~=name(world) and not restore() then return false end
        if not scope then local ok,why=configure(world);if not ok then info.error=why;return false end end
        local got,players=pcall(core.get_players)
        if not got or type(players)~='table' then info.error='Native player roster is unavailable';return false end
        local count=0
        for _,p in ipairs(players)do
            local pc,ps=p.controller,p.player_state
            if valid(pc) and valid(ps) and controller_in_world(pc,world) and name(get(pc,'PlayerState'))==name(ps) then
                local id=read_team(ps);local key=name(ps)
                if id==nil or not key then info.error='Native player team is unreadable';return false end
                if not scope.players[key] then scope.players[key]={state=ps,controller=pc,team_id=id} end
                scope.players[key].controller=pc
                if id~=0 and not set_team(ps,0) then
                    info.error='Native player team assignment failed';restore();return false
                end
                count=count+1
            end
        end
        info.assigned=count;info.host_team_verified=count>0;info.error=nil
        return true
    end
    function self.shutdown()
        started=false;local ok=restore();info.ready=false;return ok
    end
    function self.restore()return restore()end
    function self.status()return info end
    return self
end
return M
