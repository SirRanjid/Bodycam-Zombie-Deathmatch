/* Runs in its own process. No Bodycam/UE4SS module is loaded or accessed. */
#include "native_bridge.c"
#include <stdlib.h>
struct lua_State {int64_t args[12],results[12];int argc,resultc;char message[192];};
typedef struct Obj {unsigned char bytes[0x800];void* world;int index,serial,alive,type,pending;} Obj;
typedef struct Frame {void* node;void* object;struct Frame* previous;} Frame;
static Obj objects[32];static volatile int calls[5];static int checks;
static volatile int script_calls;
static unsigned long long weak_reads,frame_node_reads;
static unsigned char script_entry[32];
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,#x);exit(1);}}while(0)
static int top(lua_State* L){return L->argc;}
static int64_t integer(lua_State* L,int n,int* ok){*ok=1;return L->args[n-1];}
static void push(lua_State* L,int64_t n){L->results[L->resultc++]=n;}
static const char* pushstring(lua_State* L,const char* s,size_t n){size_t size=n<sizeof L->message-1?n:sizeof L->message-1;memcpy(L->message,s,size);L->message[size]=0;return s;}
static int indexof(const void* p){return ((const Obj*)p)->index;}
static void* itemof(int n){return n>=0&&n<32?&objects[n]:NULL;}
static void* objectof(const void* p){return (void*)p;}
static void* weakmake(Weak* w,const void* p){const Obj* o=p;w->index=o->index;w->serial=o->serial;return w;}
static void* weakread(const Weak* w,unsigned char pending){Obj* o=itemof(w->index);weak_reads++;return o&&o->alive&&(!o->pending||pending)&&o->serial==w->serial?o:NULL;}
static void* worldof(const void* p){return ((const Obj*)p)->world;}
static unsigned char isa(const void* p,const void* c){return c==&objects[2]?((const Obj*)p)->type==1:c==&objects[3]?((const Obj*)p)->type==2:
    c==&objects[13]?((const Obj*)p)->type==3:c==&objects[14]?((const Obj*)p)->type==4:c==&objects[20]?((const Obj*)p)->type==5:0;}
#define ORIGINAL(n) __declspec(noinline) static void test##n(void* r,void* k,void* v){(void)r;(void)k;(void)v;calls[n]++;}
ORIGINAL(0) ORIGINAL(1) ORIGINAL(2) ORIGINAL(3) ORIGINAL(4)
__declspec(noinline) static void test_script(void* r,void* f,void* result){(void)r;(void)f;(void)result;script_calls++;}
static void** frame_node(void* f){frame_node_reads++;return &((Frame*)f)->node;}
static void** frame_object(void* f){return &((Frame*)f)->object;}
static void** frame_previous(void* f){return (void**)&((Frame*)f)->previous;}
static int64_t op(int64_t code,int64_t a,int64_t b,int64_t c,int64_t d,int64_t e){
    lua_State L={{code,a,b,c,d,e},{0},6,0};CHECK(bodycam_bridge_call(&L)>=1);return L.results[0];
}
static TeamData fixture_teams[2];static void* fixture_players[2];
static uint64_t start_tag=101,end_tag=102;static int team_mode=1,point_calls,phase_calls,score_limit=100,point_callback;
static int32_t fake_team(void* ps){return *(int32_t*)((char*)ps+0x398);}
static int32_t fake_limit(void* gs){CHECK(gs==&objects[15]);return score_limit;}
static unsigned char fake_shared(void* gs){CHECK(gs==&objects[15]);return team_mode;}
static int32_t fake_point(void* gs,int32_t team){
    TeamData* t=team_data(gs,team);CHECK(t!=NULL);point_calls++;t->score++;
    if(point_callback==1){KillFn volatile invoke=test0;invoke(&objects[1],&objects[7],&objects[5]);}
    if(point_callback==2){(*(int32_t*)(objects[15].bytes+0x3b8))++;(*(uint64_t*)(objects[15].bytes+0x3d0))++;}
    if(point_callback==3)reset_registry();
    *(int32_t*)((char*)gs+0x3bc)=team;return t->score;
}
static void fake_phase(void* gm,uint64_t tag){
    CHECK(gm==&objects[1]&&tag==end_tag);phase_calls++;
    *(uint64_t*)(objects[15].bytes+0x3b0)=tag;(*(int32_t*)(objects[15].bytes+0x3b8))++;
}
static void reward_fixture(void){
    lua_State L={{21,(intptr_t)&objects[0],(intptr_t)&objects[1],1,(intptr_t)&objects[2],(intptr_t)&objects[3],(intptr_t)&objects[21]},{0},7,0};
    CHECK(op(24,0,0,0,0,0)==1);
    native_team_id=fake_team;native_score_limit=fake_limit;native_team_based=fake_shared;
    native_team_point=fake_point;native_request_phase=fake_phase;component_owner_layout_verified=1;
    round_active_tag=&start_tag;round_end_tag=&end_tag;
    CHECK(op(28,(intptr_t)&objects[13],(intptr_t)&objects[14],(intptr_t)&objects[20],0,0)==1);
    CHECK((op(20,0,0,0,0,0)&16)==16);
    objects[15].type=4;objects[15].bytes[0x168]=3;
    *(void**)(objects[0].bytes+0x160)=&objects[15];*(void**)(objects[1].bytes+0x308)=&objects[15];
    objects[16].type=objects[17].type=3;objects[21].type=5;
    *(void**)(objects[21].bytes+0x90)=&objects[1]; /* real ActorComponent OwnerPrivate */
    *(void**)(objects[21].bytes+0x98)=&objects[0]; /* real CachedWorld is DIFFERENT */
    *(void**)(objects[7].bytes+0x2b0)=&objects[16];*(void**)(objects[16].bytes+0x158)=&objects[7];
    *(void**)(objects[18].bytes+0x2b0)=&objects[17];*(void**)(objects[17].bytes+0x158)=&objects[18];
    *(int32_t*)(objects[16].bytes+0x398)=3;*(int32_t*)(objects[17].bytes+0x398)=3;
    fixture_teams[0]=(TeamData){3,0,2};fixture_teams[1]=(TeamData){4,0,1};
    fixture_players[0]=&objects[16];fixture_players[1]=&objects[17];
    *(NativeArray*)(objects[15].bytes+0x2c0)=(NativeArray){fixture_players,2,2};
    *(NativeArray*)(objects[15].bytes+0x3c0)=(NativeArray){fixture_teams,2,2};
    *(uint64_t*)(objects[15].bytes+0x3b0)=start_tag;*(int32_t*)(objects[15].bytes+0x3b8)=1;
    *(uint64_t*)(objects[15].bytes+0x3d0)=500;
    point_calls=phase_calls=point_callback=0;score_limit=100;team_mode=1;
    CHECK(bodycam_bridge_call(&L)==1&&L.results[0]==1);CHECK(reward_mode_supported());
}
static void new_owned(void){
    CHECK(op(23,(intptr_t)&objects[4],1,0,0,0)==1);
    objects[4].serial++;objects[5].serial++;
    *(void**)(objects[5].bytes+0x2e8)=&objects[4];
    CHECK(op(22,(intptr_t)&objects[4],(intptr_t)&objects[5],1,0,0)==1);
}
static void kill_owned(void* killer){KillFn volatile invoke=test0;new_owned();invoke(&objects[1],killer,&objects[5]);}
static void reward_tests(void){
    KillFn volatile invoke=test0;KillFn volatile xp=test_script;int i,before;
    reward_fixture();
    CHECK(*(void**)(objects[21].bytes+0x90)==&objects[1]&&*(void**)(objects[21].bytes+0x98)==&objects[0]);
    for(i=0;i<4;i++){kill_owned(i%2?&objects[18]:&objects[7]);CHECK(point_calls==0);}
    kill_owned(&objects[18]);CHECK(point_calls==1&&fixture_teams[0].score==1&&phase_calls==0);
    CHECK(*(int32_t*)(objects[15].bytes+0x3bc)==3); /* same native RoundWinTeam */
    before=calls[0];invoke(&objects[1],&objects[7],&objects[5]);CHECK(point_calls==1&&calls[0]==before);
    {Frame caller={&objects[12],&objects[4],NULL},frame={&objects[11],&objects[7],&caller};
        before=script_calls;xp(&objects[7],&frame,NULL);CHECK(point_calls==1&&script_calls==before);}
    for(i=0;i<2;i++){
        CHECK(*(int32_t*)(objects[16+i].bytes+0x39c)==0);CHECK(*(int32_t*)(objects[16+i].bytes+0x3a0)==0);
    }
    /* All native downstream callbacks still suppress and never contribute. */
    detour1(&objects[1],&objects[7],&objects[5]);detour2(&objects[1],&objects[7],&objects[5]);
    CHECK(point_calls==1);
    new_owned();CHECK(op(29,(intptr_t)&objects[4],1,0,0,0)==1);invoke(&objects[1],&objects[7],&objects[5]);CHECK(point_calls==1);
    CHECK(op(22,(intptr_t)&objects[4],(intptr_t)&objects[5],1,0,0)==1);CHECK(owned[0].reward_retired);
    /* Prematch deaths are consumed but neither counted nor replayed later. */
    *(uint64_t*)(objects[15].bytes+0x3b0)=99;kill_owned(&objects[7]);CHECK(!rewards.scope.active);
    *(uint64_t*)(objects[15].bytes+0x3b0)=start_tag;invoke(&objects[1],&objects[7],&objects[5]);CHECK(point_calls==1);
    for(i=0;i<4;i++)kill_owned(&objects[7]);CHECK(point_calls==1);
    (*(int32_t*)(objects[15].bytes+0x3b8))++;kill_owned(&objects[7]);CHECK(point_calls==1);
    for(i=0;i<3;i++)kill_owned(&objects[7]);
    (*(uint64_t*)(objects[15].bytes+0x3d0))++;kill_owned(&objects[7]);CHECK(point_calls==1);
    /* Same team ID reused by a new FFA PlayerState cannot inherit fractions. */
    reward_fixture();team_mode=0;for(i=0;i<4;i++)kill_owned(&objects[7]);
    kill_owned(&objects[18]);CHECK(point_calls==0);kill_owned(&objects[7]);CHECK(point_calls==1);
    objects[17].serial++;kill_owned(&objects[18]);CHECK(point_calls==1);
    for(i=0;i<3;i++)kill_owned(&objects[18]);CHECK(point_calls==1);kill_owned(&objects[18]);CHECK(point_calls==2);
    /* Team switch discards the player's old-team fractions. */
    reward_fixture();team_mode=0;for(i=0;i<4;i++)kill_owned(&objects[7]);
    *(int32_t*)(objects[16].bytes+0x398)=4;kill_owned(&objects[7]);CHECK(point_calls==0);
    *(int32_t*)(objects[16].bytes+0x398)=3;kill_owned(&objects[7]);CHECK(point_calls==0);
    /* Empty/recreated team and authority heartbeat prune remainders. */
    reward_fixture();for(i=0;i<4;i++)kill_owned(&objects[7]);fixture_teams[0].players=0;
    CHECK(op(25,0,0,0,0,0)==1);fixture_teams[0].players=2;kill_owned(&objects[7]);CHECK(point_calls==0);
    /* Unknown, foreign and unrostered killers never advance a team. */
    kill_owned(NULL);kill_owned(&objects[5]);fixture_players[0]=&objects[17];kill_owned(&objects[7]);
    fixture_players[0]=&objects[16];objects[7].world=&objects[10];kill_owned(&objects[7]);objects[7].world=&objects[0];
    *(void**)(objects[16].bytes+0x158)=&objects[18];kill_owned(&objects[7]);*(void**)(objects[16].bytes+0x158)=&objects[7];
    CHECK(point_calls==0);
    /* Exact legacy death route contributes once while XP body never executes. */
    reward_fixture();for(i=0;i<5;i++){
        Frame caller={&objects[12],&objects[4],NULL},frame={&objects[11],&objects[7],&caller};
        new_owned();before=script_calls;xp(&objects[7],&frame,NULL);CHECK(script_calls==before);
        invoke(&objects[1],&objects[7],&objects[5]);
    }CHECK(point_calls==1);
    /* Native limit completion happens exactly after the fifth point contributor. */
    reward_fixture();score_limit=1;for(i=0;i<4;i++){kill_owned(&objects[7]);CHECK(phase_calls==0);}
    kill_owned(&objects[7]);CHECK(point_calls==1&&phase_calls==1&&fixture_teams[0].score==1);
    CHECK(*(int32_t*)(objects[15].bytes+0x3b8)==2);kill_owned(&objects[7]);CHECK(point_calls==1&&phase_calls==1);
    /* OnTeamsChanged is synchronous: same-death re-entry stays exactly once. */
    reward_fixture();score_limit=1;point_callback=1;
    for(i=0;i<5;i++)kill_owned(&objects[7]);CHECK(point_calls==1&&phase_calls==1);
    /* Broadcast can replace the round/registry before the native call returns. */
    reward_fixture();score_limit=1;point_callback=2;
    for(i=0;i<5;i++)kill_owned(&objects[7]);CHECK(point_calls==1&&phase_calls==0);
    CHECK(*(int32_t*)(objects[15].bytes+0x3b8)==2);
    reward_fixture();score_limit=1;point_callback=3;
    for(i=0;i<5;i++)kill_owned(&objects[7]);CHECK(point_calls==1&&phase_calls==0&&!active);
    /* Identity remains usable on the real native pending/unpossessed death paths. */
    reward_fixture();for(i=0;i<4;i++)kill_owned(&objects[7]);new_owned();objects[4].pending=1;
    invoke(&objects[1],&objects[7],&objects[5]);CHECK(point_calls==1);objects[4].pending=0;
    CHECK(op(22,(intptr_t)&objects[4],(intptr_t)&objects[5],1,0,0)==1);CHECK(owned[0].death_observed);
    reward_fixture();for(i=0;i<4;i++)kill_owned(&objects[7]);new_owned();*(void**)(objects[5].bytes+0x2e8)=NULL;
    invoke(&objects[1],&objects[7],&objects[5]);CHECK(point_calls==1);
    /* Never overflow native int32 scoring. */
    reward_fixture();fixture_teams[0].score=INT32_MAX;for(i=0;i<6;i++)kill_owned(&objects[7]);
    CHECK(point_calls==0&&fixture_teams[0].score==INT32_MAX);
    /* Objective/Elimination mode without the score rule stays zero and cannot end. */
    reward_fixture();score_rule=(BzObjectId){0};for(i=0;i<8;i++)kill_owned(&objects[7]);
    CHECK(point_calls==0&&phase_calls==0&&!reward_mode_supported());
    /* Regression: the old implementation compared CachedWorld to GameMode.
     * Actual +0x90 ownership activates; wrong owner fails with a bounded reason. */
    reward_fixture();
    {lua_State L={{21,(intptr_t)&objects[0],(intptr_t)&objects[1],1,(intptr_t)&objects[2],(intptr_t)&objects[3],(intptr_t)&objects[21]},{0},7,0,{0}};
        *(void**)(objects[21].bytes+0x90)=&objects[0];
        CHECK(bodycam_bridge_call(&L)==2&&L.results[0]==0);
        CHECK(strstr(L.message,"owner is not the authority GameMode")!=NULL);CHECK(!active);
    }
    reward_fixture();
    {lua_State L={{21,(intptr_t)&objects[0],(intptr_t)&objects[1],1,(intptr_t)&objects[2],(intptr_t)&objects[3],(intptr_t)&objects[21]},{0},7,0,{0}};
        objects[21].pending=1;CHECK(bodycam_bridge_call(&L)==2&&L.results[0]==0);
        CHECK(strstr(L.message,"identity unavailable")!=NULL);objects[21].pending=0;
    }
    CHECK(op(24,0,0,0,0,0)==1);CHECK(!active&&!rewards.scope.active);
}
static DWORD WINAPI worker(void* unused){
    lua_State L={{24},{0},1,0};(void)unused;
    if(context_ok() || filter(1,&objects[1],&objects[5]) || bodycam_bridge_call(&L)!=0)return 1;
    return 0;
}
int main(void){
    int i;void* k=&objects[7];KillFn targets[5]={test0,test1,test2,test3,test4};
    void* detours[5]={(void*)detour0,(void*)detour1,(void*)detour2,(void*)detour3,(void*)detour4};
    for(i=0;i<32;i++){objects[i].index=i;objects[i].serial=20+i;objects[i].alive=1;objects[i].world=&objects[0];}
    *(void**)(objects[0].bytes+0x158)=&objects[1];objects[1].bytes[0x168]=3;
    objects[5].type=1;objects[7].type=2;objects[8].type=1;
    *(void**)(objects[5].bytes+0x2e8)=&objects[4];*(void**)(objects[7].bytes+0x2e8)=&objects[6];
    *(void**)(objects[8].bytes+0x2e8)=&objects[9];
    ltop=top;lint=integer;lpush=push;lstring=pushstring;weak_ctor=weakmake;weak_get=weakread;
    object_index=indexof;index_object=itemof;item_object=objectof;object_world=worldof;object_isa=isa;attempted=installed=1;
    script_entry[0]=0xff;script_entry[1]=0x25;{uintptr_t target=(uintptr_t)test_script;memcpy(script_entry+6,&target,8);}
    ue4ss_base=(uintptr_t)test_script-BZ_XP_UE4SS_DISPATCH_RVA;game_base=(uintptr_t)script_entry-BZ_XP_GAME_SCRIPT_RVA;
    CHECK(op(20,0,0,0,0,0)==5);
    frames=(BzXpAccessors){frame_node,frame_object,frame_previous};script_installed=1;
    CHECK(op(26,(intptr_t)&objects[11],(intptr_t)&objects[12],0,0,0)==1);
    CHECK(op(20,0,0,0,0,0)==7);
    CHECK(op(21,(intptr_t)&objects[0],(intptr_t)&objects[1],1,(intptr_t)&objects[2],(intptr_t)&objects[3])==1);
    CHECK(op(25,0,0,0,0,0)==1);
    CHECK(op(22,(intptr_t)&objects[4],0,1,0,0)==1); /* before FinishSpawningActor */
    CHECK(owned_count==1);
    CHECK(MH_Initialize()==MH_OK);
    for(i=0;i<5;i++)CHECK(MH_CreateHook((void*)targets[i],detours[i],(void**)&original[i])==MH_OK);
    for(i=0;i<5;i++)CHECK(MH_EnableHook((void*)targets[i])==MH_OK);
    CHECK(MH_CreateHook((void*)test_script,(void*)script_detour,(void**)&original_script)==MH_OK);
    CHECK(MH_EnableHook((void*)test_script)==MH_OK);
    {Frame caller={&objects[12],&objects[4],NULL},frame={&objects[11],&objects[7],&caller};KillFn volatile invoke=test_script;
        invoke(&objects[7],&frame,NULL);CHECK(script_calls==0);CHECK(suppressed_xp==1);
        caller.object=&objects[9];invoke(&objects[7],&frame,NULL);CHECK(script_calls==1);
        caller.object=&objects[4];caller.node=&objects[10];invoke(&objects[7],&frame,NULL);CHECK(script_calls==2);
        caller.node=&objects[12];frame.node=&objects[10];invoke(&objects[7],&frame,NULL);CHECK(script_calls==3);
        frame.node=&objects[11];frame.previous=NULL;invoke(&objects[7],&frame,NULL);CHECK(script_calls==4);
    }
    {Frame caller={&objects[12],&objects[4],NULL},frame={&objects[10],&objects[7],&caller};KillFn volatile invoke=test_script;
        unsigned long long before=weak_reads,node_before=frame_node_reads;int count=script_calls;size_t saved=owned_count;
        invoke(&objects[7],&frame,NULL);CHECK(script_calls==count+1);
        CHECK(weak_reads==before&&frame_node_reads==node_before+1); /* common path: zero UObject lookups */
        owned_count=0;before=weak_reads;node_before=frame_node_reads;count=script_calls;
        invoke(&objects[7],&frame,NULL);CHECK(script_calls==count+1&&weak_reads==before&&frame_node_reads==node_before);
        CHECK(filter(1,&objects[1],&objects[5])==0&&weak_reads==before);owned_count=saved;
        /* Cached address reuse/expiry still reaches exact weak-serial checks. */
        frame.node=&objects[11];objects[11].serial++;count=script_calls;before=weak_reads;
        invoke(&objects[7],&frame,NULL);CHECK(script_calls==count+1&&weak_reads>before);objects[11].serial--;
        objects[11].alive=0;count=script_calls;invoke(&objects[7],&frame,NULL);CHECK(script_calls==count+1);objects[11].alive=1;
    }
    for(i=0;i<5;i++){
        KillFn volatile invoke=targets[i];
        invoke(&objects[1],k,&objects[5]);CHECK(calls[i]==0);CHECK(suppressed[i]==1);
        invoke(&objects[1],k,&objects[7]);CHECK(calls[i]==1); /* human */
        invoke(&objects[1],k,&objects[8]);CHECK(calls[i]==2); /* foreign zombie */
        invoke(&objects[1],NULL,NULL);CHECK(calls[i]==3); /* native re-evaluation */
    }
    CHECK(op(22,(intptr_t)&objects[4],(intptr_t)&objects[5],1,0,0)==1); /* after possession */
    {DWORD result=99;HANDLE thread=CreateThread(NULL,0,worker,NULL,0,NULL);CHECK(thread!=NULL);CHECK(WaitForSingleObject(thread,5000)==WAIT_OBJECT_0);
        CHECK(GetExitCodeThread(thread,&result)!=0);CHECK(result==0);CHECK(CloseHandle(thread)!=0);CHECK(active&&owned_count==1);}
    *(void**)(objects[5].bytes+0x2e8)=NULL;
    CHECK(filter(1,&objects[1],&objects[5])==1); /* retained exact controller */
    *(void**)(objects[5].bytes+0x2e8)=&objects[6];CHECK(filter(1,&objects[1],&objects[5])==0); /* re-possessed */
    *(void**)(objects[5].bytes+0x2e8)=&objects[4];
    objects[5].serial++;CHECK(filter(1,&objects[1],&objects[5])==0);objects[5].serial--;
    objects[4].alive=0;CHECK(filter(1,&objects[1],&objects[5])==0);objects[4].alive=1;
    objects[4].pending=1;CHECK(filter(1,&objects[1],&objects[5])==1);CHECK(owned_xp(&objects[4],&objects[7],NULL)==1);
    objects[4].serial++;CHECK(filter(1,&objects[1],&objects[5])==0);CHECK(owned_xp(&objects[4],&objects[7],NULL)==0);objects[4].serial--;objects[4].pending=0;
    objects[1].bytes[0x168]=2;CHECK(filter(1,&objects[1],&objects[5])==0);objects[1].bytes[0x168]=3;
    objects[5].world=&objects[10];CHECK(filter(1,&objects[1],&objects[5])==0);objects[5].world=&objects[0];
    CHECK(op(23,(intptr_t)&objects[4],2,0,0,0)==0);CHECK(owned_count==1);
    CHECK(op(23,(intptr_t)&objects[4],1,0,0,0)==1);CHECK(owned_count==0);
    CHECK(filter(1,&objects[1],&objects[5])==0);
    CHECK(op(22,(intptr_t)&objects[4],(intptr_t)&objects[5],1,0,0)==1);
    CHECK(op(21,(intptr_t)&objects[0],(intptr_t)&objects[1],2,(intptr_t)&objects[2],(intptr_t)&objects[3])==1);CHECK(owned_count==0);
    CHECK(op(24,0,0,0,0,0)==1);CHECK(!active);CHECK(op(25,0,0,0,0,0)==0);
    reward_tests();
    for(i=0;i<5;i++){KillFn volatile invoke=targets[i];invoke(&objects[1],k,&objects[5]);CHECK(calls[i]==4);CHECK(MH_DisableHook((void*)targets[i])==MH_OK);CHECK(MH_RemoveHook((void*)targets[i])==MH_OK);}
    CHECK(MH_DisableHook((void*)test_script)==MH_OK);CHECK(MH_RemoveHook((void*)test_script)==MH_OK);
    CHECK(MH_Uninitialize()==MH_OK);
    {SYSTEM_INFO system;DWORD old;void* block;GetSystemInfo(&system);block=VirtualAlloc(NULL,system.dwPageSize*2,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);CHECK(block!=NULL);
        CHECK(VirtualProtect((char*)block+system.dwPageSize,system.dwPageSize,PAGE_READONLY,&old)!=0);CHECK(readable(block,system.dwPageSize*2));
        CHECK(VirtualProtect((char*)block+system.dwPageSize,system.dwPageSize,PAGE_NOACCESS,&old)!=0);CHECK(!readable(block,system.dwPageSize*2));CHECK(VirtualFree(block,0,MEM_RELEASE)!=0);}
    printf("Native bridge: %d checks passed, including six real x64 detours; game untouched.\n",checks);return 0;
}
