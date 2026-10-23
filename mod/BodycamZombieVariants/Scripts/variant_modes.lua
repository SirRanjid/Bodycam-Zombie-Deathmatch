-- Native host variants. All gameplay enums, map tables and limits stay native.
local M={}
local HOST='/Game/UI/Menus/Play/Submenus/W_CustomGameModeSubmenu.W_CustomGameModeSubmenu_C:'
local CLICK=HOST..'BndEvt__W_CasualSubmenu_ModeTileView_K2Node_ComponentBoundEvent_2_SimpleListItemEventDynamic__DelegateSignature'
local CONFIRM='/Game/UI/Menus/MapRotation/W_MapRotationSubmenu.W_MapRotationSubmenu_C:OnMapSelectedModalConfirmation'
local ATTR='/Script/Bodycam.BodycamOnlineTypesLibrary:MakeStringLobbyAttribute'
local READ='/Script/Bodycam.BodycamOnlineTypesLibrary:GetStringAttribute'
local READ_KEY='__BodycamZombieVariantsAttributeRead'
local UPDATE='/Script/Bodycam.BodycamUpdateLobby:UpdateLobby'
local CREATE='/Script/Bodycam.BodycamCreateLobby:CreateLobby'
local CURRENT='/Script/Bodycam.BodycamOnlineManager:GetCurrentLobbyInfo'
local DATA='/Game/UI/Menus/Play/Cards/Data/BP_PlayModeCardData.BP_PlayModeCardData_C'
local ENUM='/Game/GM/DATA/Enum/GameMode.GameMode'
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
local function str(o)if type(o)=='string' then return o end;local ok,v=call(o,'ToString');return ok and type(v)=='string' and v or nil end
local function copy(t)local r={};for k,v in pairs(t or {})do if type(v)~='table' and type(v)~='userdata' and type(v)~='function' then r[k]=v end end;return r end
local function host_only(o)
    local ok,c=call(o,'GetClass')
    for _=1,8 do
        local n=ok and name(c);if not n then return false end
        if n:match('([^./: ]+)$')=='W_CustomGameSubmenu_C' then return true end
        ok,c=call(c,'GetSuperStruct')
    end
    return false
end
function M.new(api,options)
    api,options=api or {},options or {}
    local wrapper_valid=valid
    local function valid(o)
        if not wrapper_valid(o) then return false end
        if type(options.is_live)=='function' then local ok,v=pcall(options.is_live,o);return ok and v==true end
        return true
    end
    local self={};local hooks={};local cards={};local hosts={};local running=false
    local choice,pending,active;local last_world;local polling=false;local write_context;local read_contexts={}
    local info={ready=false,cards=0,outgoing_verified=false,published_verified=false,guest_mod_required=false}
    local function log(s)if options.log then pcall(options.log,'[Zombie variants] '..s)end end
    local function find(p)local ok,o=pcall(api.StaticFindObject,p);return ok and valid(o) and o or nil end
    local function now()return options.now and options.now() or os.time() end
    local function world()
        local ok,list=pcall(api.FindAllOf,'GameViewportClient')
        if ok and type(list)=='table' then for _,vp in ipairs(list)do local w=get(vp,'World');if valid(w)then return w end end end
    end
    local function token(w)
        if type(options.world_key)=='function' then local ok,k=pcall(options.world_key,w);return ok and k or nil end
        local n=name(w);if not n then return nil end;local ok,a=call(w,'GetAddress')
        return n..(ok and type(a)=='number' and '@'..string.format('%.0f',a) or '')
    end
    local function transition(w)return (name(w)or''):lower():find('transition',1,true)~=nil end
    local function lobby(w)
        local n=(name(w)or''):lower()
        return not transition(w)and(n:find('/lobby',1,true)or n:find('mainmenu',1,true))
    end
    local function gi_of(w)local ok,gi=call(find('/Script/Engine.Default__GameplayStatics'),'GetGameInstance',w);return ok and valid(gi) and gi or nil end
    local function notify(k,v)if type(options[k])=='function' then pcall(options[k],v and copy(v) or nil) end end
    local function clear(reason)
        choice=nil;pending=nil;active=nil;info.outgoing_verified=false;info.published_verified=false;info.active=false;info.reason=reason
        info.last_clear_reason=reason;info.last_clear_world=info.current_world
        notify('on_select',nil);notify('on_active',nil)
    end
    local function capable()
        if type(options.ready)~='function' then return false end
        local ok,yes,why=pcall(options.ready);if not ok or yes~=true then info.reason=why or 'Zombie runtime is not ready';return false end
        return true
    end
    local function text(s)local ok,t=pcall(api.FText,s);return ok and t or nil end
    local function fname(s)local ok,n=pcall(api.FName,s);return ok and n or nil end
    local function in_list(list,item)
        local ok,n=call(list,'GetNumItems');if not ok or type(n)~='number' or n>64 then return false end
        for i=0,n-1 do local got,v=call(list,'GetItemAt',i);if got and name(v)==name(item)then return true end end
        return false
    end
    local function native_name(mode)
        local ok,v=call(find('/Script/Engine.Default__KismetNodeHelperLibrary'),'GetEnumeratorUserFriendlyName',find(ENUM),mode)
        return ok and str(v) or nil
    end
    local function applicable(publication_only)
        local a=pending or active
        -- A confirmed host intent must still mark the game's one-shot lobby
        -- publication while gameplay dependencies temporarily reload. Offering
        -- cards, verifying publication and enabling gameplay remain ready-gated.
        if not a or not publication_only and not capable() then return nil end
        local w=world();local gi=gi_of(w)
        if not valid(w)or transition(w)and not publication_only then return nil end
        if not gi or name(gi)~=a.gi or get(gi,'Gamemode')~=a.mode then return nil end
        if pending and (now()>pending.expires or token(w)~=pending.source_world and lobby(w))then return nil end
        if active and lobby(w) then return nil end
        return a
    end
    local function read_settings(settings)
        -- Update/CreateLobby use FString keys; SearchResult uses FName keys.
        -- Neither a mismatched remote map nor a nested Lua map is safe here:
        -- the pinned UE4SS table-map converter also ignores nested stack indices.
        local checked,contains=call(settings,'Contains','Gamemode')
        if not checked or type(contains)~='boolean'then return nil,'Native lobby attribute lookup failed'end
        if not contains then return nil end
        local got,entry=call(settings,'Find','Gamemode')
        if not got or entry==nil then return nil,'Native lobby attribute unavailable'end
        local key=fname(READ_KEY);if key==nil then return nil,'Native lobby read key unavailable'end
        if #read_contexts>=8 then return nil,'Native lobby read nesting exceeded'end
        local frame={attribute=unwrap(entry),key=key};read_contexts[#read_contexts+1]=frame
        -- Pass an empty native struct; PRE seeds its correctly typed native map.
        -- The private lookup key prevents an unrelated recursive getter from
        -- consuming this frame. The source map still reads only Gamemode.
        local out={};local ok,found=call(find('/Script/Bodycam.Default__BodycamOnlineTypesLibrary'),'GetStringAttribute',
            {},key,out)
        read_contexts[#read_contexts]=nil;frame.attribute=nil;frame.key=nil
        if not frame.seeded then return nil,frame.error or'Native lobby read hook did not run'end
        if not ok then return nil,'Native lobby attribute getter failed'end
        local result=found==true and str(out.OutString)or nil
        if result==nil then return nil,'Native lobby attribute readback did not verify'end
        return result
    end
    local function hook(path,pre,post)
        if hooks[path]then return true end
        if not find(path)or type(api.RegisterHook)~='function'then return false end
        local function guard(f)if not f then return nil end;return function(...)if running then return f(...)end end end
        -- Installed UE4SS requires a first callback even for POST-only hooks.
        local ok,a,b=pcall(api.RegisterHook,path,guard(pre or function()end),guard(post))
        if ok and type(a)=='number' and type(b)=='number'then hooks[path]={a,b};return true end
        return false
    end
    local function install()
        hook(READ,function(_,result,key)
            local frame=read_contexts[#read_contexts]
            if not frame or frame.consumed or str(unwrap(key))~=READ_KEY then return end
            frame.consumed=true
            local map=get(unwrap(result),'LobbySettings')
            -- Add uses this native map's own FName key and attribute layout.
            -- Both source attribute and destination parameter remain live here.
            local copied=call(map,'Add',frame.key,frame.attribute)
            if copied then frame.seeded=true else frame.error='Native lobby read staging failed'end
        end)
        hook(ATTR,nil,function(_,result,value)
            -- Copy the opaque native result while both stack frames are alive.
            -- UE4SS's ordinary Lua return would contain no reflected fields.
            local c=write_context;if not c or str(unwrap(value))~=c.name then return end
            c.wrote=call(c.settings,'Add','Gamemode',unwrap(result))
        end)
        local function publication(_,world_context,settings)
            local a=applicable(true);if not a then return end
            if name(unwrap(world_context))~=a.gi then return end
            local map=unwrap(settings);local actual,read_error=read_settings(map)
            -- Partial unrelated lobby updates need not contain a Gamemode entry.
            if actual==nil then
                if read_error then
                    a.outgoing=false;a.published=false;info.outgoing_verified=false;info.published_verified=false
                    info.reason=read_error;notify('on_active',nil)
                end
                return
            end
            a.outgoing=false;a.published=false;info.outgoing_verified=false;info.published_verified=false
            if actual==a.native_name or actual==a.name or pending and actual=='Training' then
                local c={settings=map,name=a.name};write_context=c
                local made=call(find('/Script/Bodycam.Default__BodycamOnlineTypesLibrary'),'MakeStringLobbyAttribute',a.name)
                write_context=nil
                if not made or not c.wrote then
                    info.reason='Native lobby attribute copy unavailable';return
                end
                actual,read_error=read_settings(map)
                if read_error then info.reason=read_error;notify('on_active',nil);return end
            end
            info.last_outgoing=actual
            if actual==a.name then
                a.outgoing=true;info.outgoing_verified=true;info.reason='Native lobby payload verified'
            else
                a.outgoing=false;info.outgoing_verified=false;info.published_verified=false
                info.reason='Native lobby payload does not match the selected variant';notify('on_active',nil)
            end
        end
        hook(UPDATE,publication)
        hook(CREATE,publication)
        -- Native POST has ReturnValue as its SECOND callback argument.
        hook(CURRENT,nil,function(_,result)
            if not polling then return end
            local a=applicable();if not a or not a.outgoing then return end
            local out={};local ok,found=call(find('/Script/Bodycam.Default__BodycamOnlineTypesLibrary'),'GetLobbyInfoStringAttribute',
                unwrap(result),fname('Gamemode'),out)
            info.last_published=ok and found==true and str(out.OutValue) or nil
            info.published_verified=info.last_published==a.name
            a.published=info.published_verified
        end)
        -- Cooked Blueprint hooks use FIRST callback POST in installed UE4SS.
        hook(CLICK,function(context,item)
            local host,data=unwrap(context),unwrap(item)
            if not host_only(host)then return end
            clear('Host choice changed')
            local r=cards[name(data) or ''];if not r or not capable() or not in_list(get(host,'ModeTileView'),data)then return end
            local w=world();local gi=gi_of(w);local wrapper=get(host,'MapRotationWrapperMenu');local menu=get(wrapper,'MapRotationSubmenu')
            if not gi or not valid(menu)or get(menu,'Gamemode')~=r.mode then return end
            choice=copy(r);choice.source_world=token(w);choice.gi=name(gi);choice.host=name(host);choice.menu=name(menu);choice.expires=now()+300
            notify('on_select',choice)
        end)
        hook(CONFIRM,function(context)
            local menu=unwrap(context);local w=world()
            if not choice or now()>choice.expires or token(w)~=choice.source_world or name(menu)~=choice.menu
                or get(menu,'Gamemode')~=choice.mode or not valid(get(menu,'SelectedLevel'))or not capable()then return end
            local gi=gi_of(w);if not gi or name(gi)~=choice.gi or get(gi,'Gamemode')~=choice.mode then return end
            -- Current cooked GI's UpdateSessionAndTravelToMap yields for 1.0s
            -- before UpdateLobby, so this POST precedes its native publication.
            -- An earlier publication is deliberately not proof of confirmation.
            -- Never replay that GI method: it also broadcasts and travels.
            pending=copy(choice);pending.expires=now()+180;choice=nil
            info.outgoing_verified=false;info.published_verified=false;info.reason='Confirmed variant; waiting for native lobby update and map'
            notify('on_confirm',pending)
        end)
        info.ready=hooks[READ]~=nil and hooks[ATTR]~=nil and hooks[UPDATE]~=nil and hooks[CREATE]~=nil and hooks[CURRENT]~=nil
            and hooks[CLICK]~=nil and hooks[CONFIRM]~=nil and find(ENUM)~=nil
    end
    local function clone(host,original)
        local title=str(get(original,'Name'));local mode=get(original,'GameMode')
        if type(mode)~='number' or mode==0 or mode==4 or not title or title=='' or title:sub(1,2)=='Z-'
            or not valid(get(original,'MapTable'))or get(original,'bAvailable')~=true then return end
        local key=name(host)..'|'..tostring(mode);if hosts[key]then return end
        local canonical=native_name(mode);if not canonical or canonical=='' then return end
        local variant='Z-'..title;if mode==2 then variant=variant..' (Classic)'end
        local ok,obj=call(find('/Script/Engine.Default__GameplayStatics'),'SpawnObject',find(DATA),host)
        if not ok or not valid(obj)then info.reason='Native host-card construction unavailable';return end
        local fields={'Description','Thumbnail','Icon','GameMode','PlayerMin','PlayerMax','bAvailable','MapTable','bCompetitive','EstimateTime','Tag','SpecialEventText'}
        local set=pcall(function()
            for _,k in ipairs(fields)do local value=get(original,k);if value~=nil then obj[k]=value end end
            obj.Name=text(variant);obj.bMarked=false
        end)
        if not set or str(get(obj,'Name'))~=variant or get(obj,'GameMode')~=mode
            or name(get(obj,'MapTable'))~=name(get(original,'MapTable'))or get(obj,'PlayerMax')~=get(original,'PlayerMax')then return end
        local list=get(host,'ModeTileView');if not call(list,'AddItem',obj)or not in_list(list,obj)then return end
        local r={id='native-z-'..tostring(mode),mode=mode,name=variant,native_name=canonical,original_name=title,
            object=obj,host=host,list=list,source=original,world=token(world())}
        cards[name(obj)]=r;hosts[key]=name(obj);info.cards=info.cards+1
    end
    function self.tick()
        if not running then return end
        local w=world();local wn=token(w)
        info.current_world=name(w);info.suspended_transition=false
        if last_world and wn~=last_world then
            -- Forget world-owned wrappers without dereferencing detached objects.
            cards={};hosts={};info.cards=0;choice=nil
            if active and lobby(w)then clear('Returned to lobby')end
        end
        last_world=wn;install()
        if pending and now()>pending.expires then clear('Confirmed map or lobby metadata timed out')end
        -- Native travel can pass through a temporary world. Suspend selection
        -- there without discarding the explicit host intent or old proof; the
        -- destination must still pass GI/mode and current lobby readback checks.
        if transition(w)then
            info.active=false;info.suspended_transition=true;info.reason='Native travel transition; variant suspended'
            notify('on_active',nil);return
        end
        if info.ready and capable()then
            local seen={}
            for _,class in ipairs({'W_CustomGameSubmenu_C','W_CustomGameModeSubmenu_C'})do
                local ok,list=pcall(api.FindAllOf,class)
                if ok and type(list)=='table'then for _,host in ipairs(list)do
                    local hn=name(host)
                    if hn and not seen[hn] and valid(host) and host_only(host)then
                        seen[hn]=true;local view=get(host,'ModeTileView');local got,n=call(view,'GetNumItems')
                        if got and type(n)=='number' and n<=32 then for i=0,n-1 do local yes,item=call(view,'GetItemAt',i);if yes then clone(host,item)end end end
                    end
                end end
            end
        end
        local a=applicable()
        if a and a.outgoing then
            -- A failed getter or missing native POST must not reuse publication
            -- proof from a previous poll/world. Only this poll can restore it.
            a.published=false;info.published_verified=false
            polling=true;call(find('/Script/Bodycam.Default__BodycamOnlineManager'),'GetCurrentLobbyInfo');polling=false
            if a.published and not lobby(w) and valid(get(w,'AuthorityGameMode'))then
                if pending and wn~=pending.source_world then
                    active=copy(pending);pending=nil;active.world=wn;active.world_key=wn;active.world_name=name(w);info.active=true;notify('on_active',active)
                elseif active and active.world~=wn then
                    active.world=wn;active.world_key=wn;active.world_name=name(w);info.active=true;notify('on_active',active)
                elseif active and not info.active then
                    info.active=true;notify('on_active',active)
                end
                if info.active then info.reason='Native lobby metadata verified for active variant'end
            end
        end
        if active and (not a or not info.published_verified)then info.active=false;notify('on_active',nil)end
    end
    function self.start()
        if running then return true end
        if (info.cleanup_failed or 0)>0 then return false,'Previous cleanup is incomplete' end
        running=true;self.tick();return info.ready
    end
    function self.selection()return active and info.active and copy(active)or nil end
    function self.status()
        local out=copy(info);local intent=pending or active
        out.intent_state=pending and'pending'or(active and'active'or nil)
        out.intent_name=intent and intent.name or nil
        return out
    end
    function self.shutdown()
        running=false;clear('Variant adapter stopped');local failures=0
        local wn=token(world())
        for key,r in pairs(cards)do
            if r.world==wn and valid(r.list) and valid(r.object)then
                local ok,result=call(r.list,'RemoveItem',r.object)
                if not ok or result==false or in_list(r.list,r.object)then failures=failures+1 else cards[key]=nil end
            else cards[key]=nil end
        end
        for path,ids in pairs(hooks)do
            local ok,result=pcall(api.UnregisterHook,path,ids[1],ids[2])
            if ok and result~=false then hooks[path]=nil else failures=failures+1 end
        end
        info.cards=0;for _ in pairs(cards)do info.cards=info.cards+1 end
        if info.cards==0 then hosts={}end
        info.ready=false;info.cleanup_failed=failures;return failures==0
    end
    return self
end
return M
