#ifndef MNG_DISPLAY_H
#define MNG_DISPLAY_H
#include <stdint.h>
#define MNG_DISPLAY_ABI 1u
#define MNG_DISPLAY_SCENE_1080 1u
#define MNG_DISPLAY_FOUR_THREE 2u
#define MNG_DISPLAY_HEAP_MANIFEST "romfs-patches-out/1920x1080-scene-1920x1080/manifest.tsv"
#define MNG_DISPLAY_LAYOUT_MANIFEST "romfs-patches-4x3/manifest.tsv"
enum mng_display_aspect { MNG_DISPLAY_16_9=0, MNG_DISPLAY_FULL=1 };
enum mng_display_outcome { MNG_DISPLAY_SUPPORTED=0, MNG_DISPLAY_UNSUPPORTED=1 };
enum mng_display_validation { MNG_DISPLAY_NOT_CONFIGURED=0, MNG_DISPLAY_PENDING=1, MNG_DISPLAY_PATCHES_VALIDATED=2 };
/* Trusted compiled native capability, never an imported preference/profile.
 * FOUR_THREE requires SCENE_1080 and the existing checked v143 Vert+ profile. */
struct mng_display_profile {uint32_t abi,size,flags;};
/* Selected scene/canvas target, not measured GPU allocation or throughput.
 * Both sizes match in the explicit v143 profile. Stock may dynamically scale
 * its scene below720; fixed_resolution distinguishes that stock behavior.
 * Full4:3 remains experimental because existing Vert+ UI-effect issues persist. */
struct mng_display_config {
    uint32_t abi,size,width,height,aspect,experimental,fixed_resolution;
};
struct mng_display_resolution {
    struct mng_display_config config;
    uint32_t height_outcome,aspect_outcome;
};
struct mng_display_state {
    uint32_t abi,size,validation;
    struct mng_display_config config;
};
/* Heights720/1080 and aspect16:9/full only. Invalid fields/nonfinite or
 * nonpositive view sizes return-1 and leave output untouched. View dimensions
 * are actual ORIENTED view dimensions (no portrait/landscape swapping), <=32768.
 * Full applies only at exact4:3 with trusted capability. Unsupported requested
 * settings resolve explicitly to supported720/16:9 defaults with outcome flags;
 * callers must report those flags, never silently call the request applied.
 * Does not write env, inspect files, patch code, resize drawables or infer FPS. */
int mng_display_resolve(const struct mng_display_profile *,uint32_t requested_height,
    uint32_t requested_aspect,double view_width,double view_height,struct mng_display_resolution *);
/* Validate a resolved config against actual view + compiled capability. */
int mng_display_check(const struct mng_display_profile *,const struct mng_display_config *,double view_width,double view_height);
#endif
