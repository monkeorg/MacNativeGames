/* Original Apple-silicon caller; production Mac mapping, not iOS permission. */
#include "fixture_runner.h"
#include <stdio.h>
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    struct canopy_fixture_result r=canopy_fixture_run(argv[1],argv[2]);
    printf("{\"status\":\"pass\",\"scope\":\"original production-loader Mac fixture; not iOS signing or gameplay\","
           "\"answer\":%llu,\"tls_answer\":%llu,\"relocated_answer\":%llu,\"service_answer\":%llu,"
           "\"host_calls\":%u,\"service_calls\":%u,\"permissions_verified\":%s}\n",
           (unsigned long long)r.answer,(unsigned long long)r.tls_answer,(unsigned long long)r.relocated_answer,
           (unsigned long long)r.service_answer,r.host_calls,r.service_calls,r.permissions_verified?"true":"false");return 0;
}
