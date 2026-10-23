-- Composition root for the independent native-mode extension.
local M={}
local ROUND_START='Game.Phase.StartRound'
local function get(o,k)if o~=nil then local ok,v=pcall(function()return o[k]end);if ok then return v end end end
local function call(o,k,...)local f=get(o,k);if f~=nil then return pcall(f,o,...)end;return false end
local function finite(v)return type(v)=='number'and v==v and v~=math.huge and v~=-math.huge end
local function text(v)
    if type(v)=='string'then return v end
    local ok,s=call(v,'ToString');return ok and type(s)=='string'and s or nil
end
function M.new(api,options)
    options=options or {};local modules=assert(options.modules,'Modules required')
    local bridge={};local runtime=modules.runtime.new(api,bridge,options.config)
    local ai=modules.ai.new(runtime,options.config);local time=modules.time.new(runtime)
    local vocals,vocal_load_error
    if type(modules.vocals)=='table'and type(modules.vocals.new)=='function'then
        local ok,value=pcall(modules.vocals.new,runtime,api,options.vocals)
        if ok and type(value)=='table'then vocals=value
        else vocal_load_error=tostring(value):sub(1,240)end
    end
    local native_ai_options={}
    for k,v in pairs(options.native_ai or {})do native_ai_options[k]=v end
    native_ai_options.vocals=vocals
    local native_ai=modules.native_ai.new(runtime,api,native_ai_options)
    local corpses,corpse_load_error
    if type(modules.corpses)=='table'and type(modules.corpses.new)=='function'then
        local ok,value=pcall(modules.corpses.new,runtime,api,options.corpses)
        if ok and type(value)=='table'then corpses=value
        else corpse_load_error=tostring(value):sub(1,240)end
    end
    local self={};local modes,events,damage,score,round_audio;local current;local stopped=false;local started=false
    local fault;local startup={};local hit_queue={};local hit_by_id={};local active_world;local active_generation
    local round={}
    local report={phase='STAGED',version='0.1.0-dev',owner='BodycamZombieVariants',live_verified=false}
    local last_ready,last_blocker=false,'Runtime has not been checked'
    local cached_score={ready=false};local cached_round_audio={ready=false}
    local phase_names={'modes','context','readiness','weather','score','ai','vocals','remaining'}
    local timing={clock='os.clock',tick_samples=0,tick_total_ms=0,tick_max_ms=0,last_tick_measured=false,phases={}}
    for _,name in ipairs(phase_names)do timing.phases[name]={samples=0,total_ms=0,max_ms=0}end
    local timing_ok,segment_started,segment_name
    local function clock()
        if type(os)~='table'or type(os.clock)~='function'then return nil end
        local ok,value=pcall(os.clock)
        if ok and type(value)=='number'and value==value and value>=0 and value<math.huge then return value end
    end
    local function begin_timing()
        segment_started=clock();timing_ok=segment_started~=nil;segment_name='readiness';timing.last_tick_measured=false
        for _,name in ipairs(phase_names)do timing.phases[name].last_ms=0 end
    end
    local function timing_phase(name)
        if timing_ok then
            local now=clock();local ms=now and(now-segment_started)*1000
            if not ms or ms<0 or ms==math.huge then timing_ok=false
            else local p=timing.phases[segment_name];p.last_ms=p.last_ms+ms;segment_started=now end
        end
        segment_name=name
    end
    local function finish_tick(ok,reason)
        timing_phase('remaining')
        if timing_ok then
            local total=0
            for _,name in ipairs(phase_names)do
                local p=timing.phases[name];p.samples=p.samples+1;p.total_ms=p.total_ms+p.last_ms;p.max_ms=math.max(p.max_ms,p.last_ms)
                total=total+p.last_ms
            end
            timing.tick_samples=timing.tick_samples+1;timing.tick_total_ms=timing.tick_total_ms+total
            timing.tick_last_ms=total;timing.tick_max_ms=math.max(timing.tick_max_ms,total);timing.last_tick_measured=true
        else
            timing.tick_last_ms=nil;for _,name in ipairs(phase_names)do timing.phases[name].last_ms=nil end
        end
        return ok,reason
    end
    local function score_snapshot()
        cached_score=score.snapshot();return cached_score
    end
    local function audio_snapshot()
        cached_round_audio=round_audio.snapshot();return cached_round_audio
    end
    local function ready_result(ok,reason)last_ready=ok;last_blocker=reason;return ok,reason end
    report.vocals_error=vocal_load_error
    report.corpses_error=corpse_load_error
    local function corpse_call(method,...)
        if not corpses then return nil end
        local ok,result=pcall(function(...)return corpses[method](...)end,...)
        if not ok then report.corpses_error=tostring(result):sub(1,240);return nil end
        return result
    end
    local function vocal_call(method,...)
        if not vocals then return nil end
        local ok,result=pcall(function(...)return vocals[method](...)end,...)
        if not ok then report.vocals_error=tostring(result):sub(1,240);return nil end
        return result
    end
    local function fail(reason)fault=tostring(reason or'Native bridge failed'):sub(1,240);report.reason=fault;ready_result(false,fault)end
    local function owned_count()return runtime.owned_count()end
    local function start_component(name,component,optional)
        local called,ok,reason=pcall(component.start)
        if called and ok==true then startup[name]=nil;return true end
        local message=tostring((called and reason)or(not called and ok)or'Component startup did not verify'):sub(1,500)
        startup[name]=message
        if not called and not optional then fail(name..' startup error: '..message)end
        return false,message
    end
    local function ready()
        if fault then return ready_result(false,fault)end
        local e=events and events.snapshot()or {}
        if e.death_observer~=true then return ready_result(false,e.startup_error or startup.events or'Native player death observer is unavailable')end
        local d=damage and damage.snapshot()or {}
        if not d.ready or not d.damage_pre_apply then return ready_result(false,d.startup_error or d.last_error or startup.damage or'Damage interception is unavailable')end
        -- Query the native capability on every guard entry. Reward statistics
        -- belong to the full tick/inspect snapshot, not each repeated guard.
        local checked,score_ready=false,false
        if score and type(score.ready)=='function'then checked,score_ready=pcall(score.ready)end
        if not checked or score_ready~=true then
            local s=score and score_snapshot()or {}
            return ready_result(false,options.native_load_error or s.startup_error or s.last_error or startup.score or s.reason or'Native zero-score dispatch guard is unavailable')
        end
        local ok,reason=native_ai.ready();if not ok then return ready_result(false,reason)end
        -- Cosmetic audio may be unloaded during travel. It must never revoke
        -- an explicitly selected mode or its damage/score/AI protection.
        return ready_result(true)
    end
    local function legacy_active(c)
        if type(options.legacy_active)~='function'then return false end
        local ok,active=pcall(options.legacy_active,c)
        return ok and active==true
    end
    local function selected(c)
        local s=modes and modes.selection()
        return s and(s.world_key or s.world)==c.world_id and s or nil
    end
    local function callback_context()
        if type(runtime.peek_context)=='function'then return runtime.peek_context()end
        return runtime.context()
    end
    local function audio_context(...)
        if stopped then return nil end
        local c;if select('#',...)>0 then c=... else c=callback_context()end
        if not c or not c.authority then return nil end
        local variant=selected(c);local legacy
        if type(options.legacy_audio_status)=='function'then
            local ok,value=pcall(options.legacy_audio_status,c)
            if ok and type(value)=='table'then legacy=value end
        end
        if legacy_active(c)and not legacy then return nil end
        if not variant and not legacy then return nil end
        local out={};for k,v in pairs(c)do out[k]=v end
        out.active=true;out.enabled=true;out.owner=report.owner
        out.audio_legacy_status=legacy
        out.audio_legacy=legacy~=nil and(legacy.phase~='FINISHED'or variant==nil)
        out.zdm_active=out.audio_legacy
        out.variant=out.audio_legacy and{name='Z-Deathmatch',legacy=true}or variant
        if legacy then
            out.audio_legacy_phase=legacy.phase;out.audio_legacy_clock=legacy.clock_seconds
            if type(legacy.started_at)=='number'and type(legacy.deadline)=='number'then
                out.audio_legacy_round=string.format('%.17g:%.17g',legacy.started_at,legacy.deadline)
            end
        end
        return out
    end
    local function round_allowed(c)
        if not c or c.authority~=true or not runtime.live(c.world)then return false,'Authoritative round world unavailable' end
        if round.world~=c.world_id or round.generation~=c.generation then
            round={world=c.world_id,generation=c.generation}
        end
        -- The native game state owns these reflected fields. Poll only this
        -- exact current-world object, never an actor inventory or audio state.
        local gs=get(c.world,'GameState');local phase,token
        if runtime.live(gs)and runtime.belongs(gs,c.world)then
            local ok,value=call(gs,'GetCurrentPhase')
            phase=ok and(text(get(value,'TagName'))or text(value))or nil
            local number,start=get(gs,'CurrentRound'),get(gs,'RoundStartTime')
            local id=runtime.key(gs)
            if type(id)=='string'and finite(number)and number>=0 and number%1==0 and finite(start)and start>=0 then
                token=id..':'..string.format('%.0f:%.17g',number,start)
            end
        end
        report.round_phase=phase;report.round_token=token
        local valid=type(phase)=='string'and token~=nil
        if valid and phase==ROUND_START and not round.closed and(not round.token or round.token==token)then
            round.token=token;report.round_active=true;report.round_reason=nil;return true
        end
        -- A changed StartRound token also closes the prior round if EndRound
        -- happened entirely between heartbeats. No new actor precedes cleanup.
        round.closed=true;round.pending=valid and phase==ROUND_START and token or nil
        round.observed_end=round.observed_end or(valid and phase~=ROUND_START)
        report.round_active=false
        report.round_reason=not valid and'Native round phase or identity unavailable'
            or(phase==ROUND_START and'Prior round cleanup required'or'Native round is not active: '..phase)
        return false,report.round_reason
    end
    local function event_context()
        if stopped or not current or not current.enabled or not ready()then return nil end
        local c=callback_context()
        if not c or not c.authority or c.world_id~=current.world_id or c.generation~=current.generation
            or not selected(c)or legacy_active(c)or not round_allowed(c)then return nil end
        return {active=true,owner=report.owner,world_key=c.world_id,generation=c.generation}
    end
    local function queue_hit(event,body)
        if type(event)~='table'or not current or not current.enabled or event.world_key~=current.world_id or event.generation~=current.generation
            or type(event.zombie_id)~='string'or #event.zombie_id==0 or #event.zombie_id>512 then return end
        local queued=hit_by_id[event.zombie_id]
        if not queued or queued.world_id~=event.world_key or queued.generation~=event.generation then
            if #hit_queue>=256 then return end
            queued={world_id=event.world_key,generation=event.generation,zombie_id=event.zombie_id}
            hit_queue[#hit_queue+1]=queued;hit_by_id[event.zombie_id]=queued
        end
        -- Body calculations emit interaction and shooter notifications. Keep
        -- one activity record, with the latest verified body shooter only.
        if body and type(event.shooter_life)=='string'and #event.shooter_life>0 and #event.shooter_life<=512 then
            queued.shooter_life=event.shooter_life
        end
    end
    damage=modules.damage.new(runtime,api,{
        get_context=function()
            if not current then return nil end
            local c=callback_context()
            if not c or not c.authority or c.world_id~=current.world_id or c.generation~=current.generation then return nil end
            -- Retain damage protection while owned actors await confirmed cleanup.
            if current.enabled or owned_count()>0 then c.enabled=current.enabled;c.active=current.enabled;return c end
        end,
        on_error=fail,
        on_body_hit=function(event)queue_hit(event,true)end,
        on_interaction=function(event)queue_hit(event,false)end,
    })
    score=modules.score.new(runtime,{native_call=options.native_call,on_error=fail})
    bridge.ready=function()
        local ok,reason=ready();if not ok then return false,reason end
        local c=callback_context()
        if not current or not current.enabled or not c or c.world_id~=current.world_id
            or c.generation~=current.generation or not selected(c)or legacy_active(c)then return false,'Active variant round unavailable' end
        return round_allowed(c)
    end
    bridge.prepare_zombie=function(actor,c,row)
        local ok,reason=damage.prepare_zombie(actor,c)
        if ok~=true then return false,'Damage preparation: '..tostring(reason or'rejected')end
        ok,reason=score.prepare_zombie(row,c)
        if ok~=true then return false,'Score preparation: '..tostring(reason or'rejected')end
        return true
    end
    bridge.bind_ai=function(row,c)
        local ok,reason=damage.verify_zombie(row.actor,c)
        if ok~=true then return false,'Damage verification: '..tostring(reason or'rejected')end
        ok,reason=score.bind_controller(row,c)
        if ok~=true then return false,'Score controller binding: '..tostring(reason or'rejected')end
        ok,reason=native_ai.bind_ai(row,c)
        if ok~=true then return false,'AI binding: '..tostring(reason or'rejected')end
        return true
    end
    bridge.unregister=function(row,c)
        if score.unregister(row,c)~=true then return false end
        if type(damage.forget_zombie)=='function'then damage.forget_zombie(row.id,c)end
        vocal_call('forget',row)
        return true
    end
    bridge.retire=function(row,c)
        return type(score.retire)=='function'and score.retire(row,c)==true
    end
    for _,name in ipairs({'target','roam','perceived','combat'})do bridge[name]=native_ai[name]end
    runtime.revenge_spawned=function(event,c)
        if stopped or not current or not current.enabled or not c.enabled or not c.authority or c.zdm_active
            or event.world_id~=current.world_id or event.generation~=current.generation
            or c.world_id~=current.world_id or c.generation~=current.generation or not round_allowed(c)then return end
        corpse_call('committed',event,c)
    end
    events=modules.events.new(api,{
        get_context=event_context,object_key=runtime.key,
        is_live=function(o,id)
            local c=callback_context();return c and c.world_id==id and c.authority and runtime.belongs(o,c.world)or false
        end,
        on_death_observed=function(event,actor)
            runtime.mark_dead(event.victim_life,event.world_key)
            if stopped or not current or not current.enabled or event.world_key~=current.world_id
                or event.generation~=current.generation then return end
            local c=callback_context()
            if not c or not c.authority or c.world_id~=current.world_id or c.generation~=current.generation
                or not selected(c)or legacy_active(c)or not round_allowed(c)then return end
            c.enabled=true;c.active=true;c.owner=report.owner;c.zdm_active=false
            corpse_call('capture',event,actor,c)
        end,
        on_player_death=function(event)
            if not current or not current.enabled or event.world_key~=current.world_id or event.generation~=current.generation
                or not round_allowed(callback_context())then return end
            return ai.on_death({world_id=event.world_key,victim_life=event.victim_life,event_id=event.event_id,
                victim_pawn_key=event.victim_pawn_key,victim_key=event.victim_key,generation=event.generation,
                killer_life=event.killer_life,position=event.position,now=current.now})
        end,
    })
    local audio_settings=options.round_audio or {}
    round_audio=modules.round_audio.new(runtime,api,{get_context=audio_context,
        sound_path=audio_settings.sound_path,sound_confirmed=audio_settings.sound_confirmed,
        on_error=function(reason)
            report.audio_error=tostring(reason):sub(1,500)
            if options.log then pcall(options.log,'Round audio: '..report.audio_error)end
        end,log=options.log})
    modes=modules.modes.new(api,{ready=ready,log=options.log,world_key=runtime.key,is_live=runtime.live})
    local function deactivate()
        if owned_count()>0 then return false end
        if type(score.deactivate)=='function'and score.deactivate()~=true then return false end
        active_world=nil;active_generation=nil;return true
    end
    local function clean(c)
        hit_queue={};hit_by_id={}
        vocal_call('reset')
        corpse_call('reset')
        if c then c.enabled=false;c.active=false;ai.tick(c);runtime.retry_cleanup(c)end
        local cleaned=runtime.cleanup_owned(c)
        if not cleaned and c and active_world==c.world_id then score.refresh(c)end
        if cleaned then return deactivate()end
        return false
    end
    local function clean_round(c)
        -- Keep native score protection and exact player-corpse restoration
        -- alive in the intermission; only the zombie population is retired.
        c.enabled=false;c.active=false
        hit_queue={};hit_by_id={};events.sync_players({})
        if not round.reset then
            ai.end_round(c);vocal_call('reset');round.reset=true
            report.round_boundaries=(report.round_boundaries or 0)+1
        end
        ai.tick(c)
        local cleaned=runtime.cleanup_owned(c)
        if cleaned then cleaned=deactivate()end
        report.round_cleanup_pending=not cleaned
        local corpse_context={};for k,v in pairs(c)do corpse_context[k]=v end
        corpse_context.enabled=true;corpse_context.active=true
        corpse_call('tick',corpse_context)
        report.phase=cleaned and'WAITING_ROUND'or'CLEANUP_REQUIRED'
        report.reason=report.round_reason
        if cleaned and round.pending and(round.pending~=round.token or not round.observed_end)then
            round.token=round.pending;round.pending=nil;round.closed=false;round.reset=nil
            round.observed_end=nil
            report.phase='ROUND_STARTING';report.reason='Prior round cleanup complete'
        end
        return finish_tick(false,report.reason)
    end
    function self.start()
        if stopped then return false,'Restart required after shutdown' end
        if started then return true end
        started=true
        start_component('damage',damage);start_component('score',score);start_component('events',events)
        start_component('round_audio',round_audio,true);modes.start()
        vocal_call('start')
        corpse_call('start')
        return self.tick()
    end
    function self.tick()
        if stopped then return false,'Stopped' end
        begin_timing()
        if not fault then
            if damage.snapshot().ready~=true then start_component('damage',damage)end
            if score_snapshot().ready~=true then start_component('score',score)end
            if events.snapshot().death_observer~=true then start_component('events',events)end
        end
        timing_phase('remaining')
        if audio_snapshot().ready~=true then start_component('round_audio',round_audio,true)end
        timing_phase('modes')
        modes.tick()
        timing_phase('context')
        local c,why=runtime.context()
        timing_phase('readiness')
        local available,reason=ready()
        timing_phase('remaining')
        local audio_ok,audio_error=pcall(round_audio.tick,audio_context(c))
        report.audio_error=not audio_ok and tostring(audio_error):sub(1,500)or nil
        if not c then vocal_call('reset');corpse_call('reset');current=nil;report.phase='WAITING';report.reason=why;return finish_tick(false,why)end
        c.zdm_active=legacy_active(c);local variant=selected(c)
        c.enabled=available and c.authority and variant~=nil and not c.zdm_active
        c.owner=report.owner;c.active=c.enabled;c.variant=variant
        current=c
        if not c.enabled then
            local cleaned=clean(c);events.sync_players({});time.release(c)
            report.phase=not cleaned and'CLEANUP_REQUIRED'or(c.zdm_active and'LEGACY_ACTIVE'or(available and'IDLE'or'BLOCKED'))
            report.reason=c.zdm_active and'Existing Z-Deathmatch has gameplay ownership'or reason
            return finish_tick(false,report.reason)
        end
        -- Map actors may arrive after mode selection. Hold the selected time
        -- before creating gameplay actors, and retry transient sky readiness.
        timing_phase('weather')
        local held,time_reason=time.tick(c)
        timing_phase('remaining')
        report.time_ready=held==true;report.time_reason=time_reason
        if held~=true then
            local cleaned=clean(c);events.sync_players({})
            report.phase=cleaned and'WAITING_TIME'or'CLEANUP_REQUIRED';report.reason=time_reason
            return finish_tick(false,time_reason)
        end
        timing_phase('score')
        if not round_allowed(c)then
            if active_world==c.world_id and active_generation==c.generation
                and score.refresh(c)~=true then fail('Native score guard heartbeat failed during round cleanup')end
            timing_phase('remaining');return clean_round(c)
        end
        if active_world~=c.world_id or active_generation~=c.generation then
            if not round.initialized then
                vocal_call('reset');corpse_call('reset');round.initialized=true
            end
            local activated,score_reason=score.activate(c)
            if activated~=true then fail(score_reason or'Native score guard could not activate for this world');clean(c);report.phase='BLOCKED';return finish_tick(false,fault)end
            active_world=c.world_id;active_generation=c.generation
        end
        if score.refresh(c)~=true then fail('Native score guard heartbeat failed');clean(c);report.phase='CLEANUP_REQUIRED';return finish_tick(false,fault)end
        timing_phase('remaining')
        report.round_cleanup_pending=false
        runtime.retry_cleanup(c)
        events.sync_players(c.players)
        local queued=hit_queue;hit_queue={};hit_by_id={}
        -- Refresh interaction before the population's inactivity/despawn check.
        for _,event in ipairs(queued)do
            if event.world_id==c.world_id and event.generation==c.generation then ai.interaction(event.zombie_id,event.world_id,c.now)end
        end
        timing_phase('ai')
        local progressed,ai_reason=ai.tick(c)
        timing_phase('remaining')
        if progressed~=true then fail(ai_reason);clean(c);report.phase='BLOCKED';return finish_tick(false,fault)end
        if not round_allowed(c)then return clean_round(c)end
        events.drain()
        corpse_call('tick',c)
        for _,event in ipairs(queued)do
            if event.world_id==c.world_id and event.generation==c.generation then
                if event.shooter_life then ai.on_body_hit(event)end
            end
        end
        timing_phase('vocals')
        vocal_call('tick',c)
        timing_phase('remaining')
        report.phase='ACTIVE';report.reason=nil;report.variant=variant.name
        return finish_tick(true)
    end
    function self.stop()
        if stopped and report.phase=='STOPPED'then return true end
        stopped=true
        ready_result(false,'Controller stopped; cleanup may still be pending')
        local c=runtime.context();current=c;if c then c.enabled=false end
        local cleaned=clean(c);local restored=time.release(c)
        corpse_call('stop')
        local unhooked=events.stop();local audio_stopped=round_audio.stop();local menu=modes.shutdown()
        local damage_clean,score_clean=false,false
        if cleaned then damage_clean=damage.stop();score_clean=score.stop()end
        if cleaned and restored and unhooked and audio_stopped and menu and damage_clean and score_clean then
            current=nil;report.phase='STOPPED';report.reason=nil;return true
        end
        report.phase='CLEANUP_REQUIRED';report.reason='Owned actors or native hooks still require cleanup';return false
    end
    function self.phase()return report.phase,report.reason end
    function self.status(full)
        local out={};for k,v in pairs(report)do out[k]=v end
        out.events=events.snapshot();out.ai=ai.status();out.time=time.snapshot();out.modes=modes.status()
        out.damage=damage.snapshot();out.native_ai=native_ai.snapshot();out.owned=owned_count()
        out.vocals=vocal_call('snapshot')or{available=false}
        out.corpses=corpse_call('snapshot')or{available=false}
        -- Automatic reporting uses observations already made by gameplay. Only
        -- an explicit inspect repeats native readbacks and readiness checks.
        if full==true then
            score_snapshot();audio_snapshot()
            if type(runtime.diagnostics)=='function'then out.runtime=runtime.diagnostics(current)end
            ready()
        end
        out.score={};for k,v in pairs(cached_score)do out.score[k]=v end
        out.round_audio={};for k,v in pairs(cached_round_audio)do out.round_audio[k]=v end
        out.diagnostics_scope=full==true and'FULL_NATIVE_READBACK'or'GAMEPLAY_SNAPSHOTS'
        out.controller_performance={}
        for k,v in pairs(timing)do if k~='phases'then out.controller_performance[k]=v end end
        out.controller_performance.phases={}
        for name,p in pairs(timing.phases)do local copy={};for k,v in pairs(p)do copy[k]=v end;out.controller_performance.phases[name]=copy end
        out.startup_errors={};for name,reason in pairs(startup)do out.startup_errors[name]=reason end
        out.ready,out.blocker=last_ready,last_blocker;return out
    end
    return self
end
return M
