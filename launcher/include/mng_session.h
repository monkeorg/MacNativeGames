#ifndef MNG_SESSION_H
#define MNG_SESSION_H
#include <stddef.h>
#include <stdint.h>
#define MNG_NATIVE_ABI_V1 1u
#define MNG_SESSION_PLAYERS 8u
#define MNG_NATIVE_EXECUTION_APPROVED 1u
/* This is a trusted host contract, never an assertion read from an imported
 * package. The hash must come from reviewed preparation/allowlisting. */
struct mng_session_manifest {
    uint32_t version, execution_capability;
    uint64_t title_id;
    uint32_t title_version;
    const char *prepared_root, *module_relative_path, *save_root, *profile_id;
    uint64_t module_size;
    unsigned char module_sha256[32];
};
struct mng_session_settings {
    uint32_t size, output_width, output_height, frame_limit;
    uint32_t language, controller_layout;
    float volume;
};
struct mng_player_input {
    uint64_t device_id, buttons;
    float left_x, left_y, right_x, right_y;
    uint32_t connected;
};
struct mng_session_input {
    uint64_t sequence, timestamp_ns;
    struct mng_player_input players[MNG_SESSION_PLAYERS];
};
struct mng_session_host {
    uint32_t size;
    void *context;
    uint64_t (*monotonic_ns)(void *context);
    void (*log)(void *context, uint32_t level, const char *message);
    /* Opaque CAMetalLayer on Apple; NULL for headless native modules. */
    void *graphics_surface;
    /* Mandatory generation lease, acquired before reading and released after
     * destroy/dlclose. Wrap mng_store_pin and close(lease_fd) in the host. */
    int (*retain_prepared)(void *context, const char *prepared_root);
    void (*release_prepared)(void *context, const char *prepared_root);
};
struct mng_native_start {
    uint32_t size;
    uint64_t title_id;
    uint32_t title_version;
    const char *prepared_root, *save_root, *profile_id;
    struct mng_session_settings settings;
    struct mng_session_host host;
};
/* Original host ABI, not a Switch SDK ABI. create failure must release all
 * resources itself. destroy joins every thread and releases callbacks before
 * return. All calls are serialized on the owner's thread; callbacks must not
 * reenter. Inputs are complete snapshots, including explicit disconnects.
 * A zero sequence/timestamp is reserved for host neutral cancellation on pause. */
struct mng_native_module {
    uint32_t abi_version, size;
    uint64_t title_id;
    uint32_t title_version;
    int (*create)(const struct mng_native_start *, void **instance);
    int (*settings)(void *, const struct mng_session_settings *);
    int (*input)(void *, const struct mng_session_input *);
    int (*pause)(void *, int paused);
    int (*tick)(void *, uint64_t monotonic_ns);
    void (*destroy)(void *);
};
typedef const struct mng_native_module *(*mng_native_entry_fn)(void);
/* Export exactly: const struct mng_native_module *canopy_native_module_v1(void); */
struct mng_session;
enum mng_session_result {
    MNG_SESSION_OK=0, MNG_SESSION_INVALID=-1, MNG_SESSION_UNSUPPORTED=-2,
    MNG_SESSION_UNVERIFIED=-3, MNG_SESSION_LOAD_FAILED=-4,
    MNG_SESSION_ABI_MISMATCH=-5, MNG_SESSION_BACKEND_FAILED=-6,
    MNG_SESSION_STALE_INPUT=-7
};
int mng_session_open(const struct mng_session_manifest *, const struct mng_session_host *,
    const struct mng_session_settings *, struct mng_session **out);
int mng_session_update_settings(struct mng_session *, const struct mng_session_settings *);
int mng_session_submit_input(struct mng_session *, const struct mng_session_input *);
int mng_session_pause(struct mng_session *, int paused);
int mng_session_tick(struct mng_session *);
void mng_session_close(struct mng_session *);
#endif
