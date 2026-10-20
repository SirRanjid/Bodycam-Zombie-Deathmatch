-- A real private-host entry: reuse the dormant Zombie card with Deathmatch data.
-- The game still owns map selection, confirmation, private session creation/travel.
local M={}
local HOST='/Game/UI/Menus/Play/Submenus/W_CustomGameModeSubmenu.W_CustomGameModeSubmenu_C:'
local MAP='/Game/UI/Menus/MapRotation/W_MapRotationSubmenu.W_MapRotationSubmenu_C:'
local TABLE='/Game/UI/Menus/Play/Cards/Data/DT_UI_DeathmatchMaps.DT_UI_DeathmatchMaps'
local GI='/Game/MenuSystemPro/Blueprints/Core/BodycamGI.BodycamGI_C:'
local CLICK='BndEvt__W_CasualSubmenu_ModeTileView_K2Node_ComponentBoundEvent_2_SimpleListItemEventDynamic__DelegateSignature'
local TITLE='Z-Deathmatch'
local DESCRIPTION='5 Minuten. 7 Zombies pro Spieler, mindestens 10, maximal 42. 80% Läufer nach 1–4 Sekunden, einige schneller. Zombie +1, Spieler-Kill -5. Bei -15 Zuschauer bis Rundenende.'
local TAG='1–6 Spieler'
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
local function string_value(o)if type(o)=='string' then return o end;local ok,v=call(o,'ToString');return ok and type(v)=='string' and v or nil end
local function is_host(o)
    local ok,c=call(o,'GetClass')
    for _=1,8 do
        local n=ok and name(c);if not n then return false end
        if n:match('([^./: ]+)$')=='W_CustomGameSubmenu_C' then return true end
        ok,c=call(c,'GetSuperStruct')
    end
    return false
end
function M.new(core,api,options)
    api,options=api or {},options or {}
    local self={};local backups={};local views={};local session_limits={};local hooks={};local timer;local started=false
    local choice,pending;local table_asset;local suspended=false
    local info={ready=false,mode_name='Z-Deathmatch',underlying_mode=2,max_players=6,patched=0,reapplied=0,view_refreshes=0,pending=false,auto_started=false,
        private_native_flow=true,hosting_live_verified=false,game_thread_only=true}
    local register=api.RegisterHook or RegisterHook;local unregister=api.UnregisterHook or UnregisterHook
    local loop=api.LoopInGameThreadWithDelay or LoopInGameThreadWithDelay;local cancel=api.CancelDelayedAction or CancelDelayedAction
    local make_text=api.FText or FText;local make_name=api.FName or FName
    local function log(s)if options.log then pcall(options.log,'[Z-Deathmatch Host] '..tostring(s)) end end
    local function find(path)local ok,o=pcall(api.StaticFindObject,path);return ok and valid(o) and o or nil end
    local validity_cdo,validity_function
    local function engine_lives(object)
        if object==nil then return false end
        if not valid(validity_cdo) then validity_cdo=find('/Script/Engine.Default__KismetSystemLibrary')end
        if not valid(validity_function) then validity_function=find('/Script/Engine.KismetSystemLibrary:IsValid')end
        if not valid(validity_cdo) or not valid(validity_function) then return nil end
        local ok,alive=call(validity_function,'CallFunction',validity_cdo,object)
        if ok and type(alive)=='boolean' then return alive end
    end
    local function world()
        local ok,list=pcall(api.FindAllOf,'GameViewportClient')
        if ok and type(list)=='table' then for _,v in ipairs(list)do local w=get(v,'World');if valid(w) then return w end end end
    end
    local function text(s)
        if make_text~=nil then local ok,t=pcall(function()return make_text(s)end);if ok and t~=nil then return t end end
        local ok,t=call(find('/Script/Engine.Default__KismetTextLibrary'),'Conv_StringToText',s)
        return ok and t or nil
    end
    local function in_list(host,data)
        local list=get(host,'ModeTileView');if not valid(list) then return false end
        local ok,n=call(list,'GetNumItems');if not ok or type(n)~='number' or n<1 or n>32 then return false end
        for i=0,n-1 do local got,item=call(list,'GetItemAt',i);if got and name(item)==name(data) then return true end end
        return false
    end
    local function restore_record(r)
        if not valid(r.object) then return true end
        local texts={}
        for _,k in ipairs({'Name','Description','Tag','SpecialEventText'})do
            texts[k]=text(r[k]);if texts[k]==nil then return false,'Original '..k..' text could not be constructed' end
        end
        if not valid(r.MapTable) then return false,'Original map table is unavailable' end
        local ok,why=pcall(function()
            for _,k in ipairs({'GameMode','MapTable','PlayerMin','PlayerMax','bAvailable','bCompetitive','EstimateTime'})do r.object[k]=r[k] end
            for k,v in pairs(texts)do r.object[k]=v end
        end)
        if not ok then return false,tostring(why) end
        for _,k in ipairs({'GameMode','PlayerMin','PlayerMax','bAvailable','bCompetitive','EstimateTime'})do
            if get(r.object,k)~=r[k] then return false,'Original '..k..' did not restore' end
        end
        if name(get(r.object,'MapTable'))~=name(r.MapTable) then return false,'Original MapTable did not restore' end
        for k in pairs(texts)do if string_value(get(r.object,k))~=r[k] then return false,'Original '..k..' did not restore' end end
        return true
    end
    local function data_matches(data)
        return valid(table_asset) and valid(get(data,'MapTable'))
            and get(data,'GameMode')==2 and name(get(data,'MapTable'))==name(table_asset)
            and string_value(get(data,'Name'))==TITLE and string_value(get(data,'Description'))==DESCRIPTION
            and get(data,'PlayerMin')==1 and get(data,'PlayerMax')==6 and get(data,'bAvailable')==true
            and get(data,'bCompetitive')==false and get(data,'EstimateTime')==10
            and string_value(get(data,'Tag'))==TAG and string_value(get(data,'SpecialEventText'))==''
    end
    local function apply(data,host,creating)
        if not info.ready or not valid(data) or not is_host(host) then return false end
        local key=name(data);if not key then return false end
        if not creating and not in_list(host,data) then return false end
        local before=backups[key]
        local label=string_value(get(data,'Name'))
        if not before and (get(data,'GameMode')~=4 or get(data,'bCompetitive')==true
            or not label or not label:lower():find('zombie',1,true)) then return false end
        if not valid(table_asset) then
            table_asset=find(TABLE)
            if not table_asset and type(api.LoadAsset)=='function' then local ok,t=pcall(api.LoadAsset,TABLE);if ok and valid(t) then table_asset=t end end
        end
        if not valid(table_asset) then info.error='The installed Deathmatch map table is unavailable';return false end
        if before then
            -- Native menu construction may reset the SAME UObject. Its original
            -- backup stays immutable; only its current owning host is refreshed.
            before.object=data;before.host=host
            if data_matches(data) then return true end
        end
        local existing=before~=nil
        before=before or {object=data,host=host,Name=label,Description=string_value(get(data,'Description')),
            GameMode=get(data,'GameMode'),MapTable=get(data,'MapTable'),PlayerMin=get(data,'PlayerMin'),PlayerMax=get(data,'PlayerMax'),
            bAvailable=get(data,'bAvailable'),bCompetitive=get(data,'bCompetitive'),EstimateTime=get(data,'EstimateTime'),
            Tag=string_value(get(data,'Tag')),SpecialEventText=string_value(get(data,'SpecialEventText'))}
        if type(before.PlayerMin)~='number' or type(before.PlayerMax)~='number' or type(before.bAvailable)~='boolean'
            or not before.Description or not before.Tag or not before.SpecialEventText then return false end
        local title,description,tag,empty=text(TITLE),text(DESCRIPTION),text(TAG),text('')
        if not title or not description or not tag or not empty then return false end
        backups[key]=before
        local ok=pcall(function()
            data.Name=title;data.Description=description;data.GameMode=2;data.MapTable=table_asset
            data.PlayerMin=1;data.PlayerMax=6;data.bAvailable=true;data.bCompetitive=false
            data.EstimateTime=10;data.Tag=tag;data.SpecialEventText=empty
        end)
        if not ok or not data_matches(data) then
            restore_record(before);if not existing then backups[key]=nil end
            info.error='Host card data could not be changed completely';return false
        end
        before.revision=(before.revision or 0)+1
        if existing then info.reapplied=info.reapplied+1 else info.patched=info.patched+1 end
        info.error=nil;log('Private host card prepared: Z-Deathmatch / ordinary Deathmatch maps')
        return true
    end
    local function view_matches(v)
        for _,entry in ipairs({{'NameText',TITLE},{'DescriptionText',DESCRIPTION},{'PlayerMaxText_1',TAG}})do
            local widget=get(v,entry[1])
            if valid(widget) then local ok,value=call(widget,'GetText');if not ok or string_value(value)~=entry[2] then return false end end
        end
        for _,entry in ipairs({{'CardButton',0},{'SpecialEventBox',1},{'WarningPartySize',1}})do
            local widget=get(v,entry[1]);local ok,value=call(widget,'GetVisibility')
            if not ok or value~=entry[2] then return false end
        end
        local ok,enabled=call(get(v,'CardButton'),'GetIsEnabled');return ok and enabled==true
    end
    local function update_view(v)
        local data=get(v,'CardData');local rec=backups[name(data) or '']
        if not rec or engine_lives(rec.host)~=true or not in_list(rec.host,data) or not data_matches(data) then return end
        local k=name(v);if not k then return end
        local old=views[k]
        if old and old.data==name(data) and old.revision==rec.revision and name(old.host)==name(rec.host) and view_matches(v) then return end
        -- Save each changed widget's real visibility for runtime-only restoration.
        local saved=old or {widgets={}};saved.object=v;saved.data=name(data);saved.host=rec.host
        for _,field in ipairs({'CardButton','SpecialEventBox','WarningPartySize'})do
            local o=get(v,field);local ok,visibility=call(o,'GetVisibility')
            local prior=saved.widgets[field]
            if ok and type(visibility)=='number' and (not prior or not valid(prior.object) or name(prior.object)~=name(o)) then
                saved.widgets[field]={object=o,visibility=visibility}
                if field=='CardButton' then
                    local read,enabled=call(o,'GetIsEnabled')
                    if read and type(enabled)=='boolean' then saved.widgets[field].enabled=enabled end
                end
            end
        end
        if not call(v,'InitializeData',data) then views[k]=saved;return end
        call(get(v,'CardButton'),'SetVisibility',0)
        call(get(v,'CardButton'),'SetIsEnabled',true)
        call(get(v,'SpecialEventBox'),'SetVisibility',1)
        call(get(v,'WarningPartySize'),'SetVisibility',1)
        saved.revision=rec.revision;views[k]=saved;info.view_refreshes=info.view_refreshes+1
    end
    local function clear_pending(reason)
        pending=nil;choice=nil;info.pending=false;info.pending_reason=reason
    end
    local function hook(path,pre,post)
        if hooks[path] then return true end
        if type(register)~='function' or not find(path) then return false end
        local function guarded(callback)
            if type(callback)~='function' then return nil end
            return function(...)if started and not suspended then return callback(...) end end
        end
        local ok,a,b=pcall(register,path,guarded(pre),guarded(post))
        if ok and type(a)=='number' and type(b)=='number' then hooks[path]={a,b};return true end
        return false
    end
    local function install_hooks()
        -- UpdateSession StartGame's third argument is MatchContext=4, not a cap.
        -- Its first synchronous step calculates Session Max Players. The ensuing
        -- native UpdateLobby reads that exact property, so override it here only
        -- for the GI from our confirmed private card.
        local function cap_session(gi)
            local key=name(gi)
            if not pending or key~=pending.game_instance_name or name(world())~=pending.source_world then return false end
            if get(gi,'Gamemode')~=2 then info.error='The native host did not select ordinary Deathmatch';return false end
            local old=get(gi,'Session Max Players')
            if type(old)~='number' then info.error='Native private session limit is unreadable';return false end
            if not session_limits[key] then session_limits[key]={object=gi,before=old} end
            local set=pcall(function()gi['Session Max Players']=6 end)
            pending.limit_set=set and get(gi,'Session Max Players')==6
            info.native_session_limit=pending.limit_set and 6 or nil
            if not pending.limit_set then info.error='Native six-player session limit could not be applied' end
            return pending.limit_set
        end
        -- FIRST callback is POST for cooked Blueprint UFunctions in UE4SS83330635.
        hook(GI..'UpdateLocalGamemodeAndMaxPlayers',function(context,mode)
            local gi=unwrap(context);local key=name(gi)
            if not pending or unwrap(mode)~=2 or key~=pending.game_instance_name
                or name(world())~=pending.source_world then return end
            cap_session(gi)
        end)
        hook(HOST..'CreateCardData',function(context,_,out_data)
            apply(unwrap(out_data),unwrap(context),true)
        end)
        hook(HOST..CLICK,function(context,item)
            local host,data=unwrap(context),unwrap(item)
            if not is_host(host) then return end
            clear_pending('Another host choice')
            if backups[name(data) or ''] and in_list(host,data) and data_matches(data) then
                local w=world()
                choice={host=host,data=data,world_name=name(w),expires=os.time()+300}
                local wrapper=get(host,'MapRotationWrapperMenu')
                local submenu=get(wrapper,'MapRotationSubmenu')
                if valid(submenu) and get(submenu,'Gamemode')==2 then choice.submenu=submenu end
            end
        end)
        hook(MAP..'OnMapSelectedModalConfirmation',function(context)
            local menu=unwrap(context);local w=world()
            if not choice or os.time()>choice.expires or name(w)~=choice.world_name
                or name(menu)~=name(choice.submenu) or not is_host(choice.host)
                or not in_list(choice.host,choice.data) or get(choice.data,'GameMode')~=2
                or get(menu,'Gamemode')~=2 or not valid(get(menu,'SelectedLevel')) then return end
            local gs=find('/Script/Engine.Default__GameplayStatics')
            local got,gi=call(gs,'GetGameInstance',menu)
            if not got or not valid(gi) then info.error='The selected private GameInstance is unavailable';return end
            pending={source_world=choice.world_name,game_instance_name=name(gi),expires=os.time()+180,next_attempt=0,attempts=0}
            -- Original confirmation called UpdateSession StartGame already. In the
            -- current GI graph UpdateLobby follows a verified 1.0-second Delay;
            -- setting the property in this POST therefore precedes its cap read.
            if not cap_session(gi) then clear_pending(info.error);return end
            info.pending=true;info.auto_started=false;info.pending_reason='Waiting for the confirmed private map to load'
            log('Z-Deathmatch map confirmed; waiting for native private host travel')
        end)
        info.ready=hooks[HOST..CLICK]~=nil and hooks[MAP..'OnMapSelectedModalConfirmation']~=nil
            and hooks[GI..'UpdateLocalGamemodeAndMaxPlayers']~=nil
    end
    function self.tick()
        if not started or suspended then return end
        install_hooks()
        local hosts,cards,seen_hosts,seen_cards={},{},{},{}
        -- Include the source base class as well as its known private-host child.
        -- is_host still excludes Casual/Competitive submenus sharing that base.
        for _,class in ipairs({'W_CustomGameSubmenu_C','W_CustomGameModeSubmenu_C'})do
            local ok,list=pcall(api.FindAllOf,class)
            if ok and type(list)=='table' then for _,host in ipairs(list)do
                if engine_lives(host)==true then local key=name(host);if key and not seen_hosts[key] then seen_hosts[key]=true;hosts[#hosts+1]=host end end
            end end
        end
        for _,host in ipairs(hosts)do
            if is_host(host) then
                local list=get(host,'ModeTileView');local read,n=call(list,'GetNumItems')
                if read and type(n)=='number' and n>=0 and n<=32 then
                    for i=0,n-1 do local got,data=call(list,'GetItemAt',i);if got then apply(data,host,false) end end
                end
            end
        end
        for _,class in ipairs({'W_PlayModeButtonCard_C','W_PlayModeCard_C'})do
            local ok,list=pcall(api.FindAllOf,class)
            if ok and type(list)=='table' then for _,v in ipairs(list)do
                if engine_lives(v)==true then local key=name(v);if key and not seen_cards[key] then seen_cards[key]=true;cards[#cards+1]=v end end
            end end
        end
        for _,v in ipairs(cards)do update_view(v) end
        if not pending then return end
        if os.time()>pending.expires then clear_pending('Private map load timed out');return end
        local state=type(core.public_status)=='function' and core.public_status() or {}
        if state.phase=='RUNNING' then clear_pending('Round already running');return end
        local w=world();local wn=name(w)
        if not wn or wn==pending.source_world or wn:lower():find('/lobby',1,true) or wn:lower():find('mainmenu',1,true)
            or wn:lower():find('transition',1,true) then return end
        if not valid(get(w,'AuthorityGameMode')) or os.time()<pending.next_attempt then return end
        if not pending.limit_set then
            info.error='The map loaded without a verified six-player native session limit'
            clear_pending(info.error);log(info.error);return
        end
        pending.next_attempt=os.time()+1;pending.attempts=pending.attempts+1
        local ran,result,why=pcall(core.play)
        if ran and result==true then
            info.auto_started=true;info.started_world=wn;clear_pending('Z-Deathmatch started on the confirmed private map')
            log('Confirmed private Z-Deathmatch started')
        elseif pending.attempts>=15 then
            info.error='The private map loaded, but the round could not start: '..tostring(why or result):sub(1,180)
            log(info.error);clear_pending(info.error)
        end
    end
    function self.suspend()
        suspended=true;info.suspended=true;return true
    end
    function self.resume(world_changed)
        if not started then return false end
        if world_changed then
            -- These UI objects belonged to the previous world. Forget their
            -- wrappers without invoking any method or restoring detached menus.
            backups={};views={};choice=nil;pending=nil;table_asset=nil
            info.patched=0;info.pending=false
        end
        suspended=false;info.suspended=false;return true
    end
    function self.start()
        if started then return true end
        if (info.cleanup_failed or 0)>0 then return false,'Previous host-menu cleanup is incomplete' end
        if type(loop)~='function' or type(cancel)~='function' or type(register)~='function' or type(unregister)~='function' then return false end
        local ok,id=pcall(loop,500,function()
            if not started then return end
            local ran,err=pcall(self.tick);if not ran then info.error=tostring(err):sub(1,200);log(info.error) end
        end)
        if not ok or type(id)~='number' then return false end
        timer=id;started=true;suspended=false;info.suspended=false;self.tick();return true
    end
    function self.shutdown()
        started=false;suspended=true;info.suspended=true;clear_pending('Adapter shutdown')
        local failed=0;local errors={};local skipped={card_data=0,views=0,widgets=0,session_limits=0}
        local function failure(operation,object,why)
            failed=failed+1
            errors['error_'..failed]={operation=operation,object=name(object) or '<invalid>',reason=tostring(why or 'Operation failed'):sub(1,180)}
        end
        local function attempt(object,method,...)
            local ok,result=call(object,method,...)
            return ok and result~=false,result
        end
        if timer then
            local ok,result=pcall(cancel,timer)
            if not ok or result==false then failure('cancel_timer',nil,result) else timer=nil end
        end
        for p,ids in pairs(hooks)do
            local ok,result=pcall(unregister,p,ids[1],ids[2])
            if not ok and not find(p) and type(api.LoadAsset)=='function' then
                -- UE4SS resolves the UFunction by path before unregistering its
                -- persistent name-keyed script callback. Reload only our two
                -- fixed menu classes, then retry the original hook IDs once.
                local owner=p:match('^(.-):[^:]+$')
                if owner==HOST:sub(1,-2) or owner==MAP:sub(1,-2) then
                    local loaded=pcall(api.LoadAsset,owner)
                    if loaded and find(p) then ok,result=pcall(unregister,p,ids[1],ids[2]) end
                end
            end
            if not ok or result==false then failure('unregister_hook',nil,p..': '..tostring(result)) else hooks[p]=nil end
        end
        local card_failed={}
        for key,r in pairs(backups)do
            local lives=engine_lives(r.object)
            if lives==nil then failure('validate_card_data',nil,'Native engine validity is unavailable')
            elseif not lives then skipped.card_data=skipped.card_data+1;backups[key]=nil
            else
                local ok,why=restore_record(r)
                if not ok then failure('restore_card_data',r.object,why);card_failed[key]=true else backups[key]=nil end
            end
        end
        for key,r in pairs(session_limits)do
            local lives=engine_lives(r.object)
            if lives==nil then failure('validate_session_limit',nil,'Native engine validity is unavailable')
            elseif not lives then skipped.session_limits=skipped.session_limits+1;session_limits[key]=nil
            elseif get(r.object,'Session Max Players')==6 then
                local ok=pcall(function()r.object['Session Max Players']=r.before end)
                if not ok or get(r.object,'Session Max Players')~=r.before then failure('restore_session_limit',r.object,'Original native player limit did not restore')
                else session_limits[key]=nil end
            else session_limits[key]=nil end -- A later ordinary host choice owns its new limit.
        end
        for key,v in pairs(views)do
            local view_lives=engine_lives(v.object)
            local data=view_lives==true and get(v.object,'CardData') or nil
            -- A live UObject wrapper can belong to a detached menu or a recycled
            -- list row. Never call InitializeData with its dead/foreign CardData.
            if view_lives==nil then failure('validate_original_view',nil,'Native engine validity is unavailable')
            elseif not view_lives or engine_lives(data)~=true or name(data)~=v.data
                or engine_lives(v.host)~=true or not in_list(v.host,data) then
                skipped.views=skipped.views+1;views[key]=nil
            elseif not card_failed[v.data] then
                local before=failed
                local ok,why=attempt(v.object,'InitializeData',data)
                if not ok and valid(v.object) then failure('initialize_original_view',v.object,why) end
                for field,r in pairs(v.widgets)do
                    local current=get(v.object,field)
                    if engine_lives(v.object)~=true or engine_lives(r.object)~=true or engine_lives(current)~=true or name(current)~=name(r.object) then
                        skipped.widgets=skipped.widgets+1
                    else
                        local restored,detail=attempt(r.object,'SetVisibility',r.visibility)
                        local read,visibility=call(r.object,'GetVisibility')
                        if valid(r.object) and (not restored or not read or visibility~=r.visibility) then failure('restore_widget_visibility',r.object,detail) end
                        if type(r.enabled)=='boolean' then
                            local enabled,err=attempt(r.object,'SetIsEnabled',r.enabled)
                            local got,value=call(r.object,'GetIsEnabled')
                            if valid(r.object) and (not enabled or not got or value~=r.enabled) then failure('restore_widget_enabled',r.object,err) end
                        end
                    end
                end
                if failed==before then views[key]=nil end
            end
        end
        local remaining=0;for _ in pairs(backups)do remaining=remaining+1 end
        info.ready=false;info.patched=remaining;info.cleanup_failed=failed;info.cleanup_errors=errors;info.cleanup_skipped=skipped
        return failed==0
    end
    function self.status()return info end
    self.info=self.status
    return self
end
return M
