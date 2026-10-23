-- Additional native-mode zombie population. All UObject work belongs to the
-- injected, authority-checked adapter; player/life identities here are strings.
local M={}
M.defaults={
    max_total=14,environment_cap=6,revenge_cap=6,camper_cap=2,environment_target=6,
    corpse_lifetime=25,corpse_cap=8,
    spawn_per_tick=1,spawn_interval=5,death_spawn_interval=1,death_priority_burst=4,
    ambient_kill_window=30,ambient_min_interval=1,ambient_wave_period=45,ambient_wave_max_interval=10,
    ambient_floor=2,ambient_floor_interval=3,
    death_queue_timeout=10,death_queue_max=32,death_history_max=4096,
    detect_distance=1800,interaction_distance=3000,despawn_distance=12000,inactivity=90,
    roam_radius=1200,roam_interval=8,walk_speed=90,chase_speed=140,base_run_speed=450,run_speed=630,
    sprint_duration=4,sprint_cooldown_min=20,sprint_cooldown_max=40,
    camper_window=20,camper_radius=200,camper_rearm_distance=600,camper_cooldown=90,camper_per_player=2,
    environment_min_distance=2000,environment_max_distance=8000,
    camper_min_distance=600,camper_max_distance=1200,revenge_max_distance=300,spacing=400,
}
local function finite(v)return type(v)=='number'and v==v and v~=math.huge and v~=-math.huge end
local function key(v)return type(v)=='string'and #v>0 and #v<=512 end
local function vec(v)
    if type(v)=='table'and finite(v.X)and finite(v.Y)and finite(v.Z)then return {X=v.X,Y=v.Y,Z=v.Z}end
end
local function distance(a,b)local x,y,z=a.X-b.X,a.Y-b.Y,a.Z-b.Z;return math.sqrt(x*x+y*y+z*z)end
local function copy(t)local o={};for k,v in pairs(t)do o[k]=v end;return o end
local function diagnostic_vector(v)
    if type(v)~='table'then return nil end
    local x,y,z=rawget(v,'X'),rawget(v,'Y'),rawget(v,'Z')
    if finite(x)and finite(y)and finite(z)then return {X=x,Y=y,Z=z}end
end
local function diagnostic_string(v)return type(v)=='string'and v:sub(1,512)or nil end
function M.new(adapter,options)
    assert(type(adapter)=='table','A native adapter is required')
    for _,name in ipairs({'spawn','valid','position','target','roam','perceived','combat','destroy'})do
        assert(type(adapter[name])=='function','Missing native adapter method: '..name)
    end
    local cfg=copy(M.defaults)
    for k,v in pairs(options or {})do assert(cfg[k]~=nil,'Unknown AI setting: '..tostring(k));assert(finite(v)and v>=0,'Invalid AI setting: '..k);cfg[k]=v end
    for _,k in ipairs({'max_total','environment_cap','revenge_cap','camper_cap','environment_target','spawn_per_tick','death_queue_max','camper_per_player','corpse_cap','death_priority_burst','ambient_floor'})do
        assert(cfg[k]%1==0 and cfg[k]<=256,'Invalid bounded count: '..k)
    end
    assert(cfg.death_history_max%1==0 and cfg.death_history_max>=1 and cfg.death_history_max<=65536,'Invalid death history bound')
    assert(cfg.max_total>0 and cfg.spawn_per_tick>0 and cfg.spawn_interval>0,'Population and spawn rate must be positive')
    assert(cfg.death_spawn_interval>0 and cfg.death_priority_burst>0,'Death spawn rate and priority burst must be positive')
    assert(cfg.ambient_min_interval>=1 and cfg.ambient_min_interval<=cfg.spawn_interval,'Invalid ambient minimum interval')
    assert(cfg.ambient_kill_window>=cfg.ambient_min_interval and math.ceil(cfg.ambient_kill_window/cfg.ambient_min_interval)<=256,'Invalid ambient kill window')
    assert(cfg.ambient_wave_period>=30 and cfg.ambient_wave_period<=60,'Ambient wave period must be 30 to 60 seconds')
    assert(cfg.ambient_wave_max_interval>=cfg.spawn_interval and cfg.ambient_wave_max_interval<=60,'Invalid ambient wave maximum interval')
    assert(cfg.ambient_floor_interval>=cfg.ambient_min_interval and cfg.ambient_floor_interval<=cfg.ambient_wave_max_interval,'Invalid ambient floor interval')
    assert(cfg.camper_window>0 and cfg.inactivity>0 and cfg.roam_interval>0 and cfg.corpse_lifetime>0,'Intervals must be positive')
    assert(cfg.base_run_speed>math.max(cfg.walk_speed,cfg.chase_speed)and cfg.run_speed>=cfg.base_run_speed and cfg.run_speed<=1000,'Invalid running speeds')
    assert(cfg.sprint_duration>=1 and cfg.sprint_duration<=10 and cfg.sprint_cooldown_min>=cfg.sprint_duration
        and cfg.sprint_cooldown_max>=cfg.sprint_cooldown_min and cfg.sprint_cooldown_max<=300,'Invalid sprint timing')
    assert(cfg.camper_per_player<=2,'Camper pairs are limited to two zombies per player')
    assert(cfg.camper_rearm_distance>cfg.camper_radius,'Camper rearm movement must exceed the stationary radius')
    assert(cfg.environment_max_distance>=cfg.environment_min_distance and cfg.camper_max_distance>=cfg.camper_min_distance,'Spawn distance ranges are reversed')
    local self={};local rows={};local by_id={};local deaths={};local seen_deaths={};local campers={}
    local world_id,last_now,enabled,next_spawn,roster=nil,nil,false,0,{}
    local next_death_spawn,death_streak,sprint_cursor=0,0,0
    local kill_times={};local kill_history_limit=math.ceil(cfg.ambient_kill_window/cfg.ambient_min_interval)
    local last_ambient_attempt,last_environment_attempt,next_camper_spawn=nil,nil,0
    local wave_start,wave_phase,wave_multiplier=nil,0,1
    local ambient_base_interval,ambient_interval=cfg.spawn_interval,cfg.spawn_interval
    local environment_cursor,death_history_count=0,0;local retirements={};local last_death_spawn
    local report={spawned=0,despawned=0,spawn_failed=0,dropped_deaths=0,duplicate_deaths=0,adapter_errors=0,world_resets=0,
        world_spawned=0,world_despawned=0,world_spawn_failed=0,player_count=0,living_count=0}
    local function invoke(method,...)
        local ok,a,b=pcall(adapter[method],...)
        if not ok then report.adapter_errors=report.adapter_errors+1;report.last_error=method..': '..tostring(a):sub(1,360);return nil,report.last_error end
        return a,b
    end
    local function reset_refill()
        kill_times={};last_ambient_attempt=nil;last_environment_attempt=nil;next_camper_spawn=0;next_spawn=0
        wave_start=nil;wave_phase=0;wave_multiplier=1;ambient_base_interval=cfg.spawn_interval;ambient_interval=cfg.spawn_interval
    end
    local function refresh_refill(now,environment_count)
        if not wave_start then wave_start=now end
        while kill_times[1]and now-kill_times[1]>=cfg.ambient_kill_window do table.remove(kill_times,1)end
        local measured_interval=#kill_times>0 and cfg.ambient_kill_window/#kill_times or cfg.spawn_interval
        ambient_base_interval=math.max(cfg.ambient_min_interval,math.min(cfg.spawn_interval,measured_interval))
        wave_phase=((now-wave_start)%cfg.ambient_wave_period)/cfg.ambient_wave_period
        local q=(1-math.cos(2*math.pi*wave_phase))/2
        wave_multiplier=0.5+q*q
        ambient_interval=math.max(cfg.ambient_min_interval,math.min(cfg.ambient_wave_max_interval,ambient_base_interval/wave_multiplier))
        local floor=math.min(cfg.ambient_floor,cfg.environment_target,cfg.environment_cap,cfg.max_total)
        if environment_count<floor then ambient_interval=math.min(ambient_interval,cfg.ambient_floor_interval)end
        -- Recompute from the last actual attempt, never from a missed deadline.
        -- Faster kills can bring it forward; a quieter phase can move it back.
        next_spawn=last_environment_attempt and last_environment_attempt+ambient_interval or 0
    end
    local function clear()
        rows={};by_id={};deaths={};seen_deaths={};campers={};roster={};next_spawn=0;enabled=false;environment_cursor=0;death_history_count=0
        next_death_spawn=0;death_streak=0;sprint_cursor=0
        reset_refill()
        retirements={};last_death_spawn=nil;report.world_spawned=0;report.world_despawned=0;report.world_spawn_failed=0
        report.player_count=0;report.living_count=0
    end
    local function counts()
        -- total/type caps reserve living actors and unconfirmed live cleanup.
        -- Corpses keep ownership separately until native cleanup is confirmed.
        local c={total=0,owned=#rows,corpses=0,cleanup_pending=0,environment=0,revenge=0,camper=0}
        for _,r in ipairs(rows)do
            if r.corpse_at then c.corpses=c.corpses+1 else c.total=c.total+1;c[r.kind]=c[r.kind]+1 end
            if r.cleanup_pending then c.cleanup_pending=c.cleanup_pending+1 end
        end
        return c
    end
    local function owner_count(owner)
        local n=0;for _,r in ipairs(rows)do if not r.corpse_at and r.kind=='camper'and r.owner_key==owner then n=n+1 end end;return n
    end
    local function death_outcome(event,outcome,now,reason)
        last_death_spawn={event_id=event.event_id,victim_life=event.victim_life,victim_pawn_key=event.victim_pawn_key,killer_life=event.killer_life,
            position=vec(event.position),expires=event.expires,attempts=event.attempts or 0,
            outcome=outcome,at=now,world_id=world_id,reason=diagnostic_string(reason)}
    end
    local function remove(i)
        local r=rows[i];by_id[r.id]=nil;table.remove(rows,i)
    end
    local function retire(i,context,reason,detail)
        local r=rows[i]
        if not r.retirement_event then
            r.retirement_reason=reason or'invalid'
            r.retirement_detail=diagnostic_string(detail)
            local event={id=r.id,kind=r.kind,world_id=world_id,reason=r.retirement_reason,requested_at=context.now,
                detail=r.retirement_detail,corpse_at=r.corpse_at,corpse_until=r.corpse_until,
                state=r.state,target_life=r.target_life,position=diagnostic_vector(r.position)or diagnostic_vector(rawget(r.handle,'spawn_position')),
                position_at=r.position_at,nearest_living_distance=r.nearest_living_distance,
                nearest_living_z_delta=r.nearest_living_z_delta,cleanup_pending=true,attempts=0}
            retirements[#retirements+1]=event;if #retirements>8 then table.remove(retirements,1)end
            r.retirement_event=event
        end
        r.retirement_event.attempts=r.retirement_event.attempts+1
        r.cleanup_pending=true;r.target_life=nil
        if invoke('destroy',r.handle,context)==true then
            r.retirement_event.cleanup_pending=false;r.retirement_event.completed_at=context.now
            remove(i);report.despawned=report.despawned+1;report.world_despawned=report.world_despawned+1;return true
        end
        return false
    end
    local function mark_corpse(row,context)
        -- Only a previously live, owned row with the native death flag reaches
        -- this transition. Cleanup, spawn rejection and player deaths do not.
        -- Keep just the newest timestamps needed to saturate the minimum rate.
        if #kill_times>=kill_history_limit then table.remove(kill_times,1)end
        kill_times[#kill_times+1]=context.now
        row.corpse_at=context.now;row.corpse_until=context.now+cfg.corpse_lifetime
        row.state='corpse';row.target_life=nil;row.speed=0;row.position_readable=false
        row.run_reason=nil;row.sprint_until=nil;row.next_sprint=nil
        row.sprint_restore_speed=nil;row.sprint_restore_state=nil
        row.nearest_living_distance=nil;row.nearest_living_z_delta=nil;row.nearest_living_life=nil
        -- Optional runtime optimization: it must verify this observed terminal
        -- death itself and still check actor liveness on subsequent valid calls.
        if type(adapter.mark_corpse)=='function'then invoke('mark_corpse',row.handle,context)end
    end
    local function trim_corpses(context)
        while counts().corpses>cfg.corpse_cap do
            local oldest
            for i,r in ipairs(rows)do
                if r.corpse_at and (not oldest or r.corpse_at<rows[oldest].corpse_at)then oldest=i end
            end
            -- A failed oldest cleanup stays reserved. Do not erase additional
            -- fresh bodies to hide that failure; the owned hard cap stops growth.
            if not oldest or rows[oldest].cleanup_pending then break end
            if not retire(oldest,context,'corpse_capacity')then break end
        end
    end
    local function living(context)
        local players,by_life,count={},{},0
        for i,p in ipairs(context.players or {})do
            if i>128 then break end
            count=count+1
            if key(p.key)and key(p.life)and p.alive==true and p.connected~=false then
                local point=vec(p.position)
                if point and not by_life[p.life]then players[#players+1]=p;by_life[p.life]=p end
            end
        end
        return players,by_life,count
    end
    local function sprint_pause(row)
        -- Primitive, deterministic staggering avoids a global RNG/native call
        -- and keeps repeated pauses different without a catch-up schedule.
        local fraction=((row.sprint_seed*17+row.sprint_cycle*11)%21)/20
        return cfg.sprint_cooldown_min+(cfg.sprint_cooldown_max-cfg.sprint_cooldown_min)*fraction
    end
    local function spawn(request,context,budget,initial_target)
        local c=counts()
        if budget.left<1 or c.total>=cfg.max_total or c.owned>=cfg.max_total+cfg.corpse_cap or c[request.kind]>=cfg[request.kind..'_cap']then return false,'capacity' end
        budget.left=budget.left-1
        request.zero_score=true;request.spacing=cfg.spacing;request.world_id=world_id
        local handle,reason=invoke('spawn',request,context)
        if type(handle)~='table'or not key(handle.id)then
            report.spawn_failed=report.spawn_failed+1;report.world_spawn_failed=report.world_spawn_failed+1;report.last_spawn_kind=request.kind
            report.last_spawn_error=tostring(reason or'Spawn adapter returned no owned zombie'):sub(1,500)
            report.last_spawn_error_at=context.now;return false,handle==nil and'spawn'or'identity'
        end
        if by_id[handle.id]then
            -- A duplicate ID cannot establish ownership of another actor.
            report.spawn_failed=report.spawn_failed+1;report.world_spawn_failed=report.world_spawn_failed+1;report.last_error='Duplicate owned zombie identity';return false,'identity'
        end
        local row={id=handle.id,handle=handle,kind=request.kind,owner_key=request.owner_key,
            target_life=request.target_life,speed=request.speed,last_interaction=context.now,
            next_roam=context.now,state=request.target_life and 'chase'or'roam'}
        rows[#rows+1]=row;by_id[row.id]=row
        local valid,validity_detail=invoke('valid',handle,context)
        if valid~=true then
            row.cleanup_pending=true;report.spawn_failed=report.spawn_failed+1;report.world_spawn_failed=report.world_spawn_failed+1
            -- Keep a failed cleanup in the population count until it is confirmed.
            retire(#rows,context,'spawn_invalid',validity_detail);return false,'validity'
        end
        if initial_target then
            -- A revenge spawn is committed only after the exact current killer
            -- and both native movement speeds are verified in this same tick.
            if invoke('target',handle,initial_target,row.speed,context,'sprint')~=true then
                report.spawn_failed=report.spawn_failed+1;report.world_spawn_failed=report.world_spawn_failed+1
                report.last_spawn_kind=request.kind;report.last_spawn_error='Native initial revenge target assignment did not verify'
                report.last_spawn_error_at=context.now
                retire(#rows,context,'target_failed');return false,'target'
            end
            row.state='run';row.run_reason='revenge'
        end
        sprint_cursor=(sprint_cursor%256)+1;row.sprint_seed=sprint_cursor;row.sprint_cycle=0
        row.next_sprint=context.now+sprint_pause(row)
        report.spawned=report.spawned+1;report.world_spawned=report.world_spawned+1
        return true,row.id
    end
    local function chase(row,player,context)
        if invoke('target',row.handle,player,row.speed,context,row.state=='run'and'sprint'or nil)==true then return true end
        report.last_error='Native target assignment did not verify';return false
    end
    local function roam(row,context)
        row.target_life=nil
        if row.run_reason~='autonomous'then row.state='roam';row.speed=cfg.walk_speed;row.run_reason=nil end
        if invoke('target',row.handle,nil,row.speed,context,row.state=='run'and'sprint'or nil)~=true then
            report.last_error='Native target clear did not verify';return false
        end
        if context.now>=row.next_roam then
            invoke('roam',row.handle,{radius=cfg.roam_radius,speed=row.speed},context)
            row.next_roam=context.now+cfg.roam_interval
        end
        return true
    end
    local function end_sprint(row,lost_target)
        row.sprint_until=nil;row.run_reason=nil
        row.speed=lost_target and cfg.walk_speed or row.sprint_restore_speed
        row.state=lost_target and'roam'or row.sprint_restore_state
        row.sprint_restore_speed=nil;row.sprint_restore_state=nil
    end
    local function begin_sprint(row,context)
        row.sprint_restore_speed=row.speed;row.sprint_restore_state=row.state
        row.sprint_until=context.now+cfg.sprint_duration;row.run_reason='autonomous'
        row.speed=cfg.base_run_speed;row.state='run';row.sprint_cycle=(row.sprint_cycle+1)%21
        row.next_sprint=row.sprint_until+sprint_pause(row)
        -- A roamer may be standing at its last route endpoint. Request one
        -- ordinary safe patrol route, with no invented player target.
        if not row.target_life then row.next_roam=context.now end
    end
    function self.on_death(event)
        if type(event)~='table'or not enabled or event.world_id~=world_id or not key(event.victim_life)or not vec(event.position)then return false end
        local event_id=event.event_id
        if event_id~=nil and not key(event_id)then return false end
        event_id=event_id or event.victim_life
        if seen_deaths[event_id]then report.duplicate_deaths=report.duplicate_deaths+1;return false end
        if death_history_count>=cfg.death_history_max then
            report.dropped_deaths=report.dropped_deaths+1;report.last_error='Map death history limit reached';return false
        end
        seen_deaths[event_id]=true;death_history_count=death_history_count+1
        -- Retain only bounded primitive records, never an event's UObjects.
        if #deaths>=cfg.death_queue_max then report.dropped_deaths=report.dropped_deaths+1;return false end
        local killer=key(event.killer_life)and event.killer_life~=event.victim_life and event.killer_life or nil
        local pending={event_id=event_id,victim_life=event.victim_life,position=vec(event.position),killer_life=killer,
            victim_pawn_key=key(event.victim_pawn_key)and event.victim_pawn_key or nil,
            victim_key=key(event.victim_key)and event.victim_key or nil,
            generation=finite(event.generation)and event.generation or nil,
            expires=(last_now or 0)+cfg.death_queue_timeout,attempts=0}
        deaths[#deaths+1]=pending;death_outcome(pending,'queued',last_now)
        return true
    end
    function self.on_body_hit(event)
        if type(event)~='table'or not enabled or event.world_id~=world_id or not key(event.shooter_life)then return false end
        local row=by_id[event.zombie_id]
        if not row or row.corpse_at or row.cleanup_pending or not roster[event.shooter_life]then return false end
        row.target_life=event.shooter_life;row.speed=cfg.run_speed;row.state='run';row.last_interaction=last_now
        row.run_reason='body_hit';row.sprint_until=nil;row.sprint_restore_speed=nil;row.sprint_restore_state=nil
        return true
    end
    function self.interaction(zombie_id,event_world,now)
        local r=by_id[zombie_id]
        if enabled and event_world==world_id and r and not r.corpse_at and not r.cleanup_pending then
            -- Queued native hits are flushed before tick updates last_now. Use
            -- the current context time so a delayed tick cannot expire a new hit.
            r.last_interaction=finite(now)and now>=(last_now or 0)and now or last_now
            return true
        end
        return false
    end
    function self.tick(context)
        if type(context)~='table'or not key(context.world_id)or not finite(context.now)or context.now<0 then return false,'Invalid world context' end
        if world_id~=context.world_id then
            -- Do not invoke native functions on actors from the previous world.
            clear();world_id=context.world_id;last_now=nil;report.world_resets=report.world_resets+1
        end
        if last_now and context.now<last_now then return false,'Map clock moved backwards' end
        last_now=context.now;report.current_now=context.now
        enabled=context.enabled==true and context.authority==true and context.zdm_active~=true
        local players,players_by_life,player_count=living(context)
        report.player_count=player_count;report.living_count=#players
        if not enabled then
            deaths={};campers={};roster={}
            reset_refill()
            for i=#rows,1,-1 do
                if context.authority==true then retire(i,context,'disabled')end
            end
            return true
        end
        roster={}
        for life in pairs(players_by_life)do roster[life]=true end
        local sprint_started=false
        for i=#rows,1,-1 do
            local r=rows[i]
            local valid,validity_detail
            if not r.cleanup_pending then valid,validity_detail=invoke('valid',r.handle,context)end
            if r.cleanup_pending then retire(i,context)
            elseif r.corpse_at then
                if valid~=true and validity_detail~='zombie_dead'then retire(i,context,'invalid',validity_detail)
                elseif context.now>=r.corpse_until then retire(i,context,'corpse_expired')end
            elseif valid~=true then
                if validity_detail=='zombie_dead'then mark_corpse(r,context)
                else retire(i,context,'invalid',validity_detail)end
            else
                local point=vec(invoke('position',r.handle,context))
                r.position_readable=point~=nil;r.nearest_living_distance=nil;r.nearest_living_z_delta=nil;r.nearest_living_life=nil
                if point then
                    r.position=point;r.position_at=context.now
                    local nearest=math.huge
                    for _,p in ipairs(players)do
                        local d=distance(point,p.position)
                        if d<nearest then
                            nearest=d;r.nearest_living_distance=d;r.nearest_living_z_delta=point.Z-p.position.Z;r.nearest_living_life=p.life
                        end
                    end
                    local combat=invoke('combat',r.handle,context)==true
                    if combat or nearest<=cfg.interaction_distance then r.last_interaction=context.now end
                    if not combat and nearest>cfg.despawn_distance and context.now-r.last_interaction>=cfg.inactivity then retire(i,context,'inactive_distance')
                    else
                        local target=r.target_life and players_by_life[r.target_life]or nil
                        local lost_target=r.target_life~=nil and not target
                        if lost_target then end_sprint(r,true)
                        elseif r.sprint_until and context.now>=r.sprint_until then end_sprint(r,false)end
                        if not sprint_started and not lost_target and not combat and not r.run_reason
                            and context.now>=r.next_sprint and r.speed<cfg.base_run_speed then
                            begin_sprint(r,context);sprint_started=true
                        end
                        local target_path_ready=true
                        if not target then
                            target_path_ready=roam(r,context)
                            for _,p in ipairs(players)do
                                if target_path_ready and distance(point,p.position)<=cfg.detect_distance and invoke('perceived',r.handle,p,context)==true then
                                    r.target_life=p.life;r.last_interaction=context.now;target=p
                                    if r.run_reason=='autonomous'then r.sprint_restore_speed=cfg.chase_speed;r.sprint_restore_state='chase'
                                    else r.speed=cfg.chase_speed;r.state='chase'end
                                    break
                                end
                            end
                        end
                        if not target_path_ready then retire(i,context,'target_clear')
                        elseif target and not chase(r,target,context)then retire(i,context,'target_failed')end
                    end
                end
            end
        end
        trim_corpses(context)
        refresh_refill(context.now,counts().environment)
        local shared={left=cfg.spawn_per_tick}
        local ambient_ready=not last_ambient_attempt or context.now-last_ambient_attempt>=cfg.ambient_min_interval
        local environment_due=ambient_ready and context.now>=next_spawn
        local camper_due=ambient_ready and context.now>=next_camper_spawn
        local ambient_due=environment_due or camper_due
        -- Deaths normally run first on their own clock. Even with slow ticks,
        -- give overdue ambient work one turn after a bounded death streak.
        local ambient_first=ambient_due and death_streak>=cfg.death_priority_burst
        local function process_deaths(allow_spawn)
          local index=1
          while index<=#deaths do
            local event=deaths[index]
            if context.now>event.expires then
                death_outcome(event,'expired',context.now,event.last_failure)
                table.remove(deaths,index);report.dropped_deaths=report.dropped_deaths+1
            elseif allow_spawn and shared.left>0 and context.now>=next_death_spawn then
                local target=players_by_life[event.killer_life]
                local before_attempt=shared.left
                local ok,why=spawn({kind='revenge',origin=vec(event.position),position=vec(event.position),try_exact=true,
                    min_distance=0,max_distance=cfg.revenge_max_distance,target_life=target and target.life,
                    speed=target and cfg.base_run_speed or cfg.walk_speed},context,shared,target)
                if shared.left<before_attempt then
                    event.attempts=event.attempts+1;next_death_spawn=context.now+cfg.death_spawn_interval
                    death_streak=math.min(cfg.death_priority_burst,death_streak+1)
                end
                if ok then
                    death_outcome(event,'spawned',context.now);table.remove(deaths,index)
                    -- Despawn only this death's body after every spawn/validity
                    -- check succeeded. Cosmetic cleanup cannot undo that success.
                    if type(adapter.revenge_spawned)=='function'then
                        local notification={event_id=event.event_id,victim_life=event.victim_life,
                            victim_pawn_key=event.victim_pawn_key,victim_key=event.victim_key,
                            generation=event.generation,world_id=world_id,zombie_id=why}
                        local notified,err=pcall(adapter.revenge_spawned,notification,context)
                        if not notified then
                            report.corpse_callback_errors=(report.corpse_callback_errors or 0)+1
                            report.corpse_callback_error=tostring(err):sub(1,240)
                        end
                    end
                elseif why=='spawn'then
                    -- A collision-safe death point can become free before the
                    -- existing deadline. Retrying consumes the shared budget;
                    -- neither the deadline nor the exact origin is moved.
                    event.last_failure=report.last_spawn_error
                    death_outcome(event,'retrying',context.now,event.last_failure);index=index+1
                elseif why=='capacity'then death_outcome(event,'waiting_capacity',context.now);index=index+1
                else
                    death_outcome(event,'failed',context.now,why);table.remove(deaths,index)
                    report.dropped_deaths=report.dropped_deaths+1
                end
            else index=index+1 end
          end
        end
        process_deaths(not ambient_first)
        local budget={left=ambient_due and shared.left or 0}
        local before=budget.left
        local alive_keys={}
        for _,p in ipairs(players)do
            alive_keys[p.key]=true
            local c=campers[p.key]
            if not c or c.life~=p.life then c={life=p.life,anchor=vec(p.position),since=context.now};campers[p.key]=c end
            if c.latched then
                if distance(p.position,c.trigger_anchor)>=cfg.camper_rearm_distance and context.now>=c.cooldown_until then
                    c.latched=nil;c.anchor=vec(p.position);c.since=context.now
                end
            elseif distance(p.position,c.anchor)>cfg.camper_radius then c.anchor=vec(p.position);c.since=context.now
            elseif context.now-c.since>=cfg.camper_window then
                local remaining=math.max(0,cfg.camper_per_player-owner_count(p.key))
                if remaining==0 then c.latched=true;c.trigger_anchor=vec(p.position);c.cooldown_until=context.now+cfg.camper_cooldown
                elseif budget.left>0 and camper_due then
                    local made=0
                    for _=1,remaining do
                        local ok=spawn({kind='camper',origin=vec(p.position),min_distance=cfg.camper_min_distance,
                            max_distance=cfg.camper_max_distance,target_life=p.life,owner_key=p.key,speed=cfg.walk_speed},context,budget)
                        if ok then made=made+1 end
                    end
                    if made>0 then c.latched=true;c.trigger_anchor=vec(p.position);c.cooldown_until=context.now+cfg.camper_cooldown end
                end
            end
        end
        for k in pairs(campers)do if not alive_keys[k]then campers[k]=nil end end
        if budget.left<before then next_camper_spawn=context.now+cfg.spawn_interval end
        local environment_before=budget.left
        local c=counts()
        for i=1,math.min(environment_due and budget.left or 0,math.max(0,cfg.environment_target-c.environment))do
            if #players==0 then break end
            local p=players[(environment_cursor%#players)+1];environment_cursor=environment_cursor+1
            spawn({kind='environment',origin=vec(p.position),min_distance=cfg.environment_min_distance,
                max_distance=cfg.environment_max_distance,speed=cfg.walk_speed},context,budget)
        end
        if budget.left<environment_before then last_environment_attempt=context.now;next_spawn=context.now+ambient_interval end
        local ambient_used=before-budget.left;shared.left=shared.left-ambient_used
        if ambient_used>0 then last_ambient_attempt=context.now;death_streak=0 end
        -- A reserved ambient turn that cannot use capacity never wastes a
        -- possible death-point attempt. No source can exceed the shared budget.
        if ambient_first then process_deaths(true)end
        return true
    end
    function self.shutdown(context)
        enabled=false;deaths={};campers={};roster={}
        reset_refill()
        if type(context)=='table'and context.world_id==world_id and context.authority==true then
            for i=#rows,1,-1 do retire(i,context,'disabled')end
        end
        return #rows==0
    end
    function self.end_round(context)
        if type(context)~='table'or context.authority~=true
            or(world_id~=nil and context.world_id~=world_id)then return false end
        -- Primitive-only boundary reset. The controller's disabled tick then
        -- retires every owned row, preserving failed cleanup for later retries.
        enabled=false;deaths={};campers={};roster={};seen_deaths={};death_history_count=0
        next_death_spawn=0;death_streak=0;sprint_cursor=0;last_death_spawn=nil
        reset_refill();return true
    end
    function self.status()
        local out=copy(report);out.counts=counts();out.world_id=world_id;out.enabled=enabled;out.queued_deaths=#deaths;out.death_history_count=death_history_count;out.config=copy(cfg);out.zombies={}
        out.next_ambient_spawn=next_spawn;out.next_death_spawn=next_death_spawn;out.death_priority_streak=death_streak
        out.ambient_recent_deaths=#kill_times;out.ambient_history_limit=kill_history_limit;out.ambient_base_interval=ambient_base_interval
        out.ambient_interval=ambient_interval;out.ambient_wave_phase=wave_phase;out.ambient_wave_multiplier=wave_multiplier
        out.ambient_wave_started_at=wave_start;out.next_camper_spawn=next_camper_spawn
        for _,r in ipairs(rows)do out.zombies[#out.zombies+1]={id=r.id,kind=r.kind,state=r.state,target_life=r.target_life,
            owner_key=r.owner_key,speed=r.speed,cleanup_pending=r.cleanup_pending==true,last_interaction=r.last_interaction,
            corpse_at=r.corpse_at,corpse_until=r.corpse_until,
            run_reason=r.run_reason,sprint_until=r.sprint_until,next_sprint=r.next_sprint,
            position=diagnostic_vector(r.position),position_at=r.position_at,position_readable=r.position_readable,
            nearest_living_distance=r.nearest_living_distance,nearest_living_z_delta=r.nearest_living_z_delta,nearest_living_life=r.nearest_living_life,
            spawn_position=diagnostic_vector(rawget(r.handle,'spawn_position')),spawn_origin=diagnostic_vector(rawget(r.handle,'spawn_origin')),
            spawn_stage=diagnostic_string(rawget(r.handle,'spawn_stage')),spawn_start_tag=diagnostic_string(rawget(r.handle,'spawn_start_tag')),
            retirement_reason=r.retirement_reason,retirement_detail=r.retirement_detail}end
        out.recent_retirements={}
        for _,event in ipairs(retirements)do
            local item=copy(event);item.position=diagnostic_vector(event.position);out.recent_retirements[#out.recent_retirements+1]=item
        end
        if last_death_spawn then out.last_death_spawn=copy(last_death_spawn);out.last_death_spawn.position=diagnostic_vector(last_death_spawn.position)end
        return out
    end
    return self
end
return M
