#include "score_filter.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static BzObjectId id(uintptr_t p, int32_t index, int32_t serial) {
    BzObjectId value; value.address=p; value.object_index=index; value.serial=serial; return value;
}
static BzScoreOwned owned(void) {
    BzScoreOwned r; memset(&r,0,sizeof r);r.owner_tag=BZ_SCORE_OWNER_TAG;r.enabled=1;r.epoch=3;
    r.world=id(100,1,1);r.authority_game_mode=id(200,2,1);r.pawn=id(300,3,7);r.controller=id(400,4,9);return r;
}
static BzScoreEvent event(void) {
    BzScoreEvent e; BzScoreOwned r=owned();memset(&e,0,sizeof e);e.boundary=BZ_SCORE_NOTIFY_KILLED;
    e.variant_active=1;e.authority=1;e.game_thread=1;e.epoch=r.epoch;e.world=r.world;
    e.authority_game_mode=r.authority_game_mode;e.victim_controller=r.controller;e.victim_pawn=r.pawn;
    e.victim_controller_is_live=1;e.victim_pawn_is_live=1;return e;
}
int main(void) {
    BzScoreOwned r=owned(), saved;BzScoreEvent e=event();unsigned checks=0,b;
#define CHECK(x) do{++checks;if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1;}}while(0)
    for(b=BZ_SCORE_NOTIFY_KILLED;b<=BZ_SCORE_OBJECTIVE_RULE;++b){e.boundary=b;CHECK(bz_score_should_suppress(&r,1,&e)==1);}e=event();
    saved=r;CHECK(bz_score_should_suppress(&r,1,&e)==1);CHECK(memcmp(&r,&saved,sizeof r)==0);
    e.variant_active=0;CHECK(!bz_score_should_suppress(&r,1,&e));e=event();e.authority=0;CHECK(!bz_score_should_suppress(&r,1,&e));
    e=event();e.game_thread=0;CHECK(!bz_score_should_suppress(&r,1,&e));e=event();e.epoch++;CHECK(!bz_score_should_suppress(&r,1,&e));
    e=event();e.world.serial++;CHECK(!bz_score_should_suppress(&r,1,&e));e=event();e.authority_game_mode.address++;CHECK(!bz_score_should_suppress(&r,1,&e));
    e=event();e.victim_controller.serial++;CHECK(!bz_score_should_suppress(&r,1,&e));
    e=event();e.victim_pawn.serial++;CHECK(!bz_score_should_suppress(&r,1,&e));
    e=event();e.victim_pawn.address++;CHECK(!bz_score_should_suppress(&r,1,&e));
    e=event();e.victim_is_player_controller=1;CHECK(!bz_score_should_suppress(&r,1,&e));
    e=event();e.victim_controller_is_live=0;CHECK(!bz_score_should_suppress(&r,1,&e));
    e=event();e.victim_pawn_is_live=0;CHECK(!bz_score_should_suppress(&r,1,&e));
    e=event();memset(&e.victim_pawn,0,sizeof e.victim_pawn);e.victim_pawn_is_live=0;CHECK(bz_score_should_suppress(&r,1,&e)==1);
    e=event();memset(&r.controller,0,sizeof r.controller);CHECK(bz_score_should_suppress(&r,1,&e)==1);
    memset(&e.victim_pawn,0,sizeof e.victim_pawn);CHECK(!bz_score_should_suppress(&r,1,&e));r=owned();
    e=event();memset(&e.victim_controller,0,sizeof e.victim_controller);memset(&e.victim_pawn,0,sizeof e.victim_pawn);CHECK(!bz_score_should_suppress(&r,1,&e));
    e=event();e.victim_controller=id(999,19,2);e.victim_pawn=id(998,18,1);CHECK(!bz_score_should_suppress(&r,1,&e));
    e=event();r.owner_tag=0;CHECK(!bz_score_should_suppress(&r,1,&e));r=owned();r.enabled=0;CHECK(!bz_score_should_suppress(&r,1,&e));r=owned();
    CHECK(!bz_score_should_suppress(NULL,1,&e));CHECK(!bz_score_should_suppress(&r,1,NULL));CHECK(!bz_score_should_suppress(&r,0,&e));
    CHECK(!bz_score_should_suppress(&r,BZ_SCORE_MAX_OWNED+1,&e));e.boundary=99;CHECK(!bz_score_should_suppress(&r,1,&e));
    printf("%u native score-filter checks passed.\n",checks);return 0;
}
