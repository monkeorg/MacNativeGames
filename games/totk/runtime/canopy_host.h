/* Original private-host control contract; no game payload. */
#ifndef CANOPY_TOTK_HOST_H
#define CANOPY_TOTK_HOST_H
#include <stdint.h>
#include "mng_display.h"
#define CANOPY_TOTK_HOST_ABI 3u
struct canopy_totk_start {
    const char *modules, *resources, *index_directory, *romfs_data, *active_saves, *identity, *cache;
    const char *shader_seed, *shader_cache;
    const char *language;
    unsigned fps_limit;
    int taa_enabled, hud_mode;
    void *metal_layer, *host_view, *metal_device;
    struct mng_display_config display;
};
struct canopy_totk_display {
    uint32_t abi_version,size;
    struct mng_display_profile profile;
    /* Exact generated manifest pins; NULL for stock. Actual overlay members
     * are verified by the native RomFS overlay consumer before use. */
    const char *heap_manifest_sha256,*layout_manifest_sha256;
    int (*read_state)(struct mng_display_state *);
};
#define CANOPY_TOTK_LIFECYCLE_ABI 1u
enum canopy_totk_main_phase {
    CANOPY_TOTK_MAIN_NOT_STARTED=0,
    CANOPY_TOTK_MAIN_RUNNING=1,
    CANOPY_TOTK_MAIN_CLEANUP_OBSERVED=2,
    CANOPY_TOTK_MAIN_JOINED=3,
    CANOPY_TOTK_MAIN_OBSERVATION_FAILED=4
};
/* Observation only: even MAIN_JOINED + zero children is not whole-runtime
 * teardown. The process-owned watcher, guest reaper, GPU/audio/IPC helpers,
 * dispatch jobs, module mappings and all session protections remain owned.
 * main_return_code is meaningful only when main_returned==1; otherwise zero.
 * main_joined becomes true only after pthread_join, including TLS destructors.
 */
struct canopy_totk_lifecycle_state {
    uint32_t abi,size,phase,main_returned,main_joined,join_error;
    uint32_t owned_guest_children,joining_guest_children,guest_join_failures,guest_admission_closed;
    int32_t main_return_code;
};
struct canopy_totk_lifecycle {
    uint32_t abi_version,size;
    int (*read_state)(struct canopy_totk_lifecycle_state *);
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
    struct canopy_totk_display display;
    struct canopy_totk_lifecycle lifecycle;
};
/* Additive data-bearing host wrapper. ABI3 byte layout and legacy accessor are
 * unchanged. A present invalid v4 descriptor is a refusal, never a v3 fallback. */
#define CANOPY_TOTK_HOST_V4_ABI 4u
#define CANOPY_TOTK_GAME_DATA_ABI 1u
struct canopy_totk_game_data {
    uint32_t abi_version,size;
    const char *manifest_sha256;
    int (*prepare)(int resources_fd,int (*cancelled)(void *),void *cancel_context,void **out);
    void (*release)(void *prepared); /* Pre-entry only. */
    int (*install)(void *prepared); /* Main-only, no I/O; consumes lifetime. */
};
struct canopy_totk_host_v4 {
    uint32_t abi_version,size;
    const struct canopy_totk_host *legacy;
    struct canopy_totk_game_data game_data;
};
const struct canopy_totk_host_v4 *totk_canopy_host_v4(void);
/* SINGLE USE, process-owned. No safe stop/join/relaunch exists yet. Focus
 * deactivation pauses GPU submission; it does not promise CPU suspension. */
const struct canopy_totk_host *totk_canopy_host_v1(void);
#if defined(CANOPY_HOST_RUNTIME)
/* Run before native graphics initialization. The cache identity uses safe math
 * and the pinned prepared translator outputs, never inherited experiment flags. */
int canopy_host_pin_compile_environment(void);
/* Compiled/link-present identity only. NULL means seed-only; never parity,
 * hard compiler isolation, gameplay or signed-device acceptance evidence. */
const char *canopy_host_shader_translator_recipe(void);
/* Called only after actual loader runtime_game_patches returns successfully.
 * Signals checked patch execution, never a rendered frame or visual acceptance. */
void canopy_host_game_patches_validated(void);
/* Main-thread query; caller initializes state ABI/size. NOT_CONFIGURED does
 * not become pending/validated merely because a callback ran. */
int canopy_host_read_display_state(struct mng_display_state *);
/* Main-thread strict ABI/size query; output unchanged on error. Available in
 * the actual iPhoneOS worker component (and its native original-source probe).
 * This never grants stop, unseal, destruction or relaunch capability. */
int canopy_host_read_lifecycle_state(struct canopy_totk_lifecycle_state *);
#endif
#endif
