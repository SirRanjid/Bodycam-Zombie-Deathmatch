#include "xp_gate.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct MockFrame {void *node,*object;struct MockFrame *previous;} MockFrame;
static void **node(void *f){return &((MockFrame*)f)->node;}
static void **object(void *f){return &((MockFrame*)f)->object;}
static void **previous(void *f){return (void**)&((MockFrame*)f)->previous;}
static int permission=1,queries=0;
static unsigned char arena[128];
static int read_bytes(const void *address,void *out,size_t size){
    uintptr_t p=(uintptr_t)address,start=(uintptr_t)arena;
    if(p<start||size>sizeof arena||p-start>sizeof arena-size)return 0;
    memcpy(out,address,size);return 1;
}
static void relative_jump(unsigned at,unsigned to){
    int32_t rel=(int32_t)to-(int32_t)at-5;
    arena[at]=0xe9;memcpy(arena+at+1,&rel,4);
}
static int owned(void *actor,void *controller,void *user){
    ++queries;return permission&&actor==(void*)101&&controller==(void*)202&&user==(void*)303;
}
static void *lookup(void *module,const char *name){
    if(module!=(void*)1)return 0;
    if(!strncmp(name,"?Node@",6))return (void*)node;
    if(!strncmp(name,"?Object@",8))return (void*)object;
    if(!strncmp(name,"?PreviousFrame@",15))return (void*)previous;
    return 0;
}
int main(void){
    BzXpAccessors a={0};MockFrame caller={(void*)12,(void*)101,0},frame={(void*)11,(void*)202,&caller};
    MockFrame copy;int checks=0;
#define CHECK(x) do{++checks;if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1;}}while(0)
#define RUN() bz_xp_should_suppress(&a,(void*)202,&frame,(void*)11,(void*)12,owned,(void*)303)
    CHECK(bz_xp_resolve(&a,(void*)1,lookup));copy=frame;CHECK(RUN());CHECK(!memcmp(&copy,&frame,sizeof frame));
    CHECK(queries==1);permission=0;CHECK(!RUN());permission=1;
    caller.object=(void*)999;CHECK(!RUN());caller.object=(void*)101;
    caller.node=(void*)99;CHECK(!RUN());caller.node=(void*)12;
    frame.node=(void*)99;CHECK(!RUN());frame.node=(void*)11;
    frame.object=(void*)999;CHECK(!RUN());frame.object=(void*)202;
    caller.object=(void*)202;CHECK(!RUN());caller.object=(void*)101;
    frame.previous=0;CHECK(!RUN());frame.previous=&frame;CHECK(!RUN());frame.previous=&caller;
    a.node=0;CHECK(!RUN());a.node=node;a.object=0;CHECK(!RUN());a.object=object;
    a.previous=0;CHECK(!RUN());a.previous=previous;
    CHECK(!bz_xp_should_suppress(&a,(void*)202,&frame,(void*)11,(void*)12,0,(void*)303));
    CHECK(!bz_xp_should_suppress(&a,(void*)202,&frame,0,(void*)12,owned,(void*)303));
    CHECK(!bz_xp_should_suppress(&a,(void*)202,&frame,(void*)11,(void*)11,owned,(void*)303));
    CHECK(!bz_xp_should_suppress(&a,(void*)202,0,(void*)11,(void*)12,owned,(void*)303));
    CHECK(!bz_xp_should_suppress(0,(void*)202,&frame,(void*)11,(void*)12,owned,(void*)303));
    CHECK(!bz_xp_resolve(&a,(void*)2,lookup));CHECK(!a.node&&!a.object&&!a.previous);
    CHECK(!bz_xp_route_reaches(arena,arena+100,read_bytes));
    relative_jump(0,100);CHECK(bz_xp_route_reaches(arena,arena+100,read_bytes));
    relative_jump(0,20);relative_jump(20,100);CHECK(bz_xp_route_reaches(arena,arena+100,read_bytes));
    relative_jump(20,0);CHECK(!bz_xp_route_reaches(arena,arena+100,read_bytes));
    arena[20]=0xeb;arena[21]=78;CHECK(bz_xp_route_reaches(arena,arena+100,read_bytes));
    arena[20]=0xeb;arena[21]=(unsigned char)-22;CHECK(!bz_xp_route_reaches(arena,arena+100,read_bytes));
    {int32_t offset=4;uintptr_t target=(uintptr_t)(arena+100);
        arena[20]=0xff;arena[21]=0x25;memcpy(arena+22,&offset,4);memcpy(arena+30,&target,8);
        CHECK(bz_xp_route_reaches(arena,arena+100,read_bytes));
        target=(uintptr_t)arena+140;memcpy(arena+30,&target,8);CHECK(!bz_xp_route_reaches(arena,arena+100,read_bytes));
        offset=999;memcpy(arena+22,&offset,4);CHECK(!bz_xp_route_reaches(arena,arena+100,read_bytes));
        arena[20]=0x48;arena[21]=0xb8;target=(uintptr_t)(arena+100);memcpy(arena+22,&target,8);arena[30]=0xff;arena[31]=0xe0;
        CHECK(bz_xp_route_reaches(arena,arena+100,read_bytes));
        arena[31]=0xd0;CHECK(!bz_xp_route_reaches(arena,arena+100,read_bytes));}
    memset(arena,0,sizeof arena);
    for(unsigned k=0;k<6;k++)relative_jump(k*10,(k+1)*10);
    CHECK(bz_xp_route_reaches(arena,arena+60,read_bytes));
    relative_jump(60,100);CHECK(!bz_xp_route_reaches(arena,arena+100,read_bytes));
    CHECK(!bz_xp_route_reaches(arena+127,arena+100,read_bytes));
    CHECK(!bz_xp_route_reaches(arena,arena+100,0));
    CHECK(!bz_xp_runtime_ready(0,arena,read_bytes));
    printf("%d native Blueprint-XP gate checks passed.\n",checks);return 0;
}
