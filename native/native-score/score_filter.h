#ifndef BODYCAM_ZOMBIE_SCORE_FILTER_H
#define BODYCAM_ZOMBIE_SCORE_FILTER_H
#include <stddef.h>
#include <stdint.h>

/* Pure policy: never dereferences Unreal pointers, mutates scores, or calls Lua.
 * The cold-start bridge validates each identity against the native object array
 * and supplies an authoritative game-thread snapshot before any original call. */
#define BZ_SCORE_OWNER_TAG UINT32_C(0x425A5631)
#define BZ_SCORE_MAX_OWNED 256u

typedef struct BzObjectId {
    uintptr_t address;
    int32_t object_index;
    int32_t serial;
} BzObjectId;

typedef enum BzScoreBoundary {
    BZ_SCORE_NOTIFY_KILLED = 1,
    BZ_SCORE_GAMESTATE_KILLED = 2,
    BZ_SCORE_LIMIT_RULE = 3,
    BZ_SCORE_ELIMINATION_RULE = 4,
    BZ_SCORE_OBJECTIVE_RULE = 5
} BzScoreBoundary;

typedef struct BzScoreOwned {
    uint32_t owner_tag;
    uint32_t enabled;
    uint64_t epoch;
    BzObjectId world;
    BzObjectId authority_game_mode;
    BzObjectId pawn;
    BzObjectId controller; /* zero until the pawn's own native AI controller binds */
    uint32_t reward_retired; /* cleanup disables bonuses, never suppression */
    uint32_t death_observed; /* immutable once any exact death route observes it */
} BzScoreOwned;

typedef struct BzScoreEvent {
    uint32_t boundary;
    uint32_t variant_active;
    uint32_t authority;
    uint32_t game_thread;
    uint64_t epoch;
    BzObjectId world;
    BzObjectId authority_game_mode;
    BzObjectId victim_controller;
    BzObjectId victim_pawn; /* zero after native unpossession; never dereference here */
    uint32_t victim_controller_is_live;
    uint32_t victim_pawn_is_live;
    uint32_t victim_is_player_controller;
} BzScoreEvent;

int bz_score_id_equal(BzObjectId a, BzObjectId b);
int bz_score_should_suppress(const BzScoreOwned *owned, size_t count, const BzScoreEvent *event);
#endif
