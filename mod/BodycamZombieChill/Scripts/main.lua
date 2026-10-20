-- Z-Deathmatch bootstrap: private-host menu and F10 controls; no automatic map travel.
local source=debug.getinfo(1,'S').source
local dir=source:sub(1,1)=='@' and source:sub(2):match('^(.*[/\\])')
if not dir then print('[BodycamZombieChill] Script directory unavailable\n');return end
local function log(s)
    print('[BodycamZombieChill] '..tostring(s)..'\n')
    local f=io.open(dir..'chill.log','ab')
    if f then f:write(os.date('!%Y-%m-%dT%H:%M:%SZ '),tostring(s),'\n');f:close() end
end
local function json(v,seen)
    local t=type(v)
    if t=='nil' then return 'null' end
    if t=='boolean' then return v and 'true' or 'false' end
    if t=='number' then return v==v and v~=math.huge and v~=-math.huge and tostring(v) or 'null' end
    if t=='string' then return '"'..v:gsub('[%z\1-\31\\"]',function(c)
        if c=='"' then return '\\"' elseif c=='\\' then return '\\\\' end
        return string.format('\\u%04x',c:byte())
    end)..'"' end
    if t~='table' then return 'null' end
    seen=seen or {};if seen[v] then return 'null' end;seen[v]=true
    local entries={}
    for k,item in pairs(v) do
        if type(k)=='string' then entries[#entries+1]=json(k)..':'..json(item,seen) end
    end
    table.sort(entries);seen[v]=nil;return '{'..table.concat(entries,',')..'}'
end
local function status(s)
    local f=io.open(dir..'status.json','wb')
    if f then f:write(json(s),'\n');f:close() end
end
if type(LoopInGameThreadWithDelay)~='function' or type(CancelDelayedAction)~='function' then
    status({phase='BLOCKED',reason='Safe game-thread timer APIs unavailable'});log('Safe game-thread timer APIs unavailable');return
end
local ok,Module=pcall(dofile,dir..'chill.lua')
if not ok or type(Module)~='table' then log('Module load failed: '..tostring(Module));return end
local function make_api()
    return {StaticFindObject=StaticFindObject,FindAllOf=FindAllOf,LoadAsset=LoadAsset,FName=FName,
        FText=FText,StaticConstructObject=StaticConstructObject,RegisterHook=RegisterHook,UnregisterHook=UnregisterHook,
        LoopInGameThreadAfterFrames=LoopInGameThreadAfterFrames,
        LoopInGameThreadWithDelay=LoopInGameThreadWithDelay,CancelDelayedAction=CancelDelayedAction}
end
local instance
local initialized=false
local blocked_reason
local handle
local function create(module)
    if type(module)~='table' or type(module.new)~='function' then return false,'Invalid own module interface' end
    return pcall(module.new,make_api(),{log=log,status=status})
end
local function reload()
    return false,'Live module reload is disabled; restart Bodycam to load new mod files'
end
handle=LoopInGameThreadWithDelay(500,function()
    if not initialized then
        initialized=true
        local made,result=create(Module)
        if not made or type(result)~='table' then
            blocked_reason='Initialization failed: '..tostring(result):sub(1,180)
            status({phase='RELOAD_BLOCKED',reason=blocked_reason});log(blocked_reason)
        else instance=result;log('Z-Deathmatch 0.2.2 ready; 300-second match; private host menu / F10; 7 zombies per player, minimum 10, maximum 6 players and 42 zombies; host only, HUD off') end
    end
    local f=io.open(dir..'command.txt','rb')
    if not f then return end
    local command=f:read(128);f:close()
    if not command then return end
    command=command:match('^%s*(.-)%s*$')
    if command=='' then return end
    local clear=io.open(dir..'command.txt','wb');if clear then clear:close() else return end
    local ran,result,why
    if command=='reload' then ran,result,why=pcall(reload)
    elseif blocked_reason and command~='inspect' and command~='stop' then ran,result,why=true,false,blocked_reason
    elseif not instance then ran,result,why=true,false,'No initialized own module; restart Bodycam'
    else ran,result,why=pcall(instance.command,command) end
    log('Command '..command..': '..tostring(ran and result==true)..(why and ' | '..tostring(why) or ''))
    if not ran and instance then pcall(instance.stop,'Command callback failed: '..tostring(result):sub(1,180)) end
end)
