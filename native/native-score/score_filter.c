#include "score_filter.h"

static int valid_id(BzObjectId id) {
    return id.address != (uintptr_t)0 && id.object_index >= 0 && id.serial > 0;
}
int bz_score_id_equal(BzObjectId a, BzObjectId b) {
    return valid_id(a) && valid_id(b) && a.address == b.address &&
        a.object_index == b.object_index && a.serial == b.serial;
}
int bz_score_should_suppress(const BzScoreOwned *owned, size_t count, const BzScoreEvent *event) {
    size_t i;
    if (!owned || !event || count == 0 || count > BZ_SCORE_MAX_OWNED ||
        event->boundary < BZ_SCORE_NOTIFY_KILLED || event->boundary > BZ_SCORE_OBJECTIVE_RULE ||
        event->variant_active != 1 || event->authority != 1 || event->game_thread != 1 || event->epoch == 0 ||
        !valid_id(event->world) || !valid_id(event->authority_game_mode) ||
        event->victim_controller_is_live != 1 || !valid_id(event->victim_controller) ||
        event->victim_is_player_controller != 0) return 0;
    for (i = 0; i < count; ++i) {
        const BzScoreOwned *record = &owned[i];
        int controller_matches;
        int pawn_matches;
        if (record->owner_tag != BZ_SCORE_OWNER_TAG || record->enabled != 1 || record->epoch != event->epoch ||
            !bz_score_id_equal(record->world, event->world) ||
            !bz_score_id_equal(record->authority_game_mode, event->authority_game_mode) || !valid_id(record->pawn)) continue;
        controller_matches = bz_score_id_equal(record->controller, event->victim_controller);
        pawn_matches = event->victim_pawn_is_live == 1 && bz_score_id_equal(record->pawn, event->victim_pawn);
        /* A still-possessed controller must own the recorded pawn right now.
         * Once unpossessed, only an exact previously bound controller is enough.
         * A newly spawned, not-yet-bound controller is accepted by current Pawn. */
        if (event->victim_pawn.address != (uintptr_t)0) {
            if (!pawn_matches) continue;
            if (valid_id(record->controller) && !controller_matches) continue;
            return 1;
        }
        if (controller_matches) return 1;
    }
    return 0;
}
