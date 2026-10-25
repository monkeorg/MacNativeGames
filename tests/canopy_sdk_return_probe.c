/* Original native C signature fixture. No private SDK, code or addresses. */
#include "canopy_sdk_return.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned started,ready_called,inits_called,finis_called;
static int result=-123;
static pthread_key_t key;
static _Atomic int tls_destroyed;
static int retained_resource=17;
static void check(int value,const char *message) {if(!value){fprintf(stderr,"FAIL: %s\n",message);exit(2);}}
static void ready(void) {ready_called++;}
static void inits(void) {inits_called++;}
static void finis(void) {finis_called++;}
static void arguments(uint64_t handle,uint64_t argument,canopy_sdk_callback r,canopy_sdk_callback i,canopy_sdk_callback f) {
    check(handle==UINT64_C(0xfedcba9876543210) && !argument,"unaltered handle and zero argument");
    check(r==ready && i==inits && f==finis,"unaltered callback pointers");started++;
}
static void returning_start(uint64_t handle,uint64_t argument,canopy_sdk_callback r,canopy_sdk_callback i,canopy_sdk_callback f) {
    arguments(handle,argument,r,i,f);
    /* Fixture-owned behavior, not a statement about Nintendo SDK ordering. */
    r();i();
}
static void exiting_start(uint64_t handle,uint64_t argument,canopy_sdk_callback r,canopy_sdk_callback i,canopy_sdk_callback f) {
    arguments(handle,argument,r,i,f);pthread_exit(NULL);
}
static void tls_destructor(void *value) {check(value==&retained_resource,"TLS resource identity");atomic_store(&tls_destroyed,1);}
static void *worker(void *unused) {
    (void)unused;check(!pthread_setspecific(key,&retained_resource),"owned TLS");
    result=canopy_call_sdk_start(exiting_start,UINT64_C(0xfedcba9876543210),ready,inits,finis);
    return NULL;
}
int main(int argc,char **argv) {
    check(argc==2,"scenario");
    if(!strcmp(argv[1],"return")) {
        result=canopy_call_sdk_start(returning_start,UINT64_C(0xfedcba9876543210),ready,inits,finis);
        check(result==CANOPY_LOADER_UNEXPECTED_SDK_RETURN && result!=CANOPY_LOADER_OK,"natural return is named host error");
        check(started==1 && ready_called==1 && inits_called==1 && !finis_called,"only SDK fixture invokes callbacks");
    } else {
        check(!strcmp(argv[1],"pthread-exit"),"known scenario");
        check(!pthread_key_create(&key,tls_destructor),"TLS key");pthread_t thread;
        check(!pthread_create(&thread,NULL,worker,NULL),"native worker");check(!pthread_join(thread,NULL),"actual join");
        check(atomic_load(&tls_destroyed) && result==-123 && started==1,"pthread_exit does not fall through to returned status");
        check(!ready_called && !inits_called && !finis_called,"adapter does not inject callbacks on thread exit");
        check(!pthread_key_delete(key),"TLS key release");
    }
    check(retained_resource==17,"adapter retains resource state");
    puts("{\"status\":\"pass\",\"scope\":\"original native SDK-signature fixture; no private SDK or teardown proof\"}");return 0;
}
