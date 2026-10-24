#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#include "MinHook.h"
#include "score_filter.h"
#include "xp_gate.h"
#include "reward_policy.h"
#include "build_pin.h"

/* A single cold-start Lua C function. Uses the already-loaded UE4SS Lua core;
 * never links a second Lua runtime or looks up process-global Lua state. */
typedef struct lua_State lua_State;
typedef int (*LuaTop)(lua_State*);
typedef int64_t (*LuaInt)(lua_State*,int,int*);
typedef void (*LuaPushInt)(lua_State*,int64_t);
typedef const char* (*LuaPushString)(lua_State*,const char*,size_t);
typedef struct Weak {int32_t index,serial;} Weak;
typedef void* (*WeakCtor)(Weak*,const void*);
typedef void* (*WeakGet)(const Weak*,unsigned char);
typedef int32_t (*ObjectIndex)(const void*);
typedef void* (*IndexObject)(int32_t);
typedef void* (*ItemObject)(const void*);
typedef void* (*ObjectWorld)(const void*);
typedef unsigned char (*ObjectIsA)(const void*,const void*);
typedef void (*KillFn)(void*,void*,void*);
typedef int32_t (*NativeInt)(void*);
typedef unsigned char (*NativeBool)(void*);
typedef int32_t (*NativeTeamPoint)(void*,int32_t);
typedef void (*NativePhase)(void*,uint64_t);
static NativeInt native_team_id,native_score_limit;
static NativeBool native_team_based;
static NativeTeamPoint native_team_point;
static NativePhase native_request_phase;
static int component_owner_layout_verified;
static const uint64_t *round_active_tag,*round_end_tag;
static BzObjectId state_class,player_state_class,score_rule_class,score_rule;
static BzRewardState rewards;
static unsigned long long reward_deaths,reward_points,reward_duplicates,reward_rejected,reward_retired;
static LuaTop ltop;static LuaInt lint;static LuaPushInt lpush;static LuaPushString lstring;
static WeakCtor weak_ctor;static WeakGet weak_get;static ObjectIndex object_index;
static IndexObject index_object;static ItemObject item_object;static ObjectWorld object_world;static ObjectIsA object_isa;
static KillFn original[5];static void* hook_targets[5];
static KillFn original_script;static void* script_target;static BzXpAccessors frames;
static BzObjectId kill_function, zombie_ubergraph;static int script_installed;
static uintptr_t ue4ss_base,game_base;
static BzScoreOwned owned[BZ_SCORE_MAX_OWNED];static size_t owned_count;
static BzObjectId world_id,gm_id,ai_class,player_class;
static uint64_t epoch;static _Atomic(DWORD) game_thread;static int active,installed,attempted;
static unsigned long long suppressed[5];static char failure[192]="Not initialized";
static unsigned long long suppressed_xp;
static int on_game_thread(void){return GetCurrentThreadId()==atomic_load_explicit(&game_thread,memory_order_acquire);}
static int bind_game_thread(void){
    DWORD expected=0,current=GetCurrentThreadId();
    return atomic_compare_exchange_strong_explicit(&game_thread,&expected,current,memory_order_acq_rel,memory_order_acquire)||expected==current;
}

static int readable(const void* p,size_t n){
    MEMORY_BASIC_INFORMATION m;uintptr_t a=(uintptr_t)p,end=a+n,next;
    if(!p || end<a)return 0;
    while(a<end){
        if(!VirtualQuery((void*)a,&m,sizeof m)||m.State!=MEM_COMMIT||(m.Protect&(PAGE_NOACCESS|PAGE_GUARD))||
           !(m.Protect&(PAGE_READONLY|PAGE_READWRITE|PAGE_WRITECOPY|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY)))return 0;
        next=(uintptr_t)m.BaseAddress+m.RegionSize;if(next<=a)return 0;a=next;
    }
    return 1;
}
static void* resolve(BzObjectId id);
static int read_memory(const void* address,void* out,size_t n){if(!out||!readable(address,n))return 0;memcpy(out,address,n);return 1;}
static int xp_ready(void){return script_installed&&resolve(kill_function)&&resolve(zombie_ubergraph)&&bz_xp_runtime_ready((void*)ue4ss_base,(void*)game_base,read_memory);}
static int hash_module(HMODULE module,const char* expected){
    wchar_t path[32768];HANDLE file=INVALID_HANDLE_VALUE;BCRYPT_ALG_HANDLE alg=NULL;BCRYPT_HASH_HANDLE hash=NULL;
    unsigned char buf[65536],digest[32];DWORD n=0;char hex[65];int ok=0;
    if(!module || !GetModuleFileNameW(module,path,32768))goto done;
    file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(file==INVALID_HANDLE_VALUE || BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,NULL,0)<0 || BCryptCreateHash(alg,&hash,NULL,0,NULL,0,0)<0)goto done;
    for(;;){if(!ReadFile(file,buf,sizeof buf,&n,NULL))goto done;if(!n)break;if(BCryptHashData(hash,buf,n,0)<0)goto done;}
    if(BCryptFinishHash(hash,digest,32,0)<0)goto done;
    for(n=0;n<32;n++)sprintf(hex+2*n,"%02x",digest[n]);hex[64]=0;ok=strcmp(hex,expected)==0;
done:if(hash)BCryptDestroyHash(hash);if(alg)BCryptCloseAlgorithmProvider(alg,0);if(file!=INVALID_HANDLE_VALUE)CloseHandle(file);return ok;
}
static BzObjectId capture_identity(void* p,unsigned char allow_pending){
    BzObjectId id={0};Weak w;int32_t index;void* item;
    if(!readable(p,0x28))return id;
    index=object_index(p);if(index<0 || !(item=index_object(index)) || item_object(item)!=p)return id;
    weak_ctor(&w,p);
    /* Runtime verification of weak layout, including pending-kill rejection. */
    if(w.index!=index || w.serial<=0 || weak_get(&w,allow_pending)!=p)return id;
    id.address=(uintptr_t)p;id.object_index=w.index;id.serial=w.serial;return id;
}
static BzObjectId capture(void* p){return capture_identity(p,0);}
static void* resolve(BzObjectId id){
    Weak w={id.object_index,id.serial};void* p;
    if(!id.address || id.serial<=0 || id.object_index<0)return NULL;
    p=weak_get(&w,0);return (uintptr_t)p==id.address?p:NULL;
}
static int context_ok(void){
    void* w;void* gm;
    if(!on_game_thread() || !active || !epoch)return 0;
    w=resolve(world_id);gm=resolve(gm_id);
    return w && gm && readable(w,0x160) && readable(gm,0x169) &&
        *(void**)((char*)w+0x158)==gm && *(unsigned char*)((char*)gm+0x168)==3 && object_world(gm)==w;
}
static int owned_boundary(unsigned boundary,void* receiver,void* victim){
    BzScoreEvent event={0};void* pawn;void* pc;void* ac;BzObjectId receiver_id;
    size_t i;
    if(!on_game_thread() || !owned_count || !victim || !context_ok())return 0;
    receiver_id=capture(receiver);if(!receiver_id.address || object_world(receiver)!=(void*)world_id.address)return 0;
    if(boundary==1 && !bz_score_id_equal(receiver_id,gm_id))return 0;
    event.victim_controller=capture(victim);if(!event.victim_controller.address || !readable(victim,0x2f0))return 0;
    pc=resolve(player_class);ac=resolve(ai_class);if(!pc||!ac)return 0;
    if(object_isa(victim,pc) || !object_isa(victim,ac))return 0;
    if(object_world(victim)!=(void*)world_id.address)return 0;
    /* A native death callback can retain its Pawn while PendingKill is set.
     * Read only the object-array identity; never call a method on that pawn.
     * The policy still requires an exact registered weak index AND serial. */
    pawn=*(void**)((char*)victim+0x2e8);event.victim_pawn=capture_identity(pawn,1);
    event.victim_pawn_is_live=event.victim_pawn.address!=0;
    if(pawn && !event.victim_pawn.address)event.victim_pawn.address=(uintptr_t)pawn;
    event.boundary=boundary;event.variant_active=event.authority=event.game_thread=1;event.epoch=epoch;
    event.world=world_id;event.authority_game_mode=gm_id;event.victim_controller_is_live=1;
    for(i=0;i<owned_count;i++)if(bz_score_should_suppress(&owned[i],1,&event))return (int)i+1;
    return 0;
}
static int filter(unsigned boundary,void* receiver,void* victim){return owned_boundary(boundary,receiver,victim)!=0;}
static int reward_ready(void){
    return native_team_id&&native_score_limit&&native_team_based&&native_team_point&&native_request_phase&&component_owner_layout_verified&&
        resolve(state_class)&&resolve(player_state_class)&&resolve(score_rule_class)&&readable(round_active_tag,8)&&readable(round_end_tag,8)&&
        *round_active_tag && *round_end_tag && *round_active_tag!=*round_end_tag;
}
typedef struct TeamData {int32_t id,score,players;} TeamData;
typedef struct NativeArray {void* data;int32_t count,capacity;} NativeArray;
static int read_array(void* object,size_t offset,size_t stride,NativeArray* out){
    return read_memory((char*)object+offset,out,sizeof *out)&&out->count>=0&&out->count<=256&&
        out->capacity>=out->count&&(out->count==0||readable(out->data,(size_t)out->count*stride));
}
static TeamData* team_data(void* gs,int32_t team){
    NativeArray a;int i;if(!read_array(gs,0x3c0,sizeof(TeamData),&a))return NULL;
    for(i=0;i<a.count;i++)if(((TeamData*)a.data)[i].id==team)return &((TeamData*)a.data)[i];
    return NULL;
}
static int player_in_roster(void* gs,void* ps){
    NativeArray a;int i;if(!read_array(gs,0x2c0,sizeof(void*),&a))return 0;
    for(i=0;i<a.count;i++)if(((void**)a.data)[i]==ps)return 1;
    return 0;
}
static const char* reward_mode_error(void){
    void *r=resolve(score_rule),*gm=resolve(gm_id),*cls=resolve(score_rule_class),*owner=NULL;
    if(!r)return "Score-limit rule identity unavailable";
    if(!gm||!cls)return "GameMode or score-rule class identity unavailable";
    if(!object_isa(r,cls))return "Score-limit rule class mismatch";
    if(object_world(r)!=(void*)world_id.address)return "Score-limit rule world mismatch";
    /* ActorComponent.execGetOwner at the pinned 0x143736310 reads +0x90.
     * +0x98 is CachedWorld; 0x143710d20 is GetWorld, not GetOwner. Never invoke
     * a UFunction exec thunk as a one-argument native getter (FFrame/OUT ABI). */
    if(!component_owner_layout_verified||!read_memory((char*)r+0x90,&owner,sizeof owner))return "Score-limit rule owner unreadable";
    if(owner!=gm)return "Score-limit rule owner is not the authority GameMode";
    return NULL;
}
static int reward_mode_supported(void){return reward_mode_error()==NULL;}
/* The heartbeat and both death detours share this native, current-phase check.
 * No Lua-cached prematch flag can leak fifths into a later round. */
static void* reward_context(void){
    void *w,*gm,*gs;BzRewardScope scope={0};size_t i;int team_based;
    if(!context_ok()||!reward_ready()||!reward_mode_supported())goto unavailable;
    w=resolve(world_id);gm=resolve(gm_id);
    if(!readable(w,0x168)||!readable(gm,0x310))goto unavailable;
    gs=*(void**)((char*)w+0x160);
    scope.game_state=capture(gs);
    if(!scope.game_state.address||!object_isa(gs,resolve(state_class))||object_world(gs)!=w||
       !readable(gs,0x3e8)||*(unsigned char*)((char*)gs+0x168)!=3||*(void**)((char*)gm+0x308)!=gs||
       *(uint64_t*)((char*)gs+0x3b0)!=*round_active_tag)goto unavailable;
    scope.active=1;scope.round=*(int32_t*)((char*)gs+0x3b8);
    scope.round_start=*(uint64_t*)((char*)gs+0x3d0);
    bz_reward_sync(&rewards,scope);team_based=native_team_based(gs)!=0;
    for(i=0;i<BZ_SCORE_MAX_OWNED;i++){
        BzRewardTeam* b=&rewards.teams[i];void* ps;TeamData* t;
        if(!b->occupied)continue;
        t=team_data(gs,b->team);
        if(!t||t->players<=0){memset(b,0,sizeof *b);continue;}
        if(team_based){if(!bz_score_id_equal(b->identity,scope.game_state))memset(b,0,sizeof *b);}
        else {ps=resolve(b->identity);if(!ps||!object_isa(ps,resolve(player_state_class))||
            !player_in_roster(gs,ps)||native_team_id(ps)!=b->team)memset(b,0,sizeof *b);}
    }
    return gs;
unavailable:bz_reward_reset(&rewards);return NULL;
}
/* Caller has already established an exact registered death route. Mark first,
 * even during warmup or with an invalid killer: a later duplicate is not a new
 * kill. Neither a corpse nor a round change can re-arm this pawn. */
static void reward_death(size_t index,void* killer){
    BzScoreOwned *row;void *gs,*ps,*gm;BzObjectId killer_id,ps_id;BzRewardScope scope;
    TeamData* team;int32_t id,before,after,limit;int shared;size_t i;
    if(!on_game_thread()||index>=owned_count)return;
    row=&owned[index];
    if(row->reward_retired){reward_retired++;return;}
    if(row->death_observed){reward_duplicates++;return;}
    row->death_observed=1;
    gs=reward_context();if(!gs){reward_rejected++;return;}
    killer_id=capture(killer);
    if(!killer_id.address||object_world(killer)!=(void*)world_id.address||!readable(killer,0x2f0))goto rejected;
    /* Native score rules consume the killer's BodycamPlayerState, including
     * combatant bots. A zombie/foreign AI cannot invent a credited team. */
    ps=*(void**)((char*)killer+0x2b0);ps_id=capture(ps);
    if(!ps_id.address||!object_isa(ps,resolve(player_state_class))||object_world(ps)!=(void*)world_id.address||
       !readable(ps,0x160)||*(void**)((char*)ps+0x158)!=killer||!player_in_roster(gs,ps))goto rejected;
    for(i=0;i<owned_count;i++)if(bz_score_id_equal(owned[i].controller,killer_id))goto rejected;
    id=native_team_id(ps);team=team_data(gs,id);
    if(id<0||!team||team->players<=0||team->score==INT32_MAX)goto rejected;
    scope=rewards.scope;shared=native_team_based(gs)!=0;
    reward_deaths++;
    if(!bz_reward_add(&rewards,id,shared?scope.game_state:ps_id))return;
    before=team->score;after=native_team_point(gs,id);
    if(after!=before+1){reward_rejected++;return;}
    reward_points++;
    /* Increment broadcasts OnTeamsChanged and may re-enter game logic. Recheck
     * identities/round before using any receiver or requesting its completion. */
    if(reward_context()!=gs||!bz_score_id_equal(rewards.scope.game_state,scope.game_state)||
       rewards.scope.round!=scope.round||rewards.scope.round_start!=scope.round_start)return;
    gm=resolve(gm_id);limit=native_score_limit(gs);
    if(gm&&after>=limit)native_request_phase(gm,*round_end_tag);
    return;
rejected:reward_rejected++;
}
typedef struct XpDeath {size_t index;void* killer;int found;} XpDeath;
static int owned_xp(void* source,void* reward,void* user){
    BzObjectId source_id,reward_id;void* pc;size_t i;
    if(!context_ok())return 0;
    source_id=capture_identity(source,1);reward_id=capture(reward);pc=resolve(player_class);
    if(!source_id.address||!reward_id.address||!pc||!object_isa(reward,pc)||object_world(reward)!=(void*)world_id.address)return 0;
    for(i=0;i<owned_count;i++)if(owned[i].enabled && owned[i].owner_tag==BZ_SCORE_OWNER_TAG && owned[i].epoch==epoch &&
        bz_score_id_equal(owned[i].world,world_id)&&bz_score_id_equal(owned[i].authority_game_mode,gm_id)&&bz_score_id_equal(owned[i].pawn,source_id)){
        if(user)*(XpDeath*)user=(XpDeath){i,reward,1};return 1;
    }
    return 0;
}
static void script_detour(void* context,void* frame,void* result){
    XpDeath death={0};
    void** node;
    /* This detour sees every Blueprint script, not just zombie deaths. Reject
     * unrelated nodes before any UObject-array/weak lookup. This compares an
     * address only; exact serial/identity validation still happens on a match.
     * A reused or expired UFunction can therefore never become an XP match. */
    if(on_game_thread() && active && owned_count && frame && frames.node && kill_function.address &&
        (node=frames.node(frame))!=NULL && (uintptr_t)*node==kill_function.address &&
        bz_xp_should_suppress(&frames,context,frame,
        resolve(kill_function),resolve(zombie_ubergraph),owned_xp,&death)){
        suppressed_xp++;if(death.found)reward_death(death.index,death.killer);return;
    }
    original_script(context,frame,result);
}
static void* find_export(void* module,const char* name){return (void*)GetProcAddress((HMODULE)module,name);}
#define DETOUR(n) static void detour##n(void* r,void* k,void* v){int row=owned_boundary(n+1,r,v);if(row){suppressed[n]++;if(n==0)reward_death((size_t)(row-1),k);return;}original[n](r,k,v);}
DETOUR(0) DETOUR(1) DETOUR(2) DETOUR(3) DETOUR(4)
static void reset_registry(void){active=0;owned_count=0;epoch=0;bz_reward_reset(&rewards);memset(owned,0,sizeof owned);memset(&world_id,0,sizeof world_id);memset(&gm_id,0,sizeof gm_id);memset(&score_rule,0,sizeof score_rule);}
static int init_lua(void){
    HMODULE u=GetModuleHandleW(L"UE4SS.dll");unsigned char* p=(unsigned char*)u;
    if(lpush)return 1;
    if(!hash_module(u,BZ_UE4SS_HASH))return 0;
#define LUA_BIND(name,type,var) if(memcmp(p+BZ_LUA_##name##_RVA,bz_lua_##var##_bytes,16))return 0;
    if(memcmp(p+BZ_LUA_GETTOP_RVA,bz_lua_gettop_bytes,16) || memcmp(p+BZ_LUA_TOINTEGERX_RVA,bz_lua_tointegerx_bytes,16) || memcmp(p+BZ_LUA_PUSHINTEGER_RVA,bz_lua_pushinteger_bytes,16) || memcmp(p+BZ_LUA_PUSHLSTRING_RVA,bz_lua_pushlstring_bytes,16))return 0;
    ltop=(LuaTop)(p+BZ_LUA_GETTOP_RVA);lint=(LuaInt)(p+BZ_LUA_TOINTEGERX_RVA);lpush=(LuaPushInt)(p+BZ_LUA_PUSHINTEGER_RVA);lstring=(LuaPushString)(p+BZ_LUA_PUSHLSTRING_RVA);return 1;
}
static int initialize(void){
    HMODULE u=GetModuleHandleW(L"UE4SS.dll"), exe=GetModuleHandleW(NULL), self;int i,created=0,xp_created=0;MH_STATUS status;
    void* detours[5]={(void*)detour0,(void*)detour1,(void*)detour2,(void*)detour3,(void*)detour4};
    if(attempted)return installed;attempted=1;
    ue4ss_base=(uintptr_t)u;game_base=(uintptr_t)exe;
    if(!hash_module(exe,BZ_EXE_HASH)){strcpy(failure,"Unsupported Bodycam executable hash");return 0;}
#define LOAD(var,type,name) {FARPROC proc=GetProcAddress(u,name);_Static_assert(sizeof(var)==sizeof(proc),"Win64 pointer ABI");memcpy(&var,&proc,sizeof(var));if(!var){strcpy(failure,"Required UE4SS native export missing");return 0;}}
    LOAD(weak_ctor,WeakCtor,"??0FWeakObjectPtr@Unreal@RC@@QEAA@PEBVUObject@12@@Z")
    LOAD(weak_get,WeakGet,"?Get@FWeakObjectPtr@Unreal@RC@@QEBAPEAVUObject@23@_N@Z")
    LOAD(object_index,ObjectIndex,"?GetInternalIndex@UObjectBase@Unreal@RC@@QEBA?BHXZ")
    LOAD(index_object,IndexObject,"?IndexToObject@FUObjectArray@Unreal@RC@@SAPEAUFUObjectItem@23@H@Z")
    LOAD(item_object,ItemObject,"?GetUObject@FUObjectItem@Unreal@RC@@QEBAPEAVUObject@23@XZ")
    LOAD(object_world,ObjectWorld,"?GetWorld@UObject@Unreal@RC@@QEBAPEAVUWorld@23@XZ")
    LOAD(object_isa,ObjectIsA,"?IsA@UObjectBase@Unreal@RC@@QEBA_NPEBVUClass@23@@Z")
    for(i=0;i<5;i++){hook_targets[i]=(char*)exe+bz_hook_rvas[i];if(memcmp(hook_targets[i],bz_hook_bytes[i],32)){strcpy(failure,"Native boundary bytes changed");return 0;}}
#define REWARD_BIND(name,type) if(memcmp((char*)exe+BZ_REWARD_##name##_RVA,bz_reward_##type##_bytes,32)){strcpy(failure,"Native reward boundary bytes changed");return 0;}
    REWARD_BIND(TEAM_POINT,team_point) REWARD_BIND(SCORE_LIMIT,score_limit)
    REWARD_BIND(REQUEST_PHASE,request_phase) REWARD_BIND(TEAM_ID,team_id) REWARD_BIND(TEAM_BASED,team_based)
    REWARD_BIND(COMPONENT_OWNER,component_owner)
    native_team_point=(NativeTeamPoint)((char*)exe+BZ_REWARD_TEAM_POINT_RVA);
    native_score_limit=(NativeInt)((char*)exe+BZ_REWARD_SCORE_LIMIT_RVA);
    native_request_phase=(NativePhase)((char*)exe+BZ_REWARD_REQUEST_PHASE_RVA);
    native_team_id=(NativeInt)((char*)exe+BZ_REWARD_TEAM_ID_RVA);
    native_team_based=(NativeBool)((char*)exe+BZ_REWARD_TEAM_BASED_RVA);
    component_owner_layout_verified=1;
    round_active_tag=(const uint64_t*)((char*)exe+BZ_REWARD_START_ROUND_TAG_RVA);
    round_end_tag=(const uint64_t*)((char*)exe+BZ_REWARD_END_ROUND_TAG_RVA);
    script_target=(char*)u+BZ_XP_UE4SS_DISPATCH_RVA;
    if(memcmp(script_target,bz_xp_dispatch_prologue,32)||!bz_xp_resolve(&frames,u,find_export)){strcpy(failure,"Native Blueprint dispatch boundary unavailable");return 0;}
    status=MH_Initialize();if(status!=MH_OK){strcpy(failure,"Private detour engine initialization failed");return 0;}
    for(i=0;i<5;i++){if(MH_CreateHook(hook_targets[i],detours[i],(void**)&original[i])!=MH_OK)goto failed;created++;}
    if(MH_CreateHook(script_target,(void*)script_detour,(void**)&original_script)!=MH_OK)goto failed;xp_created=1;
    /* Pin before exposing callbacks so Lua shutdown cannot unload active code. */
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,(LPCWSTR)(uintptr_t)&initialize,&self))goto failed;
    for(i=0;i<5;i++)if(MH_QueueEnableHook(hook_targets[i])!=MH_OK)goto failed;
    if(MH_QueueEnableHook(script_target)!=MH_OK)goto failed;
    if(MH_ApplyQueued()!=MH_OK)goto failed;
    script_installed=1;installed=1;strcpy(failure,"Ready");return 1;
failed:
    if(xp_created){MH_DisableHook(script_target);MH_RemoveHook(script_target);}
    for(i=0;i<created;i++)MH_DisableHook(hook_targets[i]);
    for(i=0;i<created;i++)MH_RemoveHook(hook_targets[i]);
    MH_Uninitialize();strcpy(failure,"Native detours could not be installed atomically");return 0;
}
static int64_t arg(lua_State* L,int index){int numeric=0;int64_t v;if(index>ltop(L))return 0;v=lint(L,index,&numeric);return numeric?v:0;}
__declspec(dllexport) int bodycam_bridge_call(lua_State* L){
    int op,ok=0;size_t i;BzObjectId p,c;void* w;void* gm;uint64_t requested;
    const char* activation_error="World or GameMode authority relationship mismatch";
    /* Bootstrap calls this from LoopInGameThreadWithDelay. Publish that owner
     * once; other Lua/native threads return before touching mutable state. */
    if(!bind_game_thread())return 0;
    if(!init_lua())return 0;
    op=(int)arg(L,1);
    if(!initialize()){lpush(L,0);lstring(L,failure,strlen(failure));return 2;}
    if(op==20){lpush(L,5|(active?8:0)|(xp_ready()?2:0)|(reward_ready()?16:0));lstring(L,failure,strlen(failure));return 2;}
    if(op==21){
        requested=(uint64_t)arg(L,4);w=(void*)(uintptr_t)arg(L,2);gm=(void*)(uintptr_t)arg(L,3);
        p=capture(w);c=capture(gm);
        if(p.address && c.address && requested && readable(w,0x160) && readable(gm,0x169) && *(void**)((char*)w+0x158)==gm && *(unsigned char*)((char*)gm+0x168)==3 && object_world(gm)==w){
            BzObjectId ac=capture((void*)(uintptr_t)arg(L,5)),pc=capture((void*)(uintptr_t)arg(L,6));
            activation_error="Controller class identities unavailable";
            if(ac.address && pc.address){
                if(!bz_score_id_equal(world_id,p)||!bz_score_id_equal(gm_id,c)||epoch!=requested)reset_registry();
                world_id=p;gm_id=c;ai_class=ac;player_class=pc;epoch=requested;active=1;
                score_rule=capture((void*)(uintptr_t)arg(L,7));
                activation_error=arg(L,7)?reward_mode_error():NULL;
                if(activation_error){reset_registry();ok=0;}else ok=1;
            }
        }
    }else if(op==22 && context_ok()){
        p=capture((void*)(uintptr_t)arg(L,2));c=capture((void*)(uintptr_t)arg(L,3));requested=(uint64_t)arg(L,4);
        if(requested==epoch && p.address && object_world((void*)p.address)==(void*)world_id.address &&
           (!arg(L,3)||(c.address && object_isa((void*)c.address,resolve(ai_class)) && !object_isa((void*)c.address,resolve(player_class)) && object_world((void*)c.address)==(void*)world_id.address && readable((void*)c.address,0x2f0) && *(void**)(c.address+0x2e8)==(void*)p.address))){
            for(i=0;i<owned_count;i++)if(bz_score_id_equal(owned[i].pawn,p))break;
            if(i<owned_count || owned_count<BZ_SCORE_MAX_OWNED){
                if(i==owned_count){owned_count++;owned[i]=(BzScoreOwned){BZ_SCORE_OWNER_TAG,1,epoch,world_id,gm_id,p,c,0,0};}
                else if(c.address)owned[i].controller=c;
                /* Rebinding must not re-arm a dead/retired pawn. */
                ok=1;
            }
        }
    }else if(op==23 && (uint64_t)arg(L,3)==epoch){
        uintptr_t address=(uintptr_t)arg(L,2);for(i=0;i<owned_count;i++)if(owned[i].pawn.address==address){owned[i]=owned[--owned_count];memset(&owned[owned_count],0,sizeof owned[0]);break;}ok=1;
    }else if(op==24){reset_registry();ok=1;}
    else if(op==25){ok=context_ok();if(ok)reward_context();}
    else if(op==26 && script_installed){p=capture((void*)(uintptr_t)arg(L,2));c=capture((void*)(uintptr_t)arg(L,3));if(p.address&&c.address&&!bz_score_id_equal(p,c)){kill_function=p;zombie_ubergraph=c;ok=1;}}
    else if(op==27){for(i=0;i<5;i++)lpush(L,(int64_t)suppressed[i]);lpush(L,(int64_t)owned_count);lpush(L,(int64_t)suppressed_xp);return 7;}
    else if(op==28){
        BzObjectId rule=capture((void*)(uintptr_t)arg(L,4));p=capture((void*)(uintptr_t)arg(L,2));c=capture((void*)(uintptr_t)arg(L,3));
        if(p.address&&c.address&&rule.address&&!bz_score_id_equal(p,c)&&!bz_score_id_equal(p,rule)&&!bz_score_id_equal(c,rule)){
            player_state_class=p;state_class=c;score_rule_class=rule;ok=reward_ready();
        }
    }
    else if(op==29 && (uint64_t)arg(L,3)==epoch){
        uintptr_t address=(uintptr_t)arg(L,2);for(i=0;i<owned_count;i++)if(owned[i].pawn.address==address){owned[i].reward_retired=1;break;}ok=1;
    }else if(op==30){
        unsigned remaining=0,teams=0;for(i=0;i<BZ_SCORE_MAX_OWNED;i++)if(rewards.teams[i].occupied){remaining+=rewards.teams[i].remainder;teams++;}
        lpush(L,(int64_t)reward_deaths);lpush(L,(int64_t)reward_points);lpush(L,(int64_t)reward_duplicates);
        lpush(L,(int64_t)reward_rejected);lpush(L,(int64_t)reward_retired);lpush(L,remaining);lpush(L,teams);
        lpush(L,active?reward_mode_supported():-1);return 8;
    }
    lpush(L,ok);
    if(op==21&&!ok){lstring(L,activation_error,strlen(activation_error));return 2;}
    return 1;
}
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,LPVOID reserved){(void)reserved;if(reason==DLL_PROCESS_ATTACH)DisableThreadLibraryCalls(module);return TRUE;}
