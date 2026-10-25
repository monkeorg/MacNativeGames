/* Trusted, process-owned Canopy provider. Never populated from shader JSON. */
#pragma once
#include <stdint.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#define TOTK_SHADER_PROVIDER_ABI 1u
struct totk_shader_provider {
    uint32_t abi, size;
    const char *recipe_sha256, *chain;
    /* Synchronous; returns nil on refusal. Publishes complete payloads only,
     * never an index. Caller retains code/request until this call returns. */
    NSDictionary *(*translate)(NSDictionary *request, NSData *code, uint64_t *epoch);
    /* Atomically publishes the final variant index after payload durability. */
    int (*publish_index)(NSString *shader, NSArray *rows, uint64_t epoch);
    int (*is_current)(uint64_t epoch);
    NSString *(*file)(NSString *name);
    NSArray<NSString *> *(*files)(void);
};
#endif
