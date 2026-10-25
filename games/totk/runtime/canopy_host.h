/* Original private-host control contract; no game payload. */
#ifndef CANOPY_TOTK_HOST_H
#define CANOPY_TOTK_HOST_H
#include <stdint.h>
#define CANOPY_TOTK_HOST_ABI 1u
struct canopy_totk_start {
    const char *modules, *resources, *index_directory, *romfs_data, *active_saves, *identity, *cache;
    const char *shader_seed, *shader_cache;
    const char *language;
    unsigned fps_limit;
    int taa_enabled, hud_mode;
    void *metal_layer, *host_view, *metal_device;
};
struct canopy_totk_host {
    uint32_t abi_version, size;
    uint64_t title_id;
    const char *game_version;
    /* Reviewed ORIGINAL input identity, not encrypted-package or rewrite SHA. */
    const char *original_main_sha256, *romfs_sha256, *runtime_index_sha256;
    /* NULL means the private signed bundle's GameData directory. Other paths
     * require compiled trusted integration, never imported profile JSON. */
    const char *resource_directory;
    const char *shader_seed_manifest_sha256, *shader_chain;
    /* Trusted caller precondition: shader_seed has completed native manifest
     * and content verification, and its immutable shared lease remains held.
     * The host uses this exact path for private read-in-place attestation. */
    int (*start)(const struct canopy_totk_start *);
    int (*fps_supported)(unsigned);
    void (*set_fps)(unsigned);
    unsigned (*get_fps)(void);
    int (*taa_supported)(void);
    void (*set_taa)(int);
    int (*get_taa)(void);
    int (*get_hud)(void);
    int (*cycle_hud)(void);
    void (*clear_input)(void);
    void (*set_focus)(int);
    /* Native Npad button layout; caller converts the portable router schema. */
    void (*input)(uint64_t,int32_t,int32_t,int32_t,int32_t,int);
};
/* SINGLE USE, process-owned. No safe stop/join/relaunch exists yet. Focus
 * deactivation pauses GPU submission; it does not promise CPU suspension. */
const struct canopy_totk_host *totk_canopy_host_v1(void);
#if defined(CANOPY_HOST_RUNTIME)
/* Run before native graphics initialization. The cache identity uses safe math
 * and the pinned prepared translator outputs, never inherited experiment flags. */
int canopy_host_pin_compile_environment(void);
#endif
#endif
