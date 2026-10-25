/* Original fixture caller of the SAME module mechanics as runtime/loader.c.
 * The only service implementation below is fixture-owned; it is not Horizon.
 * runtime/gate.S is linked unchanged. No copied mapper or relocation writes. */
#include "fixture_runner.h"
#include "runtime.h"
#include <TargetConditionals.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include "mach_vm_compat.h"
#include "fixture_module.h"
#define NM (sizeof(modules)/sizeof(modules[0]))
pthread_key_t runtime_keys[8];
/* The unchanged production assembly reads this offset. This fixture supplies
 * its own sole host stack; it does not replace or test the HLE thunk registry. */
uint64_t runtime_hle_tsd_off;
static uint64_t timer_calls,svc_calls;
static struct canopy_fixture_result observed;
static uintptr_t expected_return;
_Noreturn void runtime_fail(const char *message) {
    fprintf(stderr,"FIXTURE_FAILURE %s\n",message);exit(2);
}
static void need(bool condition,const char *message){if(!condition)runtime_fail(message);}
#include "loader_module_core.h"
void *runtime_symbol(const char *name){for(unsigned i=0;i<NM;i++){void *p=module_symbol(modules+i,name);if(p)return p;}return NULL;}
/* There are no host imports in this original module. Unexpected import/wrapper
 * calls must fail rather than substituting an untested host implementation. */
void *runtime_override(const char *name){(void)name;runtime_fail("unexpected fixture host import");}
void *runtime_observer(const char *name){(void)name;runtime_fail("unexpected fixture observer");}
void *runtime_hle_wrap_named(void *target,const char *name){(void)target;(void)name;runtime_fail("unexpected fixture HLE wrapper");}
uint64_t runtime_svc(unsigned number,uint64_t *regs,const char *module,uint64_t original) {
    need(number==1&&!strcmp(module,"fixture")&&original==0x1c0,"fixture service gate identity");
    need(regs[0]==11&&regs[1]==22&&regs[2]==33&&regs[3]==44,"fixture service argument preservation");
    observed.service_calls++;regs[0]+=100;return 0;
}
__attribute__((noinline)) static uint64_t host_target(uint64_t a,uint64_t b,uint64_t c,uint64_t d) {
    need((uintptr_t)__builtin_return_address(0)==expected_return,"fixture host return address");
    need(a==10&&b==2&&c==3&&d==4,"fixture indirect host arguments");
    observed.host_calls++;return a+7;
}
struct canopy_fixture_result canopy_fixture_run(const char *rewritten,const char *scenario) {
    static int invoked;need(!invoked++,"fixture is single-use");need(rewritten&&scenario,"fixture arguments");
    need(sysconf(_SC_PAGESIZE)==0x4000,"fixture requires native 16 KiB Apple pages");
    Module *module=modules;Reloc invalid=fixture_relocs[0];
    if(!strcmp(scenario,"bad-digest")) {
#if TARGET_OS_IPHONE
        runtime_fail("Mac-only digest negative case");
#else
        module->digest="0000000000000000000000000000000000000000000000000000000000000000";
#endif
    } else if(!strcmp(scenario,"bad-layout"))module->key_off=1;
    else if(!strcmp(scenario,"bad-relocation")){invalid.where=0;module->relocs=&invalid;}
    else need(!strcmp(scenario,"positive")||!strcmp(scenario,"bad-gate"),"unknown fixture scenario");
    unsigned created=0;for(;created<8;created++)need(!pthread_key_create(runtime_keys+created,NULL),"fixture TLS key");
    pthread_key_t host_key;need(!pthread_key_create(&host_key,NULL),"fixture host stack key");
    runtime_hle_tsd_off=(uint64_t)host_key*8;
    void *stack=malloc(65536);need(stack!=NULL,"fixture host stack allocation");
    uintptr_t top=((uintptr_t)stack+65536)&~(uintptr_t)15;
    need(!pthread_setspecific(host_key,(void *)top),"fixture host stack binding");
    need(!pthread_setspecific(runtime_keys[0],(void *)host_target)&&
         !pthread_setspecific(runtime_keys[1],(void *)(uintptr_t)0x12345678)&&
         !pthread_setspecific(runtime_keys[3],(void *)runtime_gate),"fixture thread slots");
    uintptr_t tsd;__asm__ volatile("mrs %0,tpidrro_el0":"=r"(tsd));
    need(tsd&&!(tsd&7),"fixture Darwin TSD alignment");
    for(unsigned i=0;i<8;i++)need(((uintptr_t *)tsd)[runtime_keys[i]]==(uintptr_t)pthread_getspecific(runtime_keys[i]),"fixture actual Darwin TSD layout");
    need(((uintptr_t *)tsd)[host_key]==top,"fixture host stack TSD layout");
    map_module(module,rewritten);relocate(module);seal(module);check_permissions(module);observed.permissions_verified=1;
    if(!strcmp(scenario,"bad-gate")){uint64_t regs[31]={0};runtime_dispatch((uintptr_t)module->base,regs);runtime_fail("invalid gate accepted");}
    need(module->relative==1&&module->symbolic==0,"fixture actual relocation counters");
#if TARGET_OS_IPHONE
    unsigned long count=0;const uint8_t *original=getsectiondata(&_mh_execute_header,"__TOTKfixtureW","__img",&count);
    uint64_t original_pointer=0,original_data=0;
    need(original&&count>=0x4010,"fixture signed data section");
    memcpy(&original_pointer,original+0x4000,8);memcpy(&original_data,original+0x4008,8);
    need(original_pointer==0x140&&original_data==UINT64_C(0x123456789abcdef0),"fixture relocation COW isolation");
#endif
    expected_return=(uintptr_t)module->base+0x118;
    void *entry=runtime_symbol("fixture_entry"),*tls=runtime_symbol("fixture_tls"),*service=runtime_symbol("fixture_service");
    need(entry&&tls&&service&&runtime_symbol("fixture_helper"),"fixture production symbol lookup");
    observed.answer=((uint64_t(*)(uint64_t,uint64_t,uint64_t,uint64_t))entry)(10,2,3,4);
    observed.tls_answer=((uint64_t(*)(void))tls)();
    uintptr_t relocated;memcpy(&relocated,module->base+0x8000,8);
    need(relocated==(uintptr_t)runtime_symbol("fixture_helper"),"fixture production relative relocation");
    observed.relocated_answer=((uint64_t(*)(uint64_t))relocated)(20);
    observed.service_answer=((uint64_t(*)(uint64_t,uint64_t,uint64_t,uint64_t))service)(11,22,33,44);
    need(observed.answer==17&&observed.tls_answer==0x12345678&&observed.relocated_answer==27&&observed.service_answer==111&&
         observed.host_calls==1&&observed.service_calls==1&&svc_calls==1&&!timer_calls,"fixture native results");
    need(pthread_getspecific(host_key)==(void *)top,"fixture production gate restored host stack slot");
    /* Only this isolated fixture owns these resources; no runtime teardown or
     * commercial module unloading contract is inferred from its cleanup. */
    for(unsigned i=0;i<8;i++){need(!pthread_setspecific(runtime_keys[i],NULL),"fixture TLS clear");need(!pthread_key_delete(runtime_keys[i]),"fixture TLS release");}
    need(!pthread_setspecific(host_key,NULL)&&!pthread_key_delete(host_key),"fixture host stack release");
    free(stack);free(module->hash);
#if TARGET_OS_IPHONE
    need(mach_vm_deallocate(mach_task_self(),(uintptr_t)module->base,module->size)==KERN_SUCCESS,"fixture mapping release");
#else
    need(!munmap(module->base,module->size),"fixture mapping release");
#endif
    module->base=NULL;module->hash=NULL;return observed;
}
