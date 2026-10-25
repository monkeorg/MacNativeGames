#include "mng_game_profile.h"
#include <string.h>
#include "mng_game_profile_data.inc"
size_t mng_game_profile_count(void) {
    return sizeof(game_profiles) / sizeof(*game_profiles);
}
const struct mng_game_profile *mng_game_profile_at(size_t index) {
    return index < mng_game_profile_count() ? game_profiles + index : NULL;
}
const struct mng_game_profile *mng_game_profile_for_title(uint64_t title) {
    for (size_t i = 0; i < mng_game_profile_count(); i++)
        if (game_profiles[i].title_id == title) return game_profiles + i;
    return NULL;
}
static int known(const struct mng_game_profile *profile) {
    for (size_t i = 0; i < mng_game_profile_count(); i++)
        if (profile == game_profiles + i) return 1;
    return 0;
}
const struct mng_game_version *mng_game_version_for_revision(const struct mng_game_profile *profile, uint32_t revision) {
    if (!known(profile)) return NULL;
    for (size_t i = 0; i < profile->version_count; i++)
        if (profile->versions[i].title_version == revision) return profile->versions + i;
    return NULL;
}
const struct mng_game_version *mng_game_version_for_alias(const struct mng_game_profile *profile, const char *alias) {
    if (!known(profile) || !alias) return NULL;
    for (size_t i = 0; i < profile->version_count; i++)
        if (!strcmp(profile->versions[i].alias, alias)) return profile->versions + i;
    return NULL;
}
