#include "xp_gate.h"

const unsigned char bz_xp_dispatch_prologue[32]={
    0x40,0x53,0x55,0x56,0x57,0x48,0x83,0xec,0x68,0x49,0x8b,0xf8,0x48,0x8b,0xf2,0x48,
    0x8b,0xe9,0xe8,0x59,0x1f,0xfe,0xff,0x48,0x8d,0x54,0x24,0x30,0x48,0x8b,0xd8,0x48};

int bz_xp_resolve(BzXpAccessors *out,void *module,BzFindExport find_export) {
    if(!out)return 0;
    out->node=0;out->object=0;out->previous=0;
    if(!module||!find_export)return 0;
    out->node=(BzFrameMember)find_export(module,"?Node@FFrame@Unreal@RC@@QEAAAEAPEAVUFunction@23@XZ");
    out->object=(BzFrameMember)find_export(module,"?Object@FFrame@Unreal@RC@@QEAAAEAPEAVUObject@23@XZ");
    out->previous=(BzFrameMember)find_export(module,"?PreviousFrame@FFrame@Unreal@RC@@QEAAAEAPEAU123@XZ");
    return out->node&&out->object&&out->previous;
}

static void *member(BzFrameMember getter,void *frame) {
    void **slot;
    if(!getter||!frame)return 0;
    slot=getter(frame);return slot?*slot:0;
}

int bz_xp_should_suppress(const BzXpAccessors *a,void *context,void *frame,
    void *kill_function,void *zombie_ubergraph,BzXpOwned owned,void *user) {
    void *caller,*source;
    if(!a||!a->node||!a->object||!a->previous||!context||!frame
        ||!kill_function||!zombie_ubergraph||kill_function==zombie_ubergraph||!owned)return 0;
    if(member(a->node,frame)!=kill_function||member(a->object,frame)!=context)return 0;
    caller=member(a->previous,frame);
    if(!caller||caller==frame||member(a->node,caller)!=zombie_ubergraph)return 0;
    source=member(a->object,caller);
    if(!source||source==context)return 0;
    /* No name/tag/IsBot inference and no unbounded stack walk. */
    return owned(source,context,user)==1;
}

static uintptr_t add_signed(uintptr_t base,int64_t delta) {
    if(delta<0) {
        uint64_t magnitude=(uint64_t)(-delta);
        return base<magnitude?0:base-(uintptr_t)magnitude;
    }
    return UINTPTR_MAX-base<(uint64_t)delta?0:base+(uintptr_t)delta;
}

int bz_xp_route_reaches(const void *entry,const void *dispatcher,BzXpRead read) {
    uintptr_t cursor=(uintptr_t)entry,target=(uintptr_t)dispatcher,seen[6]={0};
    unsigned i,j;unsigned char b[12];int32_t rel32;int8_t rel8;
    if(!cursor||!target||!read)return 0;
    for(i=0;i<6;i++) {
        uintptr_t next=0,slot;
        if(cursor==target)return 1;
        for(j=0;j<i;j++)if(seen[j]==cursor)return 0;
        seen[i]=cursor;
        if(cursor>UINTPTR_MAX-sizeof b)return 0;
        if(!read((const void*)cursor,b,2))return 0;
        if(b[0]==0xe9) {
            if(!read((const void*)(cursor+1),&rel32,4))return 0;
            next=add_signed(cursor,(int64_t)rel32+5);
        }else if(b[0]==0xeb) {
            rel8=(int8_t)b[1];next=add_signed(cursor,(int64_t)rel8+2);
        }else if(b[0]==0xff&&b[1]==0x25) {
            if(!read((const void*)(cursor+2),&rel32,4))return 0;
            slot=add_signed(cursor,(int64_t)rel32+6);
            if(!slot||!read((const void*)slot,&next,sizeof next))return 0;
        }else if(b[0]==0x48&&b[1]==0xb8) {
            if(!read((const void*)cursor,b,sizeof b)||b[10]!=0xff||b[11]!=0xe0)return 0;
            if(!read((const void*)(cursor+2),&next,sizeof next))return 0;
        }else return 0;
        if(!next)return 0;
        cursor=next;
    }
    return cursor==target;
}

int bz_xp_runtime_ready(const void *ue4ss_base,const void *game_base,BzXpRead read) {
    uintptr_t u=(uintptr_t)ue4ss_base,g=(uintptr_t)game_base;
    if(!u||!g||UINTPTR_MAX-u<BZ_XP_UE4SS_DISPATCH_RVA||UINTPTR_MAX-g<BZ_XP_GAME_SCRIPT_RVA)return 0;
    return bz_xp_route_reaches((const void*)(g+BZ_XP_GAME_SCRIPT_RVA),
        (const void*)(u+BZ_XP_UE4SS_DISPATCH_RVA),read);
}
