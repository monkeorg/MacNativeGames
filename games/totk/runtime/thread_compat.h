#pragma once
#include "runtime.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define LOG(...) do {fprintf(stderr,"[totk-thread] " __VA_ARGS__);fputc('\n',stderr);}while(0)
#define die(...) do {LOG(__VA_ARGS__);runtime_fail("thread runtime failure");}while(0)
#define now_ns runtime_now_ns
#define guest_ns runtime_now_ns
#define guest_sym runtime_symbol
#define guest_thread_init runtime_thread_init
static inline int dm_detclock_enabled(void) {return 0;}
void dm_thread_enter(uint64_t entry,uint64_t arg,uint64_t sp,uint64_t *host_context);

#if defined(CANOPY_HOST_RUNTIME)
/* Only guest children created by CreateThread are owned here. Main, the
 * process-lifetime reaper, GPU/audio/IPC helpers and other host workers are
 * excluded. Zero children is never evidence of whole-runtime teardown.
 * Closing admission is irreversible for this single-use process. Existing
 * guests must exit naturally via ExitThread; no exit or wake is injected.
 * Drain accepts at most one second of condition-wait budget per call and only
 * succeeds after actual
 * pthread_join (including TLS destructors). A timeout retains all ownership.
 * Drain is host-only: a guest cannot drain itself. Caller initializes abi/size.
 */
#define CANOPY_THREADS_ABI 1u
#define CANOPY_THREADS_MAX_CHILDREN 4095u
struct canopy_threads_state {
    uint32_t abi, size, admission_closed, owned_children, joining_children;
    uint32_t join_failures;
    uint64_t joined_children;
};
void runtime_canopy_threads_close_admission(void);
int runtime_canopy_threads_snapshot(struct canopy_threads_state *state);
/* 1: admission closed and all owned children joined; 0: pending; -1: invalid.
 * Only this child registry has drained, never the complete runtime. */
int runtime_canopy_threads_drain(uint64_t wait_ns, struct canopy_threads_state *state);
#endif
