/* Optional real static NativeAOT consumer. No imported library loading. */
#pragma once
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#include "../../../games/totk/third_party/d2r_gfx/gfx/nvn/totk_shader_provider.h"
/* Main thread, before NVN initialization. Existing private cache and its
 * genuine lease remain owned for the process lifetime. A linked provider
 * uses native-<compiled recipe> below that cache; renderer cwd is unchanged. Unlinked builds do not
 * mutate it. No stop/unseal/relaunch authority is granted. */
int CanopyShaderTranslatorInstall(const char *leasedCache, const char *chain);
void CanopyShaderTranslatorSetActive(int active);
/* Irreversible main-worker end. Later focus events cannot revive jobs. */
void CanopyShaderTranslatorTerminate(void);
const struct totk_shader_provider *CanopyShaderTranslatorProvider(void);
/* Linked provider admission is fixed at 256 full-request/code digests per
 * focus epoch, with at most three actual ABI calls per request. Typed outcome
 * and job ticket are runtime-only facts, never imported JSON authority. */
/* NULL in unlinked builds; identity only, never a device/parity proof. */
const char *CanopyShaderTranslatorRecipe(void);
#endif
