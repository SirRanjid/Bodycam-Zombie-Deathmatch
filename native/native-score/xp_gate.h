#ifndef BZ_XP_GATE_H
#define BZ_XP_GATE_H
#include <stdint.h>
#include <stddef.h>

/* Win64 C ABI. UE4SS getters return a C++ reference, therefore void **. */
typedef void **(*BzFrameMember)(void *frame);
typedef void *(*BzFindExport)(void *module,const char *name);
typedef int (*BzXpOwned)(void *source_zombie,void *reward_controller,void *user);
typedef int (*BzXpRead)(const void *address,void *out,size_t size);
typedef struct BzXpAccessors {
    BzFrameMember node,object,previous;
} BzXpAccessors;

/* Resolve only from the parent's already SHA256-validated UE4SS module. */
int bz_xp_resolve(BzXpAccessors *out,void *module,BzFindExport find_export);

/* Parent must resolve live weak function IDs each call and supply a predicate
 * checking game thread, current authority world/GM/epoch, exact live registered
 * pawn weak identity, and live reward PlayerController in that same world.
 * A true result authorizes an immediate void return before script execution. */
int bz_xp_should_suppress(const BzXpAccessors *access,void *context,void *frame,
    void *kill_function,void *zombie_ubergraph,BzXpOwned owned,void *user);

#define BZ_XP_UE4SS_DISPATCH_RVA UINT32_C(0x4670c0)
#define BZ_XP_GAME_SCRIPT_RVA UINT32_C(0x14ac2b0)
extern const unsigned char bz_xp_dispatch_prologue[32];
/* Parent reader checks VirtualQuery/readability then copies exactly size bytes.
 * Only unconditional x64 branches are followed; ordinary interpreter bytes,
 * unmapped memory, cycles, and routes longer than six branches return false. */
int bz_xp_route_reaches(const void *entry,const void *dispatcher,BzXpRead read);
int bz_xp_runtime_ready(const void *ue4ss_base,const void *game_base,BzXpRead read);
#endif
