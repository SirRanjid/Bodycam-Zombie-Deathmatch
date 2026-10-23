-- Optional original zombie voices. These finite SoundCues use the shipped
-- unreliable multicast and its head-attached attenuation; no target timer,
-- StateTree, shared asset, looping cue, or gameplay readiness is changed.
local M={}
local ROOT='/Game/BodycamZombies/ZombieAI/'
local RPC=ROOT..'Zombie.Zombie_C:Multicast - SpawnScreamSound'
local CUES={
    -- Scream: 3.977521 / native Modulator PitchMin .95 < 4.25.
    -- Arrival: (8s longest wave + 2s delay) / cue pitch .8 <= 12.5.
    scream={path=ROOT..'Sounds/Scream/ScreamZombie.ScreamZombie',duration=4.25},
    acquire={path=ROOT..'Sounds/Scream/ZombieArriving.ZombieArriving',duration=12.5},
    sprint={path=ROOT..'Sounds/Scream/ZombieArrivingSprinter.ZombieArrivingSprinter',duration=10},
}
M.paths={rpc=RPC,cues=CUES}
local PRIORITY={idle=1,acquire=2,attack=3,sprint=4}
local function finite(v)return type(v)=='number'and v==v and v~=math.huge and v~=-math.huge end
local function point(v)return type(v)=='table'and finite(v.X)and finite(v.Y)and finite(v.Z)end
local function stagger(id,n)
    local hash=n or 0;for i=1,#id do hash=(hash*33+id:byte(i))%65521 end
    return 8+hash%7
end
function M.new(runtime,api,options)
    api,options=api or{},options or{}
    local self={};local token={};local epoch=0;local pending={};local pending_count=0
    local world_id;local last_now;local next_global=0;local assets={};local next_load={}
    local report={optional=true,ready=false,attempted=0,emitted=0,errors=0,dropped=0,
        idle=0,acquire=0,attack=0,sprint=0,resets=0,asset_loads=0}
    local function issue(reason)report.errors=report.errors+1;report.last_error=tostring(reason):sub(1,300);return false end
    local function safe(fn,...)
        if type(fn)~='function'then return false end
        return pcall(fn,...)
    end
    local function live(value)local ok,v=safe(runtime.live,value);return ok and v==true end
    local function find(path)local ok,v=safe(runtime.find,path);return ok and live(v)and v or nil end
    local function reset()
        pending={};pending_count=0;epoch=epoch+1;world_id=nil;last_now=nil;next_global=0;next_load={}
        report.resets=report.resets+1
    end
    local function context(c)
        if type(c)~='table'or c.enabled~=true or c.authority~=true or c.zdm_active==true
            or type(c.world_id)~='string'or not finite(c.now)or c.now<0 then return false end
        if world_id~=c.world_id or(last_now and c.now<last_now)then reset();world_id=c.world_id end
        last_now=c.now;return true
    end
    local function valid(row,c)
        if type(row)~='table'or type(row.id)~='string'or row.world_id~=c.world_id
            or row.cleanup_requested or row.cleanup_complete or row.bonus_retired then return false end
        local ok,value=safe(runtime.valid,row,c);return ok and value==true
    end
    local function state(row,c)
        -- These observations come after native_ai's existing validation and
        -- only change Lua metadata. Revalidate native ownership once at send.
        if not context(c)or type(row)~='table'or type(row.id)~='string'or row.world_id~=c.world_id
            or row.cleanup_requested or row.cleanup_complete or row.bonus_retired then return nil end
        local s=row.variant_vocals
        if type(s)~='table'or s.owner~=token or s.epoch~=epoch then
            s={owner=token,epoch=epoch,next_voice=0,next_idle=c.now+stagger(row.id),sequence=0}
            row.variant_vocals=s
        end
        return s
    end
    local function offer(row,c,s,kind)
        if c.now<s.next_voice then report.dropped=report.dropped+1;return end
        local old=pending[row.id]
        if old and PRIORITY[old.kind]>=PRIORITY[kind]then return end
        if not old and pending_count>=32 then report.dropped=report.dropped+1;return end
        if not old then pending_count=pending_count+1 end
        -- References last at most two seconds and are revalidated before use.
        -- Reset drops them without touching actors from an old world.
        pending[row.id]={row=row,state=s,kind=kind,at=c.now,world_id=c.world_id}
    end
    local function ambient(row,c,s)
        if c.now<s.next_idle then return end
        s.sequence=s.sequence+1;s.next_idle=c.now+stagger(row.id,s.sequence)
        offer(row,c,s,'idle')
    end
    local function asset(name,now,allow_load)
        local entry=CUES[name];local value=assets[name]
        if live(value)then return value end
        value=find(entry.path)
        if not value and allow_load and now>=(next_load[name]or 0)and type(api.LoadAsset)=='function'then
            next_load[name]=now+30;report.asset_loads=report.asset_loads+1
            local ok,loaded=safe(api.LoadAsset,entry.path);if ok and live(loaded)then value=loaded end
        end
        assets[name]=value;return value
    end
    function self.start()
        local available=0
        for name in pairs(CUES)do if asset(name,0,true)then available=available+1 end end
        report.ready=find(RPC)~=nil and available==3
        if not report.ready then report.last_error='Optional zombie voice assets or multicast unavailable' end
        return report.ready
    end
    function self.target(row,c,player,speed,intent)
        local s=state(row,c);if not s then return end
        local life=type(player)=='table'and type(player.life)=='string'and player.life or nil
        -- Native AI supplies explicit sprint intent for ordinary 450-speed
        -- bursts, including targetless patrols. Retain the existing hit-run edge.
        local running=finite(speed)and((intent=='sprint'and speed>=450)or(life~=nil and speed>=600))
        if running and not s.running then offer(row,c,s,'sprint')
        elseif life and life~=s.target_life then offer(row,c,s,'acquire')end
        s.running=running;s.target_life=life
        ambient(row,c,s)
    end
    function self.combat(row,c,active)
        local s=state(row,c);if not s then return end
        active=active==true
        if active and not s.attacking then offer(row,c,s,'attack')end
        s.attacking=active
    end
    local function near(row,c)
        local ok,pos=safe(runtime.position_of,row.actor);if not ok or not point(pos)then return false end
        -- Reuse the authoritative roster snapshot; never enumerate the world.
        for _,p in ipairs(c.players or{})do
            if p.combatant_kind=='human'and p.alive==true and p.connected~=false and point(p.position)then
                local q=p.position;local d=(pos.X-q.X)^2+(pos.Y-q.Y)^2+(pos.Z-q.Z)^2
                if d<=6400^2 then return true end
            end
        end
        return false
    end
    function self.tick(c)
        if not context(c)then reset();return end
        local selected
        for id,e in pairs(pending)do
            if e.world_id~=c.world_id or c.now-e.at>2 or e.state.epoch~=epoch
                or e.row.cleanup_requested or e.row.cleanup_complete or e.row.bonus_retired
                or c.now<e.state.next_voice then
                pending[id]=nil;pending_count=pending_count-1;report.dropped=report.dropped+1
            elseif not selected or PRIORITY[e.kind]>PRIORITY[selected.kind]
                or(PRIORITY[e.kind]==PRIORITY[selected.kind]and(e.at<selected.at
                    or(e.at==selected.at and id<selected.row.id)))then selected=e end
        end
        if not selected or c.now<next_global then return end
        local e=selected;pending[e.row.id]=nil;pending_count=pending_count-1
        if not valid(e.row,c)or not near(e.row,c)then report.dropped=report.dropped+1;return end
        local name=(e.kind=='acquire'or e.kind=='sprint')and e.kind or'scream'
        local cue=asset(name,c.now,true)
        if not cue or not find(RPC)then issue('Optional zombie voice asset or multicast unavailable');return end
        -- Reserve before dispatch: synchronous callbacks cannot enqueue this
        -- actor again. Cooldowns exceed the cooked cue's maximum duration.
        next_global=c.now+0.5;e.state.next_voice=c.now+CUES[name].duration+0.25
        e.state.next_idle=math.max(e.state.next_idle,e.state.next_voice)
        report.attempted=report.attempted+1
        local ok,sent=safe(runtime.native,RPC,e.row.actor,cue)
        if not ok or sent~=true then issue('Optional zombie voice multicast failed');return end
        report.ready=true;report.last_error=nil;report.emitted=report.emitted+1;report[e.kind]=report[e.kind]+1
        report.last_kind=e.kind;report.last_zombie=e.row.id;report.last_at=c.now
    end
    function self.forget(row)
        if type(row)~='table'then return end
        if pending[row.id]then pending[row.id]=nil;pending_count=pending_count-1 end
        row.variant_vocals=nil
    end
    function self.reset()reset()end
    function self.snapshot()
        local result={};for k,v in pairs(report)do result[k]=v end
        result.queued=pending_count;result.world_id=world_id;result.live_verified=false;return result
    end
    return self
end
return M
