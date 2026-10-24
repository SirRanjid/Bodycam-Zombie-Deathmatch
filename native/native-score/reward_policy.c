#include "reward_policy.h"
#include <string.h>
void bz_reward_reset(BzRewardState *s){if(s)memset(s,0,sizeof *s);}
void bz_reward_sync(BzRewardState *s,BzRewardScope next){
    if(!s)return;
    if(next.active!=1 || !bz_score_id_equal(next.game_state,next.game_state)){
        bz_reward_reset(s);return;
    }
    if(s->scope.active!=1 || !bz_score_id_equal(s->scope.game_state,next.game_state) ||
       s->scope.round!=next.round || s->scope.round_start!=next.round_start)memset(s->teams,0,sizeof s->teams);
    s->scope=next;
}
int bz_reward_add(BzRewardState *s,int32_t team,BzObjectId identity){
    size_t i,empty=BZ_SCORE_MAX_OWNED;
    if(!s || s->scope.active!=1 || team<0 || !bz_score_id_equal(identity,identity))return 0;
    for(i=0;i<BZ_SCORE_MAX_OWNED;i++){
        BzRewardTeam *b=&s->teams[i];
        if(!b->occupied){if(empty==BZ_SCORE_MAX_OWNED)empty=i;continue;}
        if(b->team==team && bz_score_id_equal(b->identity,identity))break;
    }
    if(i==BZ_SCORE_MAX_OWNED){
        if(empty==BZ_SCORE_MAX_OWNED)return 0;
        i=empty;s->teams[i]=(BzRewardTeam){team,identity,1,0};
    }
    if(++s->teams[i].remainder==5){s->teams[i].remainder=0;return 1;}
    return 0;
}
