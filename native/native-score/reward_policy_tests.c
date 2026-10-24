#include "reward_policy.h"
#include <stdio.h>
#include <stdlib.h>
static int checks;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);exit(1);}}while(0)
int main(void){
    BzRewardState s={0};BzObjectId gs={100,1,2},p1={200,2,3},p2={300,3,4};
    BzRewardScope scope={gs,1000,1,1};int i;
    CHECK(!bz_reward_add(&s,0,p1));bz_reward_sync(&s,scope);
    for(i=0;i<15;i++)CHECK(bz_reward_add(&s,0,gs)==(i%5==4));
    for(i=0;i<4;i++){CHECK(!bz_reward_add(&s,1,p1));CHECK(!bz_reward_add(&s,2,p2));}
    CHECK(bz_reward_add(&s,1,p1));CHECK(bz_reward_add(&s,2,p2));
    for(i=0;i<4;i++)CHECK(!bz_reward_add(&s,3,p1));
    CHECK(!bz_reward_add(&s,3,p2)); /* reused FFA team ID is a new player */
    scope.round++;bz_reward_sync(&s,scope);CHECK(!bz_reward_add(&s,3,p1));
    for(i=0;i<3;i++)CHECK(!bz_reward_add(&s,3,p1));
    scope.round_start++;bz_reward_sync(&s,scope);CHECK(!bz_reward_add(&s,3,p1));
    scope.active=0;bz_reward_sync(&s,scope);CHECK(!bz_reward_add(&s,3,p1));
    scope.active=1;bz_reward_sync(&s,scope);CHECK(!bz_reward_add(&s,3,p1));
    CHECK(!bz_reward_add(&s,-1,p1));CHECK(!bz_reward_add(&s,0,(BzObjectId){0}));
    bz_reward_reset(&s);bz_reward_sync(&s,scope);
    for(i=0;i<256;i++)CHECK(!bz_reward_add(&s,i,gs));
    CHECK(!bz_reward_add(&s,256,gs));CHECK(!bz_reward_add(&s,0,gs));
    scope.game_state.serial++;bz_reward_sync(&s,scope);CHECK(!bz_reward_add(&s,0,gs));
    puts("Reward policy: bounded per-team integer fifths verified.");printf("%d native reward checks passed.\n",checks);return 0;
}
