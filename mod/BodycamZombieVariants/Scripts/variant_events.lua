-- Native death observation and policies for a verified native damage/score bridge.
-- Blueprint RegisterHook callbacks are observers; they never repair health or scores.
local M={}
M.DEATH_PATH='/Game/AdvancedLocomotionV4/Blueprints/Components/WW_SurvivorStatus.WW_SurvivorStatus_C:K2_OnOutofHealth'
M.DEATH_CLASS=M.DEATH_PATH:match('^(.*):')
M.OWNER='BodycamZombieVariants'
local function call(o,k,...)
    if o==nil then return false end
    local args=table.pack(...)
    local ok,f=pcall(function()return o[k]end)
    if ok and f~=nil then return pcall(f,o,table.unpack(args,1,args.n))end
    local read,mt=pcall(getmetatable,o);f=read and type(mt)=='table' and rawget(mt,k)
    if type(f)=='function'then return pcall(f,o,table.unpack(args,1,args.n))end
    return false
end
local function get(o,k)local ok,v=pcall(function()return o[k]end);if ok then return v end end
local function unwrap(o)local ok,v=call(o,'get');if ok then return v end;return o end
local function finite(n)return type(n)=='number'and n==n and n~=math.huge and n~=-math.huge end
local function vector(v)
    if v and finite(get(v,'X'))and finite(get(v,'Y'))and finite(get(v,'Z'))then
        return {X=v.X,Y=v.Y,Z=v.Z}
    end
end
local function text(v)
    if type(v)=='string'then return v end
    local ok,s=call(v,'ToString');return ok and type(s)=='string'and s or nil
end
local function key(o)
    local ok,n=call(o,'GetFullName');if not ok or type(n)~='string'then return nil end
    local read,a=call(o,'GetAddress')
    return read and (type(a)=='number'or type(a)=='string')and(n..'@'..tostring(a))or n
end

-- The amount is the native final damage, after the game's own bone/weapon factors.
-- These policies are deliberately separate from observation hooks. A post-death
-- callback cannot retroactively prevent a fatal hit or a native round transition.
function M.hit_policy(event)
    if type(event)~='table'or event.owner~=M.OWNER or event.owned~=true
        or event.authority~=true or event.phase~='before_health_commit'
        or not finite(event.amount)or event.amount<0 then return nil,'Invalid authoritative damage event'end
    local bone=text(event.hit_bone)
    if not bone or bone==''or bone:lower()=='none'then return nil,'An actual hit bone is required'end
    bone=bone:lower()
    local head=bone=='head' -- An actual head hit; neck and all other bones are body.
    local factor=head and 1.0 or 1.0
    return {amount=event.amount*factor,factor=factor,body_hit=not head,
        rush_target=not head and event.original_instigator_player_key or nil}
end

function M.score_policy(event)
    if type(event)~='table'or event.owner~=M.OWNER or event.authority~=true
        or event.phase~='before_native_kill_dispatch'then return nil,'Invalid score boundary'end
    if event.victim_owned_zombie==true then
        return {suppress_kill_dispatch=true,score_delta=0,objective_delta=0}
    end
    return {suppress_kill_dispatch=false}
end

function M.new(api,options)
    api,options=api or {},options or {}
    local self={};local hooks={};local context;local players={};local aliases={};local lives={}
    local pending={};local epoch=0;local life_sequence=0;local hook_token=0;local active=false;local cleanup_failed=false
    local queue_limit=math.max(16,math.min(1024,math.floor(tonumber(options.max_pending_deaths)or 256)))
    local info={death_observer=false,damage_pre_apply=false,zero_native_score=false,
        native_damage_replication_verified=false,ready=false,deaths=0,duplicates=0,ignored=0,
        observed_callbacks=0,context_rejected=0,unregistered_deaths=0,callback_errors=0,
        queue_dropped=0,reason='A verified native pre-damage and pre-score bridge is required'}
    local object_key=options.object_key or key
    local function event_summary(event,outcome)
        local out={outcome=outcome,generation=finite(event.generation)and event.generation or nil,position=vector(event.position)}
        for _,field in ipairs({'event_id','victim_key','victim_pawn_key','victim_life','killer_key','killer_life','world_key','source'})do
            local value=event[field];if type(value)=='string'then out[field]=value:sub(1,1024)end
        end
        return out
    end
    local function clean_tables()players={};aliases={};lives={};pending={}end
    local function current()
        local c
        if options.get_context then c=options.get_context()else c=context end
        if type(c)~='table'or c.active~=true or c.owner~=M.OWNER
            or type(c.world_key)~='string'or c.world_key==''
            or not finite(c.generation)then return nil end
        return c
    end
    local function synchronized()
        local c=current()
        if not c then context=nil;clean_tables();return nil end
        if not context or c.world_key~=context.world_key or c.generation~=context.generation then
            epoch=epoch+1;clean_tables()
        end
        -- Only primitive context values survive this call.
        context={active=true,owner=M.OWNER,world_key=c.world_key,generation=c.generation}
        return context
    end
    local function live(o,c)
        if o==nil then return false end
        if options.is_live then local ok,v=pcall(options.is_live,o,c.world_key);return ok and v==true end
        local ok,v=call(o,'IsValid');if not ok or v~=true then return false end
        -- UE4SS IsValid alone can accept a PendingKill UObject.
        local checked=false
        local find=api.StaticFindObject
        if type(find)=='function'then
            local found,cdo=pcall(find,'/Script/Engine.Default__KismetSystemLibrary')
            local located,fn=pcall(find,'/Script/Engine.KismetSystemLibrary:IsValid')
            if found and located then
                local read,valid=call(fn,'CallFunction',cdo,o)
                if read and type(valid)=='boolean'then checked=true;if not valid then return false end end
            end
        end
        if not checked then
            local flags=api.EInternalObjectFlags
            if type(flags)~='table'then return false end
            for _,field in ipairs({'PendingKill','Unreachable'})do
                if type(flags[field])~='number'then return false end
                local read,bad=call(o,'HasAnyInternalFlags',flags[field])
                if not read or type(bad)~='boolean'or bad then return false end
            end
        end
        local read,destroying=call(o,'IsActorBeingDestroyed');if read and destroying then return false end
        local located,w=call(o,'GetWorld')
        return located and object_key(w)==c.world_key
    end
    local function authority(o)local ok,v=call(o,'HasAuthority');return ok and v==true end
    local function player_for(o,c,require_alive)
        if not live(o,c)then return nil end
        local id=object_key(o);local p=id and aliases[id]
        if not p or not players[p.key]or not live(p.pawn,c)or not authority(p.pawn)then return nil end
        if id~=p.pawn_key then
            local ok,controller=call(p.pawn,'GetController')
            if not ok or object_key(controller)~=id then return nil end
            local got,pawn=call(o,'K2_GetPawn')
            if not got or object_key(pawn)~=p.pawn_key then return nil end
        end
        -- Aliases only come from a supplied actual pawn and its actual controller.
        if require_alive then
            local life=lives[p.pawn_key]
            if p.alive~=true or not life or life.dead then return nil end
            local status=get(p.pawn,'WW_SurvivorStatus')
            if get(status,'Death?')==true then return nil end
        end
        return p
    end
    function self.sync_players(records)
        local c=synchronized();if not c then return false end
        players={};aliases={};local retained_lives={}
        for index,record in ipairs(records or {})do
            if index>256 then break end
            if type(record.key)=='string'and live(record.pawn,c)and authority(record.pawn)then
                local pk=object_key(record.pawn)
                if pk then
                    local life=lives[pk]
                    local supplied_life=type(record.life)=='string'and record.life~=''and record.life or nil
                    if not life then
                        life_sequence=life_sequence+1;life={serial=life_sequence,dead=false,external=supplied_life}
                    elseif record.alive==true and get(get(record.pawn,'WW_SurvivorStatus'),'Death?')==false
                        and(life.dead or supplied_life and supplied_life~=life.external)then
                        life_sequence=life_sequence+1;life.serial=life_sequence;life.dead=false;life.external=supplied_life
                    end
                    retained_lives[pk]=life
                    local p={key=record.key,pawn=record.pawn,pawn_key=pk,alive=record.alive==true,
                        life=life.external or(pk..'#'..life.serial)}
                    local got,location=call(record.pawn,'K2_GetActorLocation')
                    p.position=got and vector(location)or vector(record.position)
                    players[p.key]=p;aliases[pk]=p
                    local got_controller,controller=call(record.pawn,'GetController')
                    if got_controller and live(controller,c)and authority(controller)
                        and (record.controller==nil or object_key(controller)==object_key(record.controller))then
                        local ck=object_key(controller);if ck then aliases[ck]=p end
                    end
                end
            end
        end
        -- Disconnected/replaced pawns have no alias and cannot emit accepted events.
        -- Their tombstones can be dropped; the serial remains unique within epoch.
        lives=retained_lives
        return true
    end
    local function death(component,instigator)
        local c=synchronized();if not active or not c then
            info.context_rejected=info.context_rejected+1;info.last_observation='no_active_context';return
        end
        component=unwrap(component);instigator=unwrap(instigator)
        local ok,actor=call(component,'GetOwner')
        if not ok or not live(actor,c)or not authority(actor)then
            info.ignored=info.ignored+1;info.last_observation='invalid_or_non_authoritative_owner';return
        end
        local p=player_for(actor,c,false)
        if not p then
            -- Owned zombie deaths and pawns absent from the synchronized player
            -- roster cannot create revenge zombies. Count this separately so a
            -- received native event cannot look like an absent hook callback.
            info.unregistered_deaths=info.unregistered_deaths+1;info.last_observation='victim_not_in_player_roster';return
        end
        local life=lives[p.pawn_key]
        if life.dead then info.duplicates=info.duplicates+1;info.last_observation='duplicate_life';return end
        -- The native event is authoritative. Explicitly alive components reject
        -- delayed callbacks from a previous life; unavailable flags are tolerated.
        if get(component,'Death?')==false then info.ignored=info.ignored+1;info.last_observation='component_explicitly_alive';return end
        life.dead=true;p.alive=false
        local got,position=call(actor,'K2_GetActorLocation')
        position=got and vector(position)or p.position
        if not position then info.ignored=info.ignored+1;info.last_observation='death_position_unavailable';return end
        local killer=player_for(instigator,c,true)
        if killer and killer.key==p.key then killer=nil end
        local event={event_id=tostring(epoch)..':'..p.pawn_key..':'..life.serial,
            victim_key=p.key,victim_pawn_key=p.pawn_key,victim_life=p.life,killer_key=killer and killer.key or nil,
            killer_life=killer and killer.life or nil,position=position,
            world_key=c.world_key,generation=c.generation,source=M.DEATH_PATH}
        info.deaths=info.deaths+1
        info.last_observed=event_summary(event,'accepted_native_death')
        -- The optional observer may capture this exact dead pawn synchronously.
        -- Only the primitive event enters the deferred spawn queue below.
        if options.on_death_observed then
            local observed,err=pcall(options.on_death_observed,event,actor)
            if not observed then info.observation_error=tostring(err):sub(1,180)end
        end
        -- Queue primitives only. Spawning inside the native death call risks
        -- re-entrancy into gameplay delegates and map transitions.
        if #pending<queue_limit then
            pending[#pending+1]=event;info.last_observation='queued';info.last_queued=event_summary(event,'queued')
        else info.queue_dropped=info.queue_dropped+1;info.last_observation='queue_full' end
    end
    function self.drain()
        local batch=pending;local c=synchronized();pending={}
        if not c or not active then
            if #batch>0 then info.last_drained=event_summary(batch[#batch],'discarded_no_active_context')end
            return 0
        end
        local count=0
        for _,event in ipairs(batch)do
            c=synchronized();if not c or not active then
                info.last_drained=event_summary(event,'discarded_no_active_context');break
            end
            if event.world_key==c.world_key and event.generation==c.generation then
                if options.on_player_death then
                    local ok,err=pcall(options.on_player_death,event)
                    if not ok then info.callback_error=tostring(err):sub(1,180)end
                    info.last_drained=event_summary(event,ok and'delivered_to_death_callback'or'death_callback_error')
                    -- A nil callback return is not evidence that a zombie spawned.
                    if ok and type(err)=='boolean'then info.last_drained.callback_result=err end
                else
                    info.last_drained=event_summary(event,'no_death_callback')
                end
                count=count+1
            else
                info.last_drained=event_summary(event,'discarded_world_or_generation_changed')
            end
        end
        return count
    end
    function self.start()
        if active then return true end
        if cleanup_failed then return false,'Previous native observer cleanup failed; restart required'end
        if type(api.RegisterHook)~='function'or type(api.UnregisterHook)~='function'then
            return false,'Native death registration and cleanup APIs are required'
        end
        if type(api.StaticFindObject)=='function'then
            local function available()
                local found,fn=pcall(api.StaticFindObject,M.DEATH_PATH)
                local checked,valid=call(fn,'IsValid')
                return found and checked and valid==true
            end
            if not available()and type(api.LoadAsset)=='function'then pcall(api.LoadAsset,M.DEATH_CLASS)end
            if not available()then return false,'The native out-of-health class could not be loaded'end
        end
        hook_token=hook_token+1;local installed_token=hook_token
        local wrapper=function(...)
            if not active or installed_token~=hook_token then return end
            info.observed_callbacks=info.observed_callbacks+1;info.last_observation='received'
            local ok,err=pcall(death,...)
            if not ok then
                info.callback_errors=info.callback_errors+1;info.last_observation='callback_error'
                info.callback_error=tostring(err):sub(1,180)
            end
            -- Never return an override from an observation hook.
        end
        local ok,pre,post=pcall(api.RegisterHook,M.DEATH_PATH,wrapper)
        if not ok or type(pre)~='number'or type(post)~='number'then
            return false,'The native out-of-health observer could not be registered'
        end
        hooks[1]={path=M.DEATH_PATH,pre=pre,post=post,callback=wrapper}
        active=true;info.death_observer=true
        return true
    end
    function self.stop()
        active=false;hook_token=hook_token+1;epoch=epoch+1;context=nil;clean_tables()
        local remaining={}
        for _,h in ipairs(hooks)do
            local ok,result=pcall(api.UnregisterHook,h.path,h.pre,h.post)
            if not ok or result==false then remaining[#remaining+1]=h end
        end
        hooks=remaining;cleanup_failed=#hooks>0
        info.death_observer=false;info.cleanup_failed=cleanup_failed
        return not cleanup_failed
    end
    function self.snapshot()
        local result={};for k,v in pairs(info)do
            if k=='last_observed'or k=='last_queued'or k=='last_drained'then
                result[k]=event_summary(v,v.outcome);result[k].callback_result=v.callback_result
            else result[k]=v end
        end
        result.pending=#pending;result.queue_limit=queue_limit
        result.retained_lives=0;for _ in pairs(lives)do result.retained_lives=result.retained_lives+1 end
        return result
    end
    function self.context(c)options.get_context=nil;context=nil;clean_tables();options.get_context=function()return c end end
    return self
end
return M
