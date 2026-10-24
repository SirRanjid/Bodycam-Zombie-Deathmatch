#ifndef BZ_REWARD_POLICY_H
#define BZ_REWARD_POLICY_H
#include "score_filter.h"
/* Integer fifths: no floating point, UObject dereference, or unbounded history. */
typedef struct BzRewardScope {
    BzObjectId game_state;
    uint64_t round_start;
    int32_t round;
    unsigned active;
} BzRewardScope;
typedef struct BzRewardTeam {
    int32_t team;
    BzObjectId identity; /* GameState for a shared team; PlayerState for FFA. */
    unsigned occupied, remainder;
} BzRewardTeam;
typedef struct BzRewardState {
    BzRewardScope scope;
    BzRewardTeam teams[BZ_SCORE_MAX_OWNED];
} BzRewardState;
void bz_reward_reset(BzRewardState *state);
void bz_reward_sync(BzRewardState *state,BzRewardScope scope);
int bz_reward_add(BzRewardState *state,int32_t team,BzObjectId identity);
#endif
