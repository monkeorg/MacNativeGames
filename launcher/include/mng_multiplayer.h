#ifndef MNG_MULTIPLAYER_H
#define MNG_MULTIPLAYER_H
#include "mng_session.h"
#include <stddef.h>
#include <stdint.h>
#define MNG_MULTIPLAYER_MAX 4u
#define MNG_MULTIPLAYER_HISTORY 16u
/* Exact FullKey state layout already consumed by runtime/input.c. This is a
 * guest HID ABI, not a title-address/profile format or shared-memory emulator. */
struct mng_npad_fullkey_state {
    int64_t sampling;
    uint64_t buttons;
    int32_t lx,ly,rx,ry;
    uint32_t attributes,reserved;
};
struct mng_multiplayer;
enum mng_multiplayer_status {
    MNG_MULTIPLAYER_OK=0,MNG_MULTIPLAYER_INVALID=-1,MNG_MULTIPLAYER_STALE=-2,
    MNG_MULTIPLAYER_BUSY=-3,MNG_MULTIPLAYER_LIMIT=-4
};
int mng_multiplayer_create(unsigned capacity,struct mng_multiplayer **out);
/* Stop host API callers before destroy. Concurrent bound guest calls finish
 * before detach; later calls return neutral/no states without touching freed
 * memory. This does not stop native title CPU threads. */
void mng_multiplayer_destroy(struct mng_multiplayer *);
/* Complete host snapshots; no merging/assignment occurs here. Nonzero normal
 * sequence increases, timestamps do not regress and must be within250ms of now.
 * Zero sequence/time is reserved for an entirely neutral owner cancellation.
 * Home/capture are system actions and cannot be presented as Npad game bits. */
int mng_multiplayer_submit(struct mng_multiplayer *,const struct mng_session_input *,uint64_t now_ns);
void mng_multiplayer_initialize(struct mng_multiplayer *);
/* Public SDK IDs0..7,handheld0x20/other0x10 accepted as filters; this service
 * implements only capacity<=4 FullKey IDs0..3. Unsupported styles stay absent. */
int mng_multiplayer_supported_ids(struct mng_multiplayer *,const uint32_t *,size_t count);
void mng_multiplayer_supported_styles(struct mng_multiplayer *,uint32_t styles);
uint32_t mng_multiplayer_style(struct mng_multiplayer *,uint32_t id);
int mng_multiplayer_states(struct mng_multiplayer *,struct mng_npad_fullkey_state *,int maximum,uint32_t id);
void mng_multiplayer_disconnect(struct mng_multiplayer *,uint32_t id);
/* Exact SDK-symbol override bridge. One binding per linked implementation;
 * the host separately enforces one active title in its process.
 * bind refuses replacing another owner. Getter signatures match runtime/input.c:
 * int states(out,int,const uint32_t *); uint32_t style(const uint32_t *).
 * Guest pointers must be valid caller-owned memory. No IPC or network emulation.
 * Resolver returns NULL for unimplemented services, including controller applet,
 * Joy-Con,motion,vibration,LDN/online. Never claim success for missing services. */
typedef void (*mng_multiplayer_guest_fn)(void);
int mng_multiplayer_bind(struct mng_multiplayer *);
int mng_multiplayer_unbind(struct mng_multiplayer *);
mng_multiplayer_guest_fn mng_multiplayer_override(const char *name);
#endif
