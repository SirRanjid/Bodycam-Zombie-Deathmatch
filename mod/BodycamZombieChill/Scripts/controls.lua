-- Host controls and a local, non-interactive scoreboard. All work is game-thread only.
local M={}
local function get(o,k)local ok,v=pcall(function()return o[k]end);if ok then return v end end
local function call(o,k,...)
    if o==nil then return false,'nil receiver' end
    local args=table.pack(...)
    local read,f=pcall(function()return o[k]end)
    if read and f~=nil then return pcall(f,o,table.unpack(args,1,args.n)) end
    local ok,mt=pcall(getmetatable,o);f=ok and type(mt)=='table' and rawget(mt,k)
    if type(f)=='function' then return pcall(f,o,table.unpack(args,1,args.n)) end
    return false,'method unavailable'
end
local function valid(o)local ok,v=call(o,'IsValid');return ok and v==true end
local function name(o)local ok,v=call(o,'GetFullName');return ok and type(v)=='string' and v or nil end
local function text(v)
    if type(v)=='string' then return v end
    local ok,s=call(v,'ToString');if ok and type(s)=='string' then return s end
end
local function unwrap(v)local ok,x=call(v,'get');return ok and x or v end
local function clean(v,max)
    v=type(v)=='string' and v or '?'
    v=v:gsub('[%z\1-\31\127|]',' ')
    if not utf8.len(v) then return '?' end
    local ok,cut=pcall(utf8.offset,v,(max or 48)+1)
    if not ok then return '?' end
    return cut and v:sub(1,cut-1) or v
end
local function integer(v,lo,hi)
    return type(v)=='number' and v==v and v>=lo and v<=hi and v%1==0 and v or nil
end
local PHASES={IDLE=true,PREMATCH=true,RUNNING=true,SMOKE_TEST=true,FINISHED=true,STOPPED=true,BLOCKED=true,READY_FOR_ONE_ZOMBIE=true,MAP_REQUESTED=true}
local function rows(s)
    local out={}
    for _,r in pairs(s.scoreboard or {}) do
        if type(r)=='table' and #out<6 then
            local player_name=clean(r.name);if player_name=='' then player_name='?' end
            out[#out+1]={name=player_name,points=integer(r.points,-100000,100000) or 0,
                kills=integer(r.kills,0,100000) or 0,deaths=integer(r.deaths,0,100000) or 0,
                eliminated=r.eliminated==true,connected=r.connected~=false}
        end
    end
    table.sort(out,function(a,b)if a.points~=b.points then return a.points>b.points end;return a.name<b.name end)
    return out
end
local function result_title(s)
    local result=type(s.final_result)=='table' and s.final_result or {}
    if type(result.message)=='string' then return clean(result.message,160) end
    if type(result.summary)=='string' then return clean(result.summary,160) end
    if result.no_winner then return 'Kein Sieger: Alle Teilnehmer sind ausgeschieden.' end
    if type(result.winners)=='table' then
        local names={}
        for _,r in pairs(result.winners) do
            if #names<6 then names[#names+1]=clean(type(r)=='table' and r.name or r) end
        end
        table.sort(names)
        if #names>0 then return clean((result.tie and 'Gleichstand: ' or 'Sieger: ')..table.concat(names,', '),160) end
    end
    return clean(type(s.result_text)=='string' and s.result_text or '',160)
end
function M.packet(s,sequence,session_id)
    local phase=PHASES[s.phase] and s.phase or 'IDLE'
    local remain=integer(math.ceil(tonumber(s.remaining_seconds) or 300),0,300) or 300
    local alive=integer(s.active,0,42) or 0
    session_id=type(session_id)=='string' and session_id:gsub('[^%w%-]',''):sub(1,40) or 'default'
    if session_id=='' then session_id='default' end
    sequence=integer(sequence,0,1000000000) or 0
    local lines={table.concat({'ZDM1',session_id,tostring(sequence),phase,tostring(remain),tostring(alive),'42',result_title(s)},'|')}
    for _,r in ipairs(rows(s)) do
        lines[#lines+1]=table.concat({'P',r.name,tostring(r.points),tostring(r.kills),tostring(r.deaths),r.eliminated and '1' or '0',r.connected and '1' or '0'},'|')
    end
    return table.concat(lines,'\n')
end
function M.parse_packet(message)
    if type(message)~='string' or #message>3072 or message:find('\r',1,true) or message:find('\n\n',1,true)
        or message:sub(-1)=='\n' then return nil end
    local lines={};for line in message:gmatch('[^\n]+')do lines[#lines+1]=line;if #lines>7 then return nil end end
    local head=lines[1] and {lines[1]:match('^(ZDM1)|([%w%-]+)|(%d+)|([A-Z_]+)|(%d+)|(%d+)|(42)|(.*)$')}
    if not head or #head~=8 or #head[2]>40 or not PHASES[head[4]] then return nil end
    if head[8]~=clean(head[8],160) then return nil end
    local seq,remaining,active=tonumber(head[3]),tonumber(head[5]),tonumber(head[6])
    if not integer(seq,0,1000000000) or not integer(remaining,0,300) or not integer(active,0,42) then return nil end
    local s={phase=head[4],remaining_seconds=remaining,elapsed_seconds=300-remaining,active=active,max_active=42,
        sequence=seq,remote_session_id=head[2],scoreboard={},result_text=clean(head[8],160),remote=true}
    for i=2,#lines do
        local n,p,k,d,e,c=lines[i]:match('^P|([^|]+)|(%-?%d+)|(%d+)|(%d+)|([01])|([01])$')
        p,k,d=tonumber(p),tonumber(k),tonumber(d)
        if not n or n~=clean(n) or not integer(p,-100000,100000) or not integer(k,0,100000) or not integer(d,0,100000) then return nil end
        s.scoreboard['p'..i]={name=n,points=p,kills=k,deaths=d,eliminated=e=='1',connected=c=='1'}
    end
    return s
end
function M.accept_packet(current,incoming,retired)
    if type(incoming)~='table' then return false end
    if not current then return true end
    if incoming.remote_session_id==current.remote_session_id then return incoming.sequence>current.sequence end
    for _,id in ipairs(retired or {})do if id==incoming.remote_session_id then return false end end
    if retired then
        retired[#retired+1]=current.remote_session_id
        if #retired>8 then table.remove(retired,1) end
    end
    return true
end
function M.format_status(s,notice)
    local remaining=math.max(0,math.min(300,math.ceil(tonumber(s.remaining_seconds) or 300)))
    local phase=s.phase or 'IDLE'
    local line=phase=='RUNNING' and string.format('%02d:%02d  |  Zombies %d/42',remaining//60,remaining%60,s.active or 0)
        or phase=='FINISHED' and 'RUNDENENDE' or phase=='SMOKE_TEST' and 'Einzeltest' or 'Bereit'
    local lines={'Z-DEATHMATCH  ·  '..line,'Zombie +1   |   Spieler-Kill -5','Tod: 5 positive Punkte abziehen, Minuspunkte bleiben.','Bei -15: Zuschauer bis Rundenende'}
    local list=rows(s)
    if #list>0 then
        lines[#lines+1]=''
        for _,r in ipairs(list) do
            lines[#lines+1]=string.format('%s   %d P  |  %d K  |  %d T%s',r.name,r.points,r.kills,r.deaths,r.eliminated and '  [Zuschauer]' or '')
        end
    end
    local result=result_title(s)
    if result~='' then lines[#lines+1]='';lines[#lines+1]=result end
    lines[#lines+1]=''
    if s.remote then lines[#lines+1]='Die Runde wird vom Host gesteuert.'
    else lines[#lines+1]=phase=='RUNNING' and 'F10 · Runde beenden' or 'F10 · Runde starten (privater Host)' end
    if notice and notice~='' then lines[#lines+1]=clean(notice,140) end
    return table.concat(lines,'\n'),#lines
end
function M.new(core,api,options)
    api,options=api or {},options or {}
    local self={};local generation=0;local input_timer,ui_timer;local accepting=false
    local hook_ids;local callback_refs={};local adapters={};local keys;local was_down=false;local widget,label,background_slot,label_slot
    local widget_world,widget_controller;local local_state;local last_value;local notice='';local remote_state;local remote_received=0
    local last_rpc=0;local sequence=0;local last_sent={};local retry_after=0;local retired_sessions={}
    local weather_round,weather_requested,weather_attempts,weather_next,weather_finished=nil,nil,0,0,false
    local restore_attempts,restore_next=0,0
    local auto={armed=false,retries=0};local native_world;local before_travel;local travel_pending=false;local travel_source
    local session_id=tostring(os.time())..'-'..tostring(math.floor(os.clock()*1000))
    local info={ready=false,key='F10',hud=false,hud_enabled=options.show_hud==true,receive_rpc=false,game_thread_only=true,guest_mod_required=false}
    local construct=api.StaticConstructObject or StaticConstructObject
    local make_text=api.FText or FText;local make_name=api.FName or FName
    local register=api.RegisterHook or RegisterHook;local unregister=api.UnregisterHook or UnregisterHook
    local after_frames=api.LoopInGameThreadAfterFrames or LoopInGameThreadAfterFrames
    local loop=api.LoopInGameThreadWithDelay or LoopInGameThreadWithDelay
    local cancel=api.CancelDelayedAction or CancelDelayedAction
    local function log(s)if options.log then pcall(options.log,'[Z-Deathmatch] '..s) end end
    local function find(path)local ok,o=pcall(api.StaticFindObject,path);return ok and valid(o) and o or nil end
    local function now()return os.time() end
    local function load_adapter(filename)
        if type(options.directory)~='string' then return nil,'Own adapter directory unavailable' end
        local read,module=pcall(dofile,options.directory..filename..'.lua')
        if not read or type(module)~='table' or type(module.new)~='function' then return nil,filename..' adapter unavailable' end
        local made,adapter
        if filename=='weather' then made,adapter=pcall(module.new,api,{log=options.log})
        elseif filename=='host_card' then
            local facade=setmetatable({play=function()return core.prepare()end},{__index=core})
            made,adapter=pcall(module.new,facade,api,{log=options.log})
        elseif filename=='map_rotation' then
            made,adapter=pcall(module.new,core,api,{log=options.log,
                before_travel=function(...)return before_travel(...)end})
        else made,adapter=pcall(module.new,core,api,{log=options.log}) end
        if not made or type(adapter)~='table' then return nil,filename..' initialization failed' end
        return adapter
    end
    local function local_controller()
        if type(core.get_controller)=='function' then local ok,c=pcall(core.get_controller);if ok and valid(c) then return c end end
        local gs=find('/Script/Engine.Default__GameplayStatics')
        local ok,vps=pcall(api.FindAllOf,'GameViewportClient')
        if ok and type(vps)=='table' then
            for _,vp in ipairs(vps) do
                local w=get(vp,'World')
                if valid(w) then local got,c=call(gs,'GetPlayerController',w,0);if got and valid(c) then return c end end
            end
        end
    end
    local function world_of(c)
        local ok,vps=pcall(api.FindAllOf,'GameViewportClient')
        if ok and type(vps)=='table' then for _,vp in ipairs(vps) do local w=get(vp,'World');if valid(w) then return w end end end
    end
    local function update_auto_round(s,w)
        local wn=name(w)
        if auto.world and auto.world~=wn then auto={armed=false,retries=0} end
        if s.phase=='PREMATCH' or s.phase=='RUNNING' then
            if auto.round~=s.started_at or auto.world~=wn then
                auto={armed=true,world=wn,round=s.started_at,retries=0}
            end
        elseif s.phase=='FINISHED' and auto.armed and auto.world==wn then
            -- The map-rotation adapter owns travel and the next prematch.
            info.waiting_for_map_change=true
        elseif s.phase=='STOPPED' or s.phase=='BLOCKED' then auto.armed=false;info.next_round_in=nil end
        info.autostart_armed=auto.armed;info.prematch_seconds=30
    end
    local function update_native_round(s,w)
        local adapter=adapters.native_round;if not adapter then return true end
        if s.phase=='RUNNING' or s.phase=='PREMATCH' then
            if native_world~=name(w) then
                local ok,ready,why=pcall(adapter.start,w)
                if not ok or ready~=true then
                    info.native_round_error=tostring(why or ready):sub(1,180);auto.armed=false;info.autostart_armed=false
                    pcall(core.stop,'Native Z-Deathmatch preparation failed: '..tostring(why or ready):sub(1,140));return false
                end
                native_world=name(w);info.native_round_error=nil
            end
            -- The native round may start only after the real 30-second prematch.
            local ok,ready,why=pcall(adapter.tick,s,w)
            if not ok or ready~=true then
                info.native_round_error=tostring(why or ready):sub(1,180);auto.armed=false;info.autostart_armed=false
                pcall(core.stop,'Native Z-Deathmatch state was lost: '..tostring(why or ready):sub(1,140));return false
            end
        elseif s.phase=='FINISHED' and native_world then
            local ok,ready=pcall(adapter.finish)
            if not ok or ready~=true then info.native_round_error='Punktelimit konnte nicht ausgeschaltet bleiben' end
        elseif native_world then
            local ok,ready=pcall(adapter.restore)
            if ok and ready~=false then native_world=nil else info.native_round_error='Ursprüngliches Punktelimit konnte nicht wiederhergestellt werden' end
        end
        return true
    end
    local function update_weather(s,w)
        local adapter=adapters.weather;if not adapter then return end
        if s.phase=='RUNNING' or s.phase=='PREMATCH' then
            restore_attempts=0;restore_next=0
            local round=(name(w) or '')..'|'..tostring(s.prematch_started_at or s.started_at)
            if weather_requested~=round then weather_requested=round;weather_attempts=0;weather_next=0 end
            if weather_round~=round then
                if now()<weather_next or weather_attempts>=30 then return end
                weather_next=now()+1;weather_attempts=weather_attempts+1
                local ok,ready,why=pcall(adapter.start,w)
                if ok and ready==true then weather_round=round;weather_finished=false;info.weather_error=nil
                else info.weather_error=tostring(why or ready):sub(1,180);return end
            end
            local ok,ready,why=pcall(adapter.tick,s.elapsed_seconds or 0)
            if not ok or ready~=true then info.weather_error=tostring(why or ready):sub(1,180) end
        elseif s.phase=='FINISHED' and weather_round and not weather_finished then
            local ok,ready=pcall(adapter.finish);weather_finished=ok and ready==true
            if not weather_finished then info.weather_error='Morgengrauen konnte nicht gesetzt werden' end
        elseif s.phase~='FINISHED' then
            local report=type(adapter.status)=='function' and adapter.status() or {}
            if weather_round or report.restore_pending then
                if now()<restore_next or restore_attempts>=5 then return end
                restore_attempts=restore_attempts+1;restore_next=now()+1
                local ok,ready=pcall(adapter.restore)
                if not ok or ready==false then info.weather_error='Wetter konnte nicht wiederhergestellt werden';return end
            end
            weather_round=nil;weather_requested=nil;weather_attempts=0;weather_next=0;weather_finished=false
            restore_attempts=0;restore_next=0
        end
    end
    local function hide()
        if valid(widget) then call(widget,'RemoveFromParent') end
        widget,label,background_slot,label_slot,widget_world,widget_controller,last_value=nil,nil,nil,nil,nil,nil,nil
        info.hud=false
    end
    before_travel=function(s,w)
        if s.phase~='FINISHED' or s.cleanup_pending~=0 or s.cleanup_failed~=0 or s.active~=0 then
            return false,'Owned round cleanup is incomplete'
        end
        local function invoke(key,method)
            local adapter=adapters[key];if not adapter then return true end
            if type(adapter[method])~='function' then return false,key..'.'..method..' unavailable' end
            local ok,ready,why=pcall(adapter[method])
            if not ok or ready~=true then return false,key..'.'..method..': '..tostring(why or ready):sub(1,140) end
            return true
        end
        -- Run while the old world is still healthy. A failure refuses travel
        -- and retains the failed adapter's original restoration state.
        if weather_round then local ok,why=invoke('weather','finish');if not ok then info.travel_error=why;return false,why end end
        for _,step in ipairs({{'weather','restore'},{'team_play','restore'},{'native_round','restore'},
            {'group_spawn','shutdown'},{'zombie_behavior','shutdown'}})do
            local ok,why=invoke(step[1],step[2]);if not ok then info.travel_error=why;return false,why end
            if step[1]=='weather' and step[2]=='restore' then
                weather_round=nil;weather_requested=nil;weather_finished=false;weather_attempts=0;weather_next=0;restore_attempts=0;restore_next=0
            elseif step[1]=='native_round' then native_world=nil
            elseif step[2]=='shutdown' then adapters[step[1]]=nil end
        end
        if type(core.release_for_travel)~='function' then return false,'Core travel reference release is unavailable' end
        local released,ready,reason=pcall(core.release_for_travel)
        if not released or ready~=true then
            info.travel_error=tostring(reason or ready):sub(1,180);return false,info.travel_error
        end
        hide()
        local ok,why=invoke('host_card','suspend');if not ok then info.travel_error=why;return false,why end
        travel_source=name(w);travel_pending=true;info.travel_pending=true;info.travel_error=nil
        return true
    end
    local function update_travel(s)
        -- The viewport is read afresh; no old controller, roster or adapter is
        -- inspected after the asynchronous travel request.
        local w=world_of(nil);local rotation=adapters.map_rotation
        if not rotation or type(rotation.tick)~='function' then info.travel_error='Map rotation adapter unavailable';return end
        local ok,ready,why=pcall(rotation.tick,s,w)
        if not ok or ready==false then info.travel_error=tostring(why or ready):sub(1,180);return end
        local read,r=pcall(rotation.status);if not read or type(r)~='table' then return end
        info.map_rotation=r
        if not r.cancelled and (r.pendingWorld or not r.arrived_world
            or type(r.arrived_world_id)~='number' or r.arrived_world_id<=0
            or type(r.arrived_game_state_id)~='number' or r.arrived_game_state_id<=0
            or type(r.source_world_id)~='number' or type(r.source_game_state_id)~='number'
            or r.arrived_world_id==r.source_world_id and r.arrived_game_state_id==r.source_game_state_id) then return end
        local fresh=core.public_status()
        if not r.cancelled and fresh.phase~='PREMATCH' and fresh.phase~='RUNNING' then return end
        local host=adapters.host_card
        if host and type(host.resume)=='function' then
            local resumed,result=pcall(host.resume,true)
            if not resumed or result~=true then info.travel_error='Host menu could not resume';return end
        end
        for _,key in ipairs({'group_spawn','zombie_behavior'})do
            if not adapters[key] then
                local adapter,err=load_adapter(key)
                if not adapter then info.travel_error=err;return end
                local started,done=pcall(adapter.start)
                if not started or done~=true then info.travel_error=key..' could not resume';return end
                adapters[key]=adapter
            end
        end
        travel_pending=false;travel_source=nil;info.travel_pending=false;info.travel_error=nil
        info.map_vote_cancelled=r.cancelled==true
        auto={armed=false,retries=0};last_sent={};local_state=nil;remote_state=nil
    end
    local function make_widget(pc,world)
        if type(construct)~='function' or make_text==nil then return false,'UMG construction APIs unavailable' end
        local widgets=find('/Script/UMG.Default__WidgetBlueprintLibrary')
        local kind=find('/Game/UI/Components/Misc/W_CurrencyPrice.W_CurrencyPrice_C')
        if not kind and type(api.LoadAsset)=='function' then
            pcall(api.LoadAsset,'/Game/UI/Components/Misc/W_CurrencyPrice.W_CurrencyPrice_C')
            kind=find('/Game/UI/Components/Misc/W_CurrencyPrice.W_CurrencyPrice_C')
        end
        local made,w=call(widgets,'Create',pc,kind,pc)
        if not made or not valid(w) then return false,'Scoreboard widget unavailable' end
        local tree=get(w,'WidgetTree');if not valid(tree) then return false,'WidgetTree unavailable' end
        local function create(class)local cls=find('/Script/UMG.'..class);local ok,o=pcall(construct,cls,tree);return ok and valid(o) and o or nil end
        local canvas,border,block=create('CanvasPanel'),create('Border'),create('TextBlock')
        if not canvas or not border or not block then return false,'Scoreboard elements unavailable' end
        local assigned=pcall(function()tree.RootWidget=canvas;w.bIsFocusable=false end)
        local b,bs=call(canvas,'AddChildToCanvas',border);local t,ts=call(canvas,'AddChildToCanvas',block)
        if not assigned or not b or not t or not valid(bs) or not valid(ts) then return false,'Scoreboard layout unavailable' end
        local font=get(block,'Font');local sized=pcall(function()font.Size=18 end)
        local ready=sized and call(block,'SetFont',font) and call(border,'SetBrushColor',{R=0.015,G=0.02,B=0.03,A=0.82})
            and call(block,'SetColorAndOpacity',{SpecifiedColor={R=0.92,G=0.96,B=1,A=1},ColorUseRule=0})
            and call(block,'SetShadowOffset',{X=1,Y=1}) and call(block,'SetShadowColorAndOpacity',{R=0,G=0,B=0,A=1})
            and call(block,'SetAutoWrapText',false) and call(ts,'SetOffsets',{Left=18,Top=14,Right=640,Bottom=360})
            and call(bs,'SetOffsets',{Left=0,Top=0,Right=670,Bottom=340})
            and call(w,'SetPositionInViewport',{X=28,Y=110},false) and call(w,'SetDesiredSizeInViewport',{X=670,Y=340})
        for _,o in ipairs({w,canvas,border,block}) do ready=call(o,'SetVisibility',3) and ready end
        local added,shown=false,false
        if ready then added,shown=call(w,'AddToPlayerScreen',200) end
        if not ready or not added or shown~=true then call(w,'RemoveFromParent');return false,'Scoreboard display failed' end
        widget,label,background_slot,label_slot,widget_world,widget_controller=w,block,bs,ts,name(world),name(pc);info.hud=true
        return true
    end
    local function publish(s,pc)
        if options.enable_modded_guest_overlay~=true then return end
        if type(core.get_players)~='function' or s.phase~='RUNNING' and s.phase~='FINISHED' then return end
        local instant=now();if instant-last_rpc<1 then return end;last_rpc=instant;sequence=sequence+1
        local ok,players=pcall(core.get_players);if not ok or type(players)~='table' then return end
        local built,typ=pcall(make_name,'ZDeathmatch');if not built then return end
        local payload=M.packet(s,sequence,session_id)
        for _,p in ipairs(players) do
            local other=p.controller
            if valid(other) then
                local local_ok,is_local=call(other,'IsLocalController')
                if local_ok and is_local==false then
                    local id=name(other)
                    if id and (last_sent[id]~=payload) then
                        local sent=call(other,'ClientMessage',payload,typ,2.5)
                        if sent then last_sent[id]=payload end
                    end
                end
            end
        end
    end
    local function update()
        if not accepting then return end
        if travel_pending then update_travel(core.public_status());return end
        local pc=local_controller();local w=valid(pc) and world_of(pc)
        if not valid(pc) or not valid(w) then hide();return end
        local _,local_pc=call(pc,'IsLocalController');if local_pc~=true then hide();return end
        local _,authority=call(pc,'HasAuthority')
        local s=core.public_status()
        for key,adapter in pairs(adapters)do
            if type(adapter.status)=='function' then local ok,value=pcall(adapter.status);if ok then info[key]=value end end
        end
        s.controls=info
        if authority~=true then
            if not remote_state or now()-remote_received>12 then hide();return end
            s=remote_state
        else
            update_auto_round(s,w)
            if update_native_round(s,w)==false then hide();return end
            for _,key in ipairs({'team_play','group_spawn','zombie_behavior'}) do
                local adapter=adapters[key]
                if adapter and type(adapter.tick)=='function' then
                    local ok,ready,why=pcall(adapter.tick,s,w)
                    if not ok or ready==false then info[key..'_error']=tostring(why or ready):sub(1,180) else info[key..'_error']=nil end
                end
            end
            local rotation=adapters.map_rotation
            if rotation and type(rotation.tick)=='function' then
                local ok,ready,why=pcall(rotation.tick,s,w)
                if not ok or ready==false then info.map_rotation_error=tostring(why or ready):sub(1,180) else info.map_rotation_error=nil end
            end
            if travel_pending then return end
            update_weather(s,w);publish(s,pc)
        end
        if options.show_hud~=true then hide();return end
        local wn=name(w) or ''
        if wn:lower():find('/lobby',1,true) then hide();return end
        if widget_world~=wn or widget_controller~=name(pc) or not valid(widget) or not valid(label) then
            hide();if now()<retry_after then return end
            local ready,why=make_widget(pc,w)
            if not ready then info.error=why;retry_after=now()+5;log(why);return end
        end
        local value,count=M.format_status(s,notice)
        if value~=last_value then
            local made,txt=pcall(make_text,value)
            if made and call(label,'SetText',txt) then
                last_value=value
                local height=math.max(135,count*25+25)
                call(background_slot,'SetOffsets',{Left=0,Top=0,Right=670,Bottom=height})
                call(label_slot,'SetOffsets',{Left=18,Top=14,Right=640,Bottom=height-20})
                call(widget,'SetDesiredSizeInViewport',{X=670,Y=height})
            end
        end
        local_state=s;info.hud=valid(widget);s.controls=info
    end
    local function input()
        if not accepting or not keys or travel_pending then return end
        local pc=local_controller();if not valid(pc) then was_down=false;return end
        local _,local_pc=call(pc,'IsLocalController');local _,authority=call(pc,'HasAuthority')
        if local_pc~=true or authority~=true then was_down=false;return end
        local ok,down=call(pc,'IsInputKeyDown',keys)
        if not ok or type(down)~='boolean' then return end
        local trigger=down and not was_down;was_down=down
        if trigger then
            local s=core.public_status()
            local active=s.phase=='RUNNING' or s.phase=='PREMATCH'
            if active then auto.armed=false;info.autostart_armed=false end
            local ran,result,why=pcall(core.command,active and 'stop' or 'play')
            if not ran or result~=true then notice=tostring(why or result or 'Start nicht möglich'):sub(1,140)
            else notice='' end
            pcall(update)
        end
    end
    function self.start()
        if accepting then return true end
        if type(loop)~='function' or type(cancel)~='function' or make_name==nil then return false,'Game-thread input APIs unavailable' end
        for _,adapter_name in ipairs({'spectator','host_card'})do
            local adapter,why=load_adapter(adapter_name)
            if not adapter then self.shutdown();return false,why end
            adapters[adapter_name]=adapter
            local ok,ready=pcall(adapter.start)
            if not ok or ready~=true then self.shutdown();return false,adapter_name..' adapter could not start' end
        end
        local weather,weather_error=load_adapter('weather')
        if weather then adapters.weather=weather else info.weather_error=weather_error end
        for _,key in ipairs({'native_round','group_spawn','team_play','zombie_behavior','map_rotation'})do
            local adapter,why=load_adapter(key)
            if adapter then
                adapters[key]=adapter
                if key~='native_round' and type(adapter.start)=='function' then
                    local ok,ready=pcall(adapter.start)
                    if not ok or ready~=true then info[key..'_error']='Adapterstart fehlgeschlagen' end
                end
            else info[key..'_error']=why end
        end
        local built,key=pcall(make_name,'F10');if not built then self.shutdown();return false,'F10 key unavailable' end
        keys={KeyName=key};accepting=true;generation=generation+1;local token=generation
        local cb=function()if accepting and generation==token then pcall(input) end end
        local ok,h
        if type(after_frames)=='function' then ok,h=pcall(after_frames,1,cb) else ok,h=pcall(loop,40,cb) end
        if not ok or not integer(h,0,1000000000) then self.shutdown();return false,'Game-thread input timer failed' end
        input_timer=h
        local ui_ok,uh=pcall(loop,250,function()if accepting and generation==token then local good,err=pcall(update);if not good then info.error=tostring(err):sub(1,180) end end end)
        if not ui_ok or not integer(uh,0,1000000000) then self.shutdown();return false,'Scoreboard timer failed' end
        ui_timer=uh
        if options.enable_modded_guest_overlay==true and type(register)=='function' and type(unregister)=='function' and find('/Script/Engine.PlayerController:ClientMessage') then
            local callback=function(receiver,message,kind)
                if not accepting or generation~=token then return end
                local pc=unwrap(receiver);local _,is_local=call(pc,'IsLocalController');local _,authority=call(pc,'HasAuthority')
                if is_local~=true or authority==true or text(unwrap(kind))~='ZDeathmatch' then return end
                local parsed=M.parse_packet(text(unwrap(message)))
                if M.accept_packet(remote_state,parsed,retired_sessions) then remote_state=parsed;remote_received=now() end
                -- No return override; the existing client RPC continues normally.
            end
            callback_refs[#callback_refs+1]=callback
            local hooked,pre,post=pcall(register,'/Script/Engine.PlayerController:ClientMessage',callback)
            if hooked and type(pre)=='number' and type(post)=='number' then hook_ids={pre,post};info.receive_rpc=true end
        end
        info.ready=true;core.public_status().controls=info;log('F10-Steuerung und Z-Deathmatch-Anzeige bereit')
        return true
    end
    function self.shutdown()
        accepting=false;generation=generation+1
        local clean_shutdown=true
        -- Restore a team config before validating/restoring the score override.
        for _,key in ipairs({'map_rotation','group_spawn','zombie_behavior','weather','team_play','native_round','spectator','host_card'})do
            local adapter=adapters[key]
            if adapter and type(adapter.shutdown)=='function' then local ok,result=pcall(adapter.shutdown);if not ok or result==false then clean_shutdown=false end end
            adapters[key]=nil
        end
        adapters={}
        for _,h in pairs({input=input_timer,ui=ui_timer}) do
            if h~=nil and type(cancel)=='function' then local ok,result=pcall(cancel,h);if not ok or result==false then clean_shutdown=false end end
        end
        input_timer,ui_timer=nil,nil
        if hook_ids and type(unregister)=='function' then
            local ok,result=pcall(unregister,'/Script/Engine.PlayerController:ClientMessage',hook_ids[1],hook_ids[2])
            if not ok or result==false then clean_shutdown=false end
        end
        hook_ids=nil;hide();info.ready=false;info.cleanup_failed=not clean_shutdown
        return clean_shutdown
    end
    function self.info()return info end
    return self
end
return M
