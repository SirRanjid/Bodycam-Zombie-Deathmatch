-- Scalar-only adapter for the separately loaded exact-build native score gate.
-- Ownership never follows an enum, actor name, tag, or arbitrary AI controller.
local M={}
M.OP={status=20,activate=21,register=22,unregister=23,reset=24,refresh=25,configure_xp=26,
    configure_reward=28,retire=29,reward_stats=30}
local AI='/Game/BodycamZombies/ZombieAI/AIC_Zombie.AIC_Zombie_C'
local PLAYER='/Script/Engine.PlayerController'
local PC='/Game/GM/PC_Bodycam.PC_Bodycam_C'
local ZOMBIE='/Game/BodycamZombies/ZombieAI/Zombie.Zombie_C'
local KILL=PC..':Update Kill'
local UBER=ZOMBIE..':ExecuteUbergraph_Zombie'
local PLAYER_STATE='/Script/Bodycam.BodycamPlayerState'
local GAME_STATE='/Script/Bodycam.BodycamGameState'
local SCORE_RULE='/Script/Bodycam.BodycamScoreLimitRuleComponent'
local function call(o,k,...)
    if o==nil then return false end
    local ok,f=pcall(function()return o[k]end)
    if not ok or f==nil then return false end
    return pcall(f,o,...)
end
local function integer(v)return type(v)=='number'and v==v and v>0 and v<9007199254740992 and v%1==0 end
local function address(o)
    local ok,n=call(o,'GetAddress');return ok and integer(n)and n or nil
end
function M.new(runtime,options)
    assert(type(runtime)=='table','Runtime is required')
    options=options or {}
    local self={};local started=false;local failed=false;local current;local rows={}
    local info={ready=false,zero_native_score=false,zero_progression=false,active=false,
        registered=0,errors=0,method='native_before_score_and_rule_dispatch',
        live_game_verified=false,coverage='none',zombie_reward='one_match_point_per_five_team_kills',
        native_kill_counter_blocked=false,reward_ready=false,reward_deaths=0,reward_points=0,
        reward_duplicates=0,reward_rejected=0,reward_retired=0,reward_remainder=0,reward_teams=0}
    local function failure(reason)
        failed=true;info.ready=false;info.zero_native_score=false;info.zero_progression=false
        info.reward_ready=false;info.native_kill_counter_blocked=false
        info.errors=info.errors+1;info.last_error=tostring(reason)
        if options.on_error then pcall(options.on_error,info.last_error)end
        return false,info.last_error
    end
    local function invoke(op,...)
        if type(options.native_call)~='function'then return false end
        local ok,v,reason=pcall(options.native_call,op,...)
        return ok and type(v)=='number',v,type(reason)=='string'and reason:sub(1,160)or nil
    end
    local function capability()
        info.ready=false;info.zero_native_score=false;info.zero_progression=false
        info.reward_ready=false;info.native_kill_counter_blocked=false
        if not started or failed then return false end
        local ok,bits=invoke(M.OP.status)
        if not ok or not integer(bits)or(bits&5)~=5 then return false end
        local xp=(bits&2)==2
        local reward=(bits&16)==16
        info.coverage=xp and'native_and_blueprint_gate'or'none'
        info.ready=xp and reward;info.zero_progression=xp
        info.native_kill_counter_blocked=xp;info.reward_ready=reward
        return info.ready
    end
    local function context(c)
        if not c or c.authority~=true or not integer(c.generation)then return nil end
        local world=c.world;local gm=c.gamemode or c.game_mode
        if runtime.live(world)~=true or runtime.live(gm)~=true then return nil end
        local id=c.world_key or c.world_id
        local w,g=address(world),address(gm)
        if type(id)~='string'or id==''or not w or not g then return nil end
        local ok,authority=call(gm,'HasAuthority')
        if not ok or authority~=true or runtime.belongs(gm,world)~=true then return nil end
        return {world=id,world_address=w,gm_address=g,generation=c.generation}
    end
    local function same(a,b)
        return a and b and a.world==b.world and a.world_address==b.world_address
            and a.gm_address==b.gm_address and a.generation==b.generation
    end
    local function loaded(path,asset)
        local object=runtime.find(path)
        if runtime.live(object)~=true and type(runtime.load_asset)=='function'then
            pcall(runtime.load_asset,asset or path);object=runtime.find(path)
        end
        return runtime.live(object)==true and object or nil
    end
    function self.start()
        if failed then return false,info.last_error end
        started=true
        local ok,bits=invoke(M.OP.status)
        if not ok or not integer(bits)or(bits&5)~=5 then return false,'Native score bridge unavailable'end
        local kill=loaded(KILL,PC);local uber=loaded(UBER,ZOMBIE)
        local k,u=address(kill),address(uber)
        if not k or not u then return false,'Exact Blueprint reward functions unavailable'end
        local configured,value=invoke(M.OP.configure_xp,k,u)
        if not configured or value~=1 then return false,'Native Blueprint reward guard unavailable'end
        local ps,gs,rule=address(loaded(PLAYER_STATE)),address(loaded(GAME_STATE)),address(loaded(SCORE_RULE))
        if not ps or not gs or not rule then return false,'Native reward state classes unavailable'end
        configured,value=invoke(M.OP.configure_reward,ps,gs,rule)
        if not configured or value~=1 then return false,'Native team reward bridge unavailable'end
        if not capability()then return false,'Native score/progression coverage unavailable'end
        return true
    end
    function self.ready()return capability()end
    function self.activate(c)
        if not capability()then return false,'Native score/progression gate unavailable'end
        local next=context(c);if not next then return false,'Confirmed authority context required'end
        if same(current,next)then return self.refresh(c)end
        local ai=loaded(AI);local player=loaded(PLAYER)
        if runtime.live(ai)~=true or runtime.live(player)~=true then return false,'Controller classes unavailable'end
        local a,p=address(ai),address(player);if not a or not p then return false,'Controller class identity unavailable'end
        local got,rule=call(c.gamemode or c.game_mode,'GetComponentByClass',loaded(SCORE_RULE))
        local rule_address=got and runtime.live(rule)==true and address(rule)or 0
        info.reward_supported=rule_address~=0
        if info.reward_supported then info.reward_reason=nil
        else info.reward_reason='Native mode has no score-limit rule; zombie match bonus disabled'end
        local ok,value,why=invoke(M.OP.activate,next.world_address,next.gm_address,next.generation,a,p,rule_address)
        if not ok or value~=1 then return failure('Native score activation rejected'..(why and(': '..why)or''))end
        current=next;rows={};info.registered=0;info.active=true;return true
    end
    function self.refresh(c)
        if not capability()or not same(current,context(c))then return false,'Score world context changed'end
        local ok,value=invoke(M.OP.refresh)
        if not ok or value~=1 then return failure('Native score authority heartbeat rejected')end
        return true
    end
    local function register(row,c,binding)
        if not capability()or not same(current,context(c))then return false,'Score world is not active'end
        local actor=row and row.actor
        if runtime.live(actor)~=true or runtime.belongs(actor,c.world)~=true
            or runtime.is_owned_zombie(actor)~=true then return false,'Exact owned zombie required'end
        local id=runtime.owned_id(actor);local pawn=address(actor)
        local ok,authority=call(actor,'HasAuthority')
        if not id or row.id~=id or not pawn or not ok or authority~=true then return false,'Zombie authority unavailable'end
        if not rows[id]and info.registered>=256 then return false,'Native ownership capacity reached'end
        local controller=0
        if binding then
            if runtime.live(row.controller)~=true or runtime.belongs(row.controller,c.world)~=true then return false,'Live owned controller required'end
            controller=address(row.controller);if not controller then return false,'Controller identity unavailable'end
        end
        local accepted,result=invoke(M.OP.register,pawn,controller,c.generation)
        if not accepted or result~=1 then return failure('Native owned-zombie registration rejected')end
        if not rows[id]then info.registered=info.registered+1 end
        -- Primitive address survives actor destruction for subsequent removal.
        rows[id]={pawn=pawn,generation=c.generation,world=current.world,retired=rows[id]and rows[id].retired or false}
        return true
    end
    function self.prepare_zombie(row,c)return register(row,c,false)end
    function self.bind_controller(row,c)return register(row,c,true)end
    function self.retire(row,c)
        local record=row and rows[row.id]
        if not record or record.retired then return true end
        if not current or record.world~=current.world or record.generation~=current.generation then return false,'Score registry generation changed'end
        local ok,value=invoke(M.OP.retire,record.pawn,record.generation)
        if not ok or value~=1 then return failure('Native zombie reward retirement rejected')end
        record.retired=true;return true
    end
    function self.unregister(row,c)
        local record=row and rows[row.id]
        if not record then return true end
        if not current or record.world~=current.world or record.generation~=current.generation then return false,'Score registry generation changed'end
        local ok,value=invoke(M.OP.unregister,record.pawn,record.generation)
        if not ok or value~=1 then return failure('Native zombie removal rejected')end
        rows[row.id]=nil;info.registered=info.registered-1;return true
    end
    function self.deactivate()
        if not current and info.registered==0 then info.active=false;return true end
        local ok,value=invoke(M.OP.reset)
        if not ok or value~=1 then return failure('Native score reset rejected')end
        current=nil;rows={};info.registered=0;info.active=false;info.reward_supported=nil;info.reward_reason=nil;return true
    end
    function self.stop()
        local ok,err=self.deactivate();started=false;info.ready=false
        info.zero_native_score=false;info.zero_progression=false;return ok,err
    end
    function self.snapshot()
        capability()
        if info.reward_ready then
            local values={pcall(options.native_call,M.OP.reward_stats)}
            local names={'reward_deaths','reward_points','reward_duplicates','reward_rejected','reward_retired','reward_remainder','reward_teams'}
            if values[1]then for i,name in ipairs(names)do
                local v=values[i+1];if type(v)=='number'and v>=0 and v<9007199254740992 and v%1==0 then info[name]=v end
            end end
            if values[1]and values[9]==0 then
                info.reward_supported=false;info.reward_reason='Native mode has no valid score-limit rule; zombie match bonus disabled'
            elseif values[1]and values[9]==1 then info.reward_supported=true;info.reward_reason=nil end
        end
        local out={};for k,v in pairs(info)do out[k]=v end;return out
    end
    return self
end
return M
