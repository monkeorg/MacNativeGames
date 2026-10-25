/* Original engineering result; not a game compatibility or signing assertion. */
#ifndef CANOPY_FIXTURE_RUNNER_H
#define CANOPY_FIXTURE_RUNNER_H
#include <stdint.h>
struct canopy_fixture_result {
    uint64_t answer,tls_answer,relocated_answer,service_answer;
    unsigned host_calls,service_calls,permissions_verified;
};
/* Single-use, synchronous; all instructions and module metadata are original.
 * Production fatal checks remain fatal. Negative cases run in fresh processes.
 * iPhoneOS maps signed embedded sections; Mac maps the original rewritten file.
 * Neither path establishes external imported-code permission on iPhoneOS. */
struct canopy_fixture_result canopy_fixture_run(const char *rewritten,const char *scenario);
#endif
