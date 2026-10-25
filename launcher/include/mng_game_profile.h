#ifndef MNG_GAME_PROFILE_H
#define MNG_GAME_PROFILE_H
#include <stddef.h>
#include <stdint.h>
enum mng_game_native_adapter {MNG_GAME_NATIVE_NONE=0,MNG_GAME_NATIVE_ARM64_ABI3=1};
enum mng_game_build_adapter {MNG_GAME_BUILD_NONE=0,MNG_GAME_BUILD_TOTK_IOS26=1};
enum mng_game_save_validator {MNG_GAME_SAVE_NONE=0,MNG_GAME_SAVE_TOTK_STRUCTURAL=1};
/* Reviewed metadata only. A row is NOT a native provider, editor, executable,
 * signature check or device acceptance. Runtime must still require actual
 * compiled callbacks, asset pins and device capabilities. No JSON is loaded. */
struct mng_game_version {
    const char *alias,*display_version,*expected_manifest,*compile_define,*patch_source,*display_profile;
    const char *manifest_sha256,*original_main_sha256,*romfs_sha256;
    uint32_t title_version,display_flags;
    uint64_t romfs_size;
};
struct mng_game_profile {
    const char *game_id,*display_name,*source_directory,*default_version;
    uint64_t title_id;
    uint32_t native_adapter,build_adapter,save_validator,max_players;
    const char *const *modules;
    size_t module_count;
    const struct mng_game_version *versions;
    size_t version_count;
};
size_t mng_game_profile_count(void);
const struct mng_game_profile *mng_game_profile_at(size_t index);
const struct mng_game_profile *mng_game_profile_for_title(uint64_t title_id);
/* Profile must be returned by this module. Unknowns return NULL; no fallback
 * guessed version or title, no BOTW/mod registration and no external table. */
const struct mng_game_version *mng_game_version_for_revision(const struct mng_game_profile *,uint32_t revision);
const struct mng_game_version *mng_game_version_for_alias(const struct mng_game_profile *,const char *alias);
#endif
