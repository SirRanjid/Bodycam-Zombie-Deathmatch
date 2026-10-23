-- Optional exact-death corpse retirement. The original player/bot pawn is the
-- ragdoll. Never select by proximity or destroy a controller/respawned pawn.
local M={}
local FINISHED='/Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/ALS_Base_CharacterBP.ALS_Base_CharacterBP_C:K2_OnDeathFinished'
M.FINISHED_PATH=FINISHED
local function finite(v)return type(v)=='number'and v==v and v~=math.huge and v~=-math.huge end
local function string_id(v)return type(v)=='string'and #v>0 and #v<=2048 end
function M.new(runtime,api,options)
    api,options=api or{},options or{}
    local self={};local entries={};local count=0;local world_id;local generation;local last_now
    local heartbeat=0;local started=false;local hook;local hook_token=0;local cleanup_failed=false
    local report={optional=true,ready=false,captured=0,committed=0,hidden=0,destroy_requested=0,
        expired=0,rejected=0,errors=0,finish_observed=0,finished_observer=false,resets=0,
        restored=0,restore_metadata_evicted=0}
    local function issue(reason)report.errors=report.errors+1;report.last_error=tostring(reason):sub(1,240);return false end
    local function reject(reason)report.rejected=report.rejected+1;report.last_rejection_reason=reason;return false end
    local function safe(fn,...)
        if type(fn)~='function'then return false end
        return pcall(fn,...)
    end
    local function call(o,name,...)
        local ok,read,value=safe(runtime.call,o,name,...)
        return ok and read==true,value
    end
    local function get(o,name)local ok,v=safe(runtime.get,o,name);if ok then return v end end
    local function key(o)local ok,v=safe(runtime.key,o);return ok and string_id(v)and v or nil end
    local function live(o)local ok,v=safe(runtime.live,o);return ok and v==true end
    local function remove(e)
        if entries[e.id]==e then entries[e.id]=nil;count=count-1 end
    end
    local function reset()
        -- Drop wrappers without calling anything on an actor from a retired world.
        entries={};count=0;world_id=nil;generation=nil;last_now=nil;heartbeat=0
        report.resets=report.resets+1
    end
    local function context(c)
        if not started or type(c)~='table'or c.enabled~=true or c.authority~=true or c.zdm_active==true
            or not string_id(c.world_id)or not finite(c.generation)or not finite(c.now)or c.now<0 then return false end
        if world_id~=c.world_id or generation~=c.generation or(last_now and c.now<last_now)then
            reset();world_id=c.world_id;generation=c.generation
        end
        last_now=c.now;return true
    end
    local function matches(event,c)
        return type(event)=='table'and string_id(event.event_id)and string_id(event.victim_pawn_key)
            and string_id(event.victim_life)and(event.world_key or event.world_id)==c.world_id
            and event.generation==c.generation
    end
    local function valid(e,c,require_native_dead)
        if entries[e.id]~=e or e.world_id~=c.world_id or e.generation~=c.generation
            or c.now<e.at or c.now-e.at>=15 then return false,'record_scope_or_ttl' end
        -- A matching address/name is never enough after a new life was observed.
        for _,p in ipairs(c.players or{})do
            if p.pawn_key==e.pawn_key and p.life~=e.life then return false,'pawn_life_changed' end
        end
        if key(e.actor)~=e.pawn_key then return false,'pawn_identity_or_liveness' end
        local ok,belongs=safe(runtime.belongs,e.actor,c.world);if not ok or belongs~=true then return false,'pawn_world' end
        local authority,auth=call(e.actor,'HasAuthority');if not authority or auth~=true then return false,'pawn_authority' end
        if get(get(e.actor,'WW_SurvivorStatus'),'Death?')~=true then return false,'blueprint_death_not_true' end
        -- Capture is inside out-of-health POST and may precede native StartDeath.
        -- Before any mutation, both the Blueprint and native state must agree.
        if not require_native_dead then return true end
        local alive,is_alive=call(e.actor,'IsCharacterAlive')
        if not alive or type(is_alive)~='boolean'then return false,'native_death_state_unavailable' end
        if is_alive then return false,'waiting_for_native_death',true end
        return true
    end
    local function hide(e,c)
        if e.hidden or e.attempts>=3 or c.now<e.next_attempt then return e.hidden==true end
        e.attempts=e.attempts+1;e.next_attempt=c.now+1
        if e.original_hidden==nil then
            local hidden,collision=get(e.actor,'bHidden'),get(e.actor,'bActorEnableCollision')
            if type(hidden)~='boolean'or type(collision)~='boolean'then return issue('Original corpse visibility/collision unavailable')end
            e.original_hidden=hidden;e.original_collision=collision
        end
        local ok=call(e.actor,'SetActorHiddenInGame',true)
        if entries[e.id]~=e then return false end
        if not ok or get(e.actor,'bHidden')~=true then return issue('Exact dead pawn could not be hidden')end
        e.hidden=true;report.hidden=report.hidden+1;report.last_hidden=e.id
        -- Native Actor.bHidden is replicated. Collision is server-only here;
        -- neither actor ticks nor death/respawn callbacks are disabled.
        local collision=call(e.actor,'SetActorEnableCollision',false)
        e.wrote_collision=collision and get(e.actor,'bActorEnableCollision')==false
        local flushed=call(e.actor,'ForceNetUpdate')
        if not collision then issue('Dead pawn server collision could not be disabled')end
        if not flushed then issue('Hidden dead pawn ForceNetUpdate failed')end
        return true
    end
    local function restore(e,p,c)
        if c.now<(e.next_restore or 0)or(e.restore_attempts or 0)>=3 then return end
        e.next_restore=c.now+1;e.restore_attempts=(e.restore_attempts or 0)+1
        -- The old wrapper may already have expired. Use only this frame's trusted
        -- roster pawn, and only for the identical key on a new, actually live life.
        local actor=p.pawn
        if key(actor)~=e.pawn_key then return end
        local checked,belongs=safe(runtime.belongs,actor,c.world)
        local auth,authority=call(actor,'HasAuthority')
        local read,alive=call(actor,'IsCharacterAlive')
        if not checked or not belongs or not auth or authority~=true or not read or alive~=true
            or get(get(actor,'WW_SurvivorStatus'),'Death?')~=false then return end
        local hidden_now,collision_now=get(actor,'bHidden'),get(actor,'bActorEnableCollision')
        if type(hidden_now)~='boolean'or type(collision_now)~='boolean'then return end
        local good=true
        if hidden_now==true and e.original_hidden==false then
            local hidden=call(actor,'SetActorHiddenInGame',false)
            local net=call(actor,'ForceNetUpdate');good=hidden and net and get(actor,'bHidden')==false
        end
        if collision_now==false and e.original_collision==true and e.wrote_collision then
            local collision=call(actor,'SetActorEnableCollision',true)
            good=collision and get(actor,'bActorEnableCollision')==true and good
        end
        if good then e.retired=true;e.actor=nil;report.restored=report.restored+1;report.last_restored=e.id
        else issue('Same-pawn revive visibility/collision restore failed')end
    end
    local function finished(context_param)
        if not started or count==0 then return end
        local unwrapped,actor=call(context_param,'get');if not unwrapped then actor=context_param end
        local pawn_key=key(actor);if not pawn_key then return end
        for _,e in pairs(entries)do
            if e.pawn_key==pawn_key and e.finished_tick==nil then
                e.finished_tick=heartbeat;report.finish_observed=report.finish_observed+1
            end
        end
        -- This Blueprint POST is inside the native completion callback. Native
        -- PlayerState respawn bookkeeping runs AFTER it returns: never destroy here.
    end
    function self.start()
        if started then return true end
        started=true;report.ready=true
        if cleanup_failed or type(api.RegisterHook)~='function'or type(api.UnregisterHook)~='function'then
            report.observer_reason='Death-finished observer unavailable; native lifespan retained';return true
        end
        local ok,fn=safe(runtime.find,FINISHED)
        if not ok or not live(fn)then
            safe(api.LoadAsset,FINISHED:match('^(.*):'))
            ok,fn=safe(runtime.find,FINISHED)
        end
        if not ok or not live(fn)then
            report.observer_reason='Death-finished Blueprint unavailable; native lifespan retained';return true
        end
        hook_token=hook_token+1;local token=hook_token
        local callback=function(...)
            if started and token==hook_token then
                local observed,err=pcall(finished,...);if not observed then issue(err)end
            end
            -- No override return value from this observer.
        end
        -- Installed UE4SS Blueprint RegisterHook invokes this callback after BP.
        local registered,pre,post=safe(api.RegisterHook,FINISHED,callback)
        if not registered or type(pre)~='number'or type(post)~='number'then
            report.observer_reason='Death-finished registration failed; native lifespan retained';return true
        end
        hook={pre=pre,post=post,callback=callback};report.finished_observer=true;report.observer_reason=nil
        return true
    end
    function self.capture(event,actor,c)
        if not context(c)or not matches(event,c)then return reject('capture_context_or_event_scope')end
        if entries[event.event_id]then return true end
        local inherited
        for _,e in pairs(entries)do
            if c.now-e.at>=15 and not e.hidden then remove(e);report.expired=report.expired+1
            elseif e.pawn_key==event.victim_pawn_key then
                -- A second life for one pawn supersedes any old finished marker.
                if e.life~=event.victim_life then
                    if e.hidden and not e.retired then inherited=e end
                    remove(e)
                else return reject('duplicate_pawn_life')end
            end
        end
        if count>=64 then
            local oldest
            for _,e in pairs(entries)do
                if e.metadata_only and(not oldest or e.at<oldest.at)then oldest=e end
            end
            if oldest then remove(oldest);report.restore_metadata_evicted=report.restore_metadata_evicted+1 end
        end
        if count>=64 then return reject('capture_capacity')end
        local owned,is_owned=safe(runtime.is_owned_zombie,actor)
        if not owned or is_owned~=false then return reject('owned_zombie_or_ownership_unavailable')end
        local e={id=event.event_id,pawn_key=event.victim_pawn_key,life=event.victim_life,
            world_id=c.world_id,generation=c.generation,actor=actor,at=c.now,attempts=0,next_attempt=0}
        -- A rapid revive/death between roster ticks must not replace our saved
        -- original flags with the hidden/collisionless values we wrote earlier.
        if inherited then
            e.original_hidden=inherited.original_hidden;e.original_collision=inherited.original_collision
            -- Preserve only our existing visibility edits so a later revive can
            -- restore them even when this second death never produces a zombie.
            -- No commit permission or completion marker crosses the life boundary.
            e.hidden=inherited.hidden;e.wrote_collision=inherited.wrote_collision
        end
        entries[e.id]=e;count=count+1
        local accepted,why=valid(e,c,false)
        if not accepted then remove(e);return reject(why)end
        report.captured=report.captured+1;return true
    end
    function self.committed(event,c)
        if not context(c)or not matches(event,c)then return reject('commit_context_or_event_scope')end
        local e=entries[event.event_id]
        if not e or e.life~=event.victim_life or e.pawn_key~=event.victim_pawn_key then return reject('commit_capture_or_life_missing')end
        if e.committed then return e.hidden==true end
        if not e.committed then e.committed=true;report.committed=report.committed+1 end
        local accepted,why,waiting=valid(e,c,true)
        if not accepted then
            if waiting then e.next_attempt=c.now+1;report.last_wait_reason=why;return false end
            remove(e);return reject(why)
        end
        return hide(e,c)
    end
    function self.tick(c)
        if not context(c)then reset();return end
        heartbeat=heartbeat+1
        local roster={};for _,p in ipairs(c.players or{})do if string_id(p.pawn_key)then roster[p.pawn_key]=p end end
        for _,e in pairs(entries)do
            if c.now-e.at>=15 and not e.metadata_only then
                report.expired=report.expired+1
                -- One expiry-only liveness check removes corpses already cleaned
                -- up by native lifespan; no repeating hidden-pawn polling.
                if e.hidden and not e.retired and live(e.actor)then e.actor=nil;e.metadata_only=true
                else remove(e)end
            end
            local p=roster[e.pawn_key]
            if entries[e.id]==e and e.hidden and not e.retired and p and p.alive==true and p.life~=e.life then
                restore(e,p,c)
            elseif entries[e.id]==e and e.committed and not e.retired and not e.metadata_only then
                local retry=not e.hidden and e.attempts<3 and c.now>=e.next_attempt
                -- Two adapter heartbeat increments exclude the completion hook's
                -- enclosing controller tick as well as the hook itself.
                local retire=e.hidden and e.finished_tick and heartbeat>e.finished_tick+1
                    and c.now>=(e.next_destroy_check or 0)
                if retry or retire then
                    local accepted,why,waiting=valid(e,c,true)
                    if not accepted then
                        if waiting then e.next_attempt=c.now+1;e.next_destroy_check=c.now+1;report.last_wait_reason=why
                        else remove(e);reject(why)end
                    elseif retry then hide(e,c)
                    elseif retire then
                        e.next_destroy_check=c.now+1
                        local checked,controller=call(e.actor,'GetController')
                        local address_read,address=call(controller,'GetAddress')
                        local detached=checked and(controller==nil or(address_read and address==0))
                        -- A roster still claiming this pawn also delays retirement.
                        for _,p in ipairs(c.players or{})do if p.pawn_key==e.pawn_key then detached=false;break end end
                        if detached then
                            -- Reserve before dispatch, including synchronous destroyed hooks.
                            e.retired=true
                            local destroyed=call(e.actor,'K2_DestroyActor')
                            e.actor=nil
                            if destroyed then report.destroy_requested=report.destroy_requested+1;report.last_destroy_requested=e.id
                            else issue('Finished detached dead pawn could not be destroyed')end
                        end
                    end
                end
            end
        end
    end
    function self.reset()reset()end
    function self.stop()
        started=false;hook_token=hook_token+1;reset();report.ready=false;report.finished_observer=false
        if hook then
            local ok,result=safe(api.UnregisterHook,FINISHED,hook.pre,hook.post)
            cleanup_failed=not ok or result==false
            if not cleanup_failed then hook=nil end
        end
        report.cleanup_failed=cleanup_failed;return not cleanup_failed
    end
    function self.snapshot()
        local result={};for k,v in pairs(report)do result[k]=v end
        result.pending=count;result.world_id=world_id;result.generation=generation
        result.retained_pawns=0;result.restore_metadata=0
        for _,e in pairs(entries)do
            if e.actor~=nil then result.retained_pawns=result.retained_pawns+1 end
            if e.metadata_only then result.restore_metadata=result.restore_metadata+1 end
        end
        result.live_verified=false;result.client_collision_replication=false;return result
    end
    return self
end
return M
