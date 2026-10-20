-- Original EndRound/EndMatch map vote; this module never selects a map or calls GI travel.
local M={}
local maps={'Airsoft','BombHouse','CQB','Hospital','Main_Trenches_Level_Design','Paintball','PublicPool','Rome','RussianBuilding','RussianBuilding_rs_hmika','TheBackrooms','WornHouse'}
local allowed={};for _,v in ipairs(maps)do allowed[v]=true end
local PLAY='Game.Phase.StartRound';local END='Game.Phase.EndRound';local MATCH='Game.Phase.EndMatch'
local function get(o,k)local ok,v=pcall(function()return o[k]end);if ok then return v end end
local function call(o,k,...)
 if o==nil then return false end
 local args=table.pack(...);local ok,f=pcall(function()return o[k]end)
 if ok and f~=nil then return pcall(f,o,table.unpack(args,1,args.n))end
 local read,mt=pcall(getmetatable,o);f=read and type(mt)=='table'and rawget(mt,k)
 if type(f)=='function'then return pcall(f,o,table.unpack(args,1,args.n))end
 return false
end
local function valid(o)local ok,v=call(o,'IsValid');return ok and v==true end
local function name(o)local ok,v=call(o,'GetFullName');return ok and type(v)=='string'and v or nil end
local function integer(v,a,b)return type(v)=='number'and v==v and v%1==0 and v>=a and v<=b end
local function id(o)local ok,v=call(o,'GetAddress');return ok and integer(v,1,math.maxinteger)and v or nil end
local function same(a,b)if not valid(a)or not valid(b)then return false end;if rawequal(a,b)then return true end;local x,y=id(a),id(b);return x~=nil and x==y end
local function world_map(w)local s=name(w)or '';local m=s:match('/GM_Maps/DeathMatch/DM_([%w_]+)%.')or s:match('/GM_Maps/DeathMatch/DM_([%w_]+)$');return allowed[m]and m or nil end
local function tag_text(t)local n=get(t,'TagName');if type(n)=='string'then return n end;local ok,v=call(n,'ToString');return ok and type(v)=='string'and v or nil end
function M.new(core,api,options)
 api,options=api or {},options or {}
 local self={};local started=false;local pending;local completed={};local retry=0
 local info={ready=false,pendingWorld=false,travel_requests=0,phase_requests=0,prepare_requests=0,installed_map_count=#maps,
  selection='native_map_vote',automatic_map_selection=false,connected_guests_preserved_by='GT_Base.CompleteVotingAndTravel',live_travel_verified=false,game_thread_only=true}
 local function log(s)if options.log then pcall(options.log,'[Z-Deathmatch Kartenwahl] '..tostring(s))end end
 local function now()if type(options.now)=='function'then return options.now()end;return os.time()end
 local function find(p)if type(api.StaticFindObject)~='function'then return nil end;local ok,v=pcall(api.StaticFindObject,p);return ok and valid(v)and v or nil end
 local gameplay=find('/Script/Engine.Default__GameplayStatics');local validity_cdo,validity_function
 local function alive(o)
  if o==nil then return false end
  if not valid(validity_cdo)then validity_cdo=find('/Script/Engine.Default__KismetSystemLibrary')end
  if not valid(validity_function)then validity_function=find('/Script/Engine.KismetSystemLibrary:IsValid')end
  if not valid(validity_cdo)or not valid(validity_function)then return false end
  local ok,v=call(validity_function,'CallFunction',validity_cdo,o);return ok and v==true
 end
 local function tag(s)local make=api.FName or FName;local ok,v=pcall(function()return make(s)end);return ok and v~=nil and {TagName=v}or nil end
 local function issue(s)info.error=s;log(s);return false,s end
 local function belongs(o,w)if not alive(o)then return false end;local ok,l=call(o,'GetLevel');local got,owner=call(l,'GetOuter');return ok and got and same(owner,w)end
 local function context(w,pawn_required)
  if not alive(w)or not id(w)then return nil,'World unavailable'end
  local got,list=pcall(api.FindAllOf,'GameViewportClient');local current=false
  if got and type(list)=='table'then for _,vp in ipairs(list)do if same(get(vp,'World'),w)then current=true;break end end end
  if not current then return nil,'The map is not the current viewport world'end
  local gm,gs=get(w,'AuthorityGameMode'),get(w,'GameState')
  if not alive(gm)or not alive(gs)or not id(gm)or not id(gs)or not belongs(gm,w)or not belongs(gs,w)then return nil,'Current native authority objects unavailable'end
  local a,ga=call(gm,'HasAuthority');local b,sa=call(gs,'HasAuthority')
  if not a or ga~=true or not b or sa~=true then return nil,'Host authority is required'end
  local ok,pc=pcall(core.get_controller)
  if not ok or not alive(pc)or not belongs(pc,w)then return nil,'The current local host controller is unavailable'end
  local a,authority=call(pc,'HasAuthority');local b,local_pc=call(pc,'IsLocalController')
  if not a or authority~=true or not b or local_pc~=true or not alive(get(pc,'PlayerState'))then return nil,'Current authoritative local host required'end
  if pawn_required then local read,pawn=call(pc,'K2_GetPawn');if not read or not alive(pawn)then return nil,'The next-map host pawn is not ready'end end
  local read,n=call(gameplay,'GetNumPlayerControllers',w);if not read or not integer(n,1,6)then return nil,'Native one-to-six player roster unavailable'end
  local read,gi=call(gameplay,'GetGameInstance',w)
  if not read or not alive(gi)or get(gi,'Gamemode')~=2 or get(gi,'Session Max Players')~=6 then return nil,'The mode2 six-player host session is not verified'end
  return {gm=gm,gs=gs,world_id=id(w),gs_id=id(gs)}
 end
 local function phase(gs)local ok,t=call(gs,'GetCurrentPhase');local p=ok and tag_text(t)or nil;if p and tag_text(get(gs,'CurrentPhase'))==p then return p end end
 local function end_gates(c)
  local t=tag('UI.EndPlay.MapVote');if not t then return nil,'Native FName constructor unavailable'end
  local lib=find('/Script/GameplayTags.Default__BlueprintGameplayTagLibrary')
  local tags=get(get(c.gs,'GamemodeUIData'),'EndGameTabs_45_E1C78F2B43BFBA40A7E27290A64036EC')
  local read,v=call(lib,'HasTag',tags,t,false)
  if not read or v~=true then return nil,'The original standard map-vote tab is not verified'end
  local a,max=call(c.gs,'GetMaxRound');local b,round=call(c.gs,'GetCurrentRound')
  if not a or max~=1 or not b or not integer(round,0,math.maxinteger)then return nil,'The restored original one-round configuration is not verified'end
  local p=phase(c.gs);if p~=PLAY and p~=END and p~=MATCH then return nil,'The native phase is not ready for its standard match ending'end
  return p
 end
 local function arrived(w,c)
  info.pendingWorld=false;info.arrived_world=name(w);info.arrived_world_id=c.world_id;info.arrived_game_state_id=c.gs_id
  info.error=nil;pending=nil
 end
 function self.start()
  if started then return true end
  if not valid(gameplay)or type(core.get_controller)~='function'or type(api.FindAllOf)~='function'then return false end
  started=true;info.ready=true;return true
 end
 function self.tick(s,w)
  if not started then return false end
  if type(s)~='table'or not alive(w)then return true end
  local wn,wi=name(w),id(w);if not wn or not wi then return true end
  if s.mode_name~='Z-Deathmatch'then
   if pending then pending=nil;info.pendingWorld=false;info.cancelled=true;return issue('The owning Z-Deathmatch round is no longer present')end
   return true
  end
  if pending then
   -- Only scalar source identities survive. The world is supplied afresh by controls.
   local lower=wn:lower()
   if lower:find('/lobby',1,true)or lower:find('mainmenu',1,true)then
    pending=nil;info.pendingWorld=false;info.cancelled=true;info.warning='Returned to a menu; no automatic round is started';return true
   end
   if now()>pending.warn_at and not info.vote_wait_warning then info.vote_wait_warning='Waiting for the original map vote or selected map; no automatic travel is requested';log(info.vote_wait_warning)end
   local gs=get(w,'GameState');local gi=alive(gs)and id(gs)or nil
   if wi==pending.source_world_id and (not gi or gi==pending.source_gs_id)then return true end
   if not world_map(w)then return true end
   local c,why=context(w,true);if not c then info.waiting_for_host=why;return true end
   info.waiting_for_host=nil
   if c.world_id==pending.source_world_id and c.gs_id==pending.source_gs_id then return true end
   if (s.phase=='PREMATCH'or s.phase=='RUNNING')and s.world==wn then arrived(w,c);return true end
   if now()<pending.next_prepare then return true end
   if type(core.prepare)~='function'then return issue('Thirty-second preparation API unavailable')end
   if pending.prepare_attempts>=30 then info.warning='The chosen map is loaded but preparation is unavailable; no automatic travel is requested';return true end
   pending.next_prepare=now()+1;pending.prepare_attempts=pending.prepare_attempts+1
   local ok,result,why=pcall(core.prepare);info.prepare_requests=info.prepare_requests+1
   if ok and result==true then arrived(w,c);log('Selected map ready; thirty-second preparation requested');return true end
   info.waiting_for_host='Next-map preparation: '..tostring(why or result):sub(1,180);return true
  end
  if s.phase~='FINISHED'then return true end
  local r=s.final_result;if type(r)~='table'or r.completed~=true or r.reason~='time_limit'then return true end
  if s.cleanup_pending~=0 or s.cleanup_failed~=0 or s.active~=0 then info.waiting_for_cleanup=true;return true end
  info.waiting_for_cleanup=false
  if not world_map(w)or s.world~=wn then return true end
  local gs=get(w,'GameState');local si=alive(gs)and id(gs)or nil;if not si then return true end
  local token=tostring(wi)..'|'..tostring(si)..'|'..tostring(s.started_at or '')..'|'..tostring(r.finished_at or s.deadline or '')
  if completed[token]then return true end
  local c,why=context(w,false);if not c then info.waiting_for_host=why;return true end
  info.waiting_for_host=nil
  if now()<retry then return true end;retry=now()+1
  if type(options.before_travel)=='function'then
   local ok,ready,why=pcall(options.before_travel,s,w)
   if not ok or ready~=true then info.waiting_for_adapter_cleanup=true;return issue('Pre-vote cleanup refused: '..tostring(why or ready):sub(1,180))end
  end
  info.waiting_for_adapter_cleanup=false
  -- Restore original team/score rules before checking the native end conditions.
  completed[token]=true;pending={source_world_id=wi,source_gs_id=c.gs_id,warn_at=now()+600,next_prepare=0,prepare_attempts=0}
  info.pendingWorld=true;info.cancelled=false;info.source_world=wn;info.source_world_id=wi;info.source_game_state_id=c.gs_id
  info.arrived_world=nil;info.arrived_world_id=nil;info.arrived_game_state_id=nil;info.vote_wait_warning=nil;info.warning=nil;info.error=nil
  local fresh,why=context(w,false)
  if not fresh or fresh.world_id~=wi or fresh.gs_id~=c.gs_id then return issue(why or 'Native authority changed during pre-vote cleanup')end
  local p,why=end_gates(fresh);if not p then return issue(why)end
  info.native_phase=p;info.original_map_vote_verified=true;info.original_max_round=1
  if p==END or p==MATCH then info.handoff_source='observed_native_match_ending';return true end
  local fn=find('/Script/Bodycam.BodycamGameMode:RequestPhaseChange');local t=tag(END)
  if not fn or not t then return issue('The native EndRound request API is unavailable')end
  -- One attempted native mutation per completed round, even when it fails.
  info.phase_requests=info.phase_requests+1
  local ok,why=call(fn,'CallFunction',fresh.gm,t);local actual=phase(fresh.gs);info.native_phase=actual
  if actual~=END and actual~=MATCH then return issue('Native EndRound did not verify: '..tostring(why or ok):sub(1,160))end
  info.handoff_source='native_end_round_request';info.native_request_call_ok=ok
  log('Cleanup complete; the game handles its standard map vote');return true
 end
 function self.shutdown()started=false;pending=nil;info.pendingWorld=false;info.ready=false;return true end
 function self.status()return info end
 return self
end
return M
