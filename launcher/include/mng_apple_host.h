/* Original additive Apple host boundary. No title code or imported approval. */
#ifndef MNG_APPLE_HOST_H
#define MNG_APPLE_HOST_H
#include <stddef.h>
#include <stdint.h>
#include "mng_session.h"
#define MNG_APPLE_HOST_ABI 1u
#define MNG_APPLE_HOST_MODULES 3u
enum mng_apple_status { MNG_APPLE_OK=0, MNG_APPLE_INVALID=-1,
    MNG_APPLE_IO=-2, MNG_APPLE_CANCELLED=-3, MNG_APPLE_UNSUPPORTED=-4 };
enum mng_apple_main_phase { MNG_APPLE_NOT_STARTED=0, MNG_APPLE_RUNNING=1,
    MNG_APPLE_CLEANUP_OBSERVED=2, MNG_APPLE_JOINED=3, MNG_APPLE_OBSERVATION_FAILED=4, MNG_APPLE_PROVIDER_FAILED=5 };
enum mng_apple_provider_error { MNG_APPLE_PROVIDER_NONE=0,
    MNG_APPLE_PROVIDER_UNIMPLEMENTED_SERVICE=1,
    MNG_APPLE_PROVIDER_CONTROLLER_UNAVAILABLE=2 };
struct mng_apple_module_pin { const char *name,*original_sha256,*build_id; };
struct mng_apple_prepared;
struct mng_apple_prepare {
    uint32_t abi,size;
    const char *generation,*resources,*active_saves,*identity,*cache,*language;
    void *metal_device; /* Borrowed strong owner lives through this operation. */
    int (*cancelled)(void *); void *cancel_context;
};
struct mng_apple_start {
    uint32_t abi,size;
    struct mng_apple_prepared *prepared;
    void *metal_device,*metal_layer,*host_view;
};
struct mng_apple_lifecycle {
    uint32_t abi,size,phase,main_returned,main_joined,join_error;
    int32_t main_return_code;
    uint32_t provider_error; /* enum mng_apple_provider_error, not a guest SDK Result. */
};
struct mng_apple_host {
    uint32_t abi,size;
    uint64_t title_id,romfs_size;
    uint32_t title_version,max_players,module_count;
    const char *game_version,*romfs_sha256,*source_recipe_sha256;
    const char *shader_manifest_sha256,*shader_chain,*native_manifest_sha256;
    /* NULL means the private bundle's GameData/MK8DX. Compiled authority only. */
    const char *resource_directory;
    struct mng_apple_module_pin modules[MNG_APPLE_HOST_MODULES];
    /* Worker-only, read/derive private assets. No guest entry, Metal compilation
     * or service callbacks. The caller retains its fully verified generation
     * lease and exact device. Refusal must return no prepared context. */
    int (*prepare)(const struct mng_apple_prepare *,struct mng_apple_prepared **);
    /* Only before invoking start; never used to imply native teardown. */
    void (*release_prepared)(struct mng_apple_prepared *);
    /* Main-only single-use handoff. Once invoked ALL context/leases/protections
     * remain owned even on failure. There is deliberately no destroy/relaunch. */
    int (*start)(const struct mng_apple_start *);
    int (*read_lifecycle)(struct mng_apple_lifecycle *);
    void (*clear_input)(void);
    int (*set_focus)(int);
    /* Complete portable snapshot; no controller merge or seat renumbering.
     * Monotonic host time, identity changes and cancellation remain explicit. */
    int (*submit_players)(const struct mng_session_input *,uint64_t now_ns);
    /* Main-only presentation sizing, not guest scene-resolution measurement. */
    int (*update_layout)(double width,double height,double scale);
};
/* Public host links NULL. A private builder supplies an exact strong provider.
 * Prepared JSON, environment variables and title labels never grant this ABI. */
const struct mng_apple_host *canopy_mk8dx_host_v1(void);
#endif
