// In-process adapter to pinned Apache-2.0 SPIRV-Cross. No translator copied.
#include "inprocess_cross.h"
#include "canopy_cross_budget.hpp"
#include "spirv_msl.hpp"
#include <cstring>
#include <vector>
extern "C" int canopy_spirv_cross(const uint8_t *input, size_t length,
    uint8_t *output, size_t capacity, size_t *out_length) {
    return canopy_spirv_cross_controlled(input,length,output,capacity,out_length,nullptr,nullptr);
}
extern "C" int canopy_spirv_cross_controlled(const uint8_t *input,size_t length,
    uint8_t *output,size_t capacity,size_t *out_length,canopy_budget_checkpoint checkpoint,void *context) {
    if (!out_length) return 1;
    *out_length = 0;
    if (!input || length < 20 || length > (4u << 20) || (length & 3) ||
        (!output && capacity) || capacity > (8u << 20)) return 1;
    try {
        canopy_cross_budget::scope budget(checkpoint,context);
        canopy_cross_budget::step(1,0,length);
        // memcpy avoids requiring alignment of caller-owned input.
        std::vector<uint32_t> words(length / 4);
        for (size_t i=0;i<words.size();i++) {
            const uint8_t *p=input+4*i;
            words[i]=uint32_t(p[0])|(uint32_t(p[1])<<8)|(uint32_t(p[2])<<16)|(uint32_t(p[3])<<24);
        }
        if (words[0] != 0x07230203u || words[3] > 262144u) return 1;
        spirv_cross::CompilerMSL compiler(std::move(words));
        auto options=compiler.get_msl_options();
        options.msl_version=20300;
        options.argument_buffers=true;
        options.texture_buffer_native=true;
        options.pad_fragment_output_components=true;
        compiler.set_msl_options(options);
        std::string text=compiler.compile();
        if (text.size() > (8u << 20)) return 3;
        *out_length=text.size();
        if (capacity < text.size()) return 2;
        if (!text.empty()) std::memcpy(output,text.data(),text.size());
        return 0;
    } catch (const canopy_cross_budget::failure &stop) { *out_length=0;return stop.status; }
      catch (...) { *out_length=0;return 3; }
}
