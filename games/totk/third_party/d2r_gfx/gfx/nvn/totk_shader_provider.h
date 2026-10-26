/* Trusted, process-owned Canopy provider. Never populated from shader JSON. */
#pragma once
#include <stdint.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#define TOTK_SHADER_PROVIDER_ABI 2u
enum totk_shader_outcome {
    TOTK_SHADER_OK=0, TOTK_SHADER_INVALID=1, TOTK_SHADER_OUTPUT_TOO_SMALL=2,
    TOTK_SHADER_TRANSLATION=3, TOTK_SHADER_BUSY=4, TOTK_SHADER_QUOTA=5,
    TOTK_SHADER_CANCELLED=6, TOTK_SHADER_CACHE_IO=7, TOTK_SHADER_METAL=8,
    TOTK_SHADER_READY_LIMIT=9, TOTK_SHADER_ADMISSION_LIMIT=10,
    TOTK_SHADER_BACKOFF=11, TOTK_SHADER_ATTEMPTS_EXHAUSTED=12
};
/* Trusted synchronous operation identity; never decoded from request JSON.
 * Epoch owns publication, ticket rejects stale completion, SHA covers the
 * complete normalized request AND code bytes (not truncated variant names). */
struct totk_shader_job {
    uint64_t epoch,ticket;
    unsigned char request_sha256[32];
    uint32_t outcome;
};
struct totk_shader_provider {
    uint32_t abi, size;
    const char *recipe_sha256, *chain;
    /* Synchronous; returns nil on refusal. Publishes complete payloads only,
     * never an index. Caller retains code/request until this call returns. */
    NSDictionary *(*translate)(NSDictionary *request, NSData *code, struct totk_shader_job *job);
    /* Atomically publishes the final variant index after payload durability. */
    int (*publish_index)(NSString *shader, NSArray *rows, struct totk_shader_job *job);
    void (*failed)(struct totk_shader_job *job, enum totk_shader_outcome outcome);
    int (*is_current)(uint64_t epoch);
    /* Separate retry scheduling, NOT successful translation/readiness proof. */
    uint64_t (*retry_token)(void);
    NSString *(*file)(NSString *name);
    NSArray<NSString *> *(*files)(void);
};
#endif
