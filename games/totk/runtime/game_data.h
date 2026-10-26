/* Original runtime-data boundary, adapted from upstream f541e14e. No payload. */
#pragma once
#include "runtime.h"
#include <stddef.h>
#include <stdint.h>
#define RUNTIME_GAME_DATA_FILES 4u
struct RuntimeGameData;
/* Worker-only snapshot: exact fixed files under resources/runtime-data. The
 * compiled manifest pin authenticates the manifest, never imported metadata.
 * expected RomFS/index pins remain independent reviewed input authority. */
int runtime_game_data_prepare_fd(int resources,const char *manifest_sha256,
    const char *expected_romfs,const char *expected_index,
    int (*cancelled)(void *),void *context,struct RuntimeGameData **out);
void runtime_game_data_release(struct RuntimeGameData *);
/* Installs once, before starting the native worker. Caller retains it through
 * every native owner. No file reopen or environment lookup after installation. */
int runtime_game_data_install(struct RuntimeGameData *);
int runtime_game_data_is_installed(void);
void runtime_game_data_modules(Module out[3],uint64_t *probe_plt,uint64_t *probe_slot);
/* Legacy Mac uses the original upstream override/default resource path. Canopy
 * resource builds require an installed context and never fall back to paths. */
void runtime_game_data_path(const char *name,char *out,size_t capacity);
const char *runtime_game_text(const char *file,const char *key);
uint64_t runtime_game_number(const char *file,const char *key);
const char *runtime_game_sha256(const char *file,const char *key);
