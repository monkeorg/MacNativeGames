/* Actual shared Canopy main-worker component, pthreads, production SVC thread
 * registry and ARM64 stack switch. No original game/graphics payload needed. */
#define CANOPY_HOST_RUNTIME 1
#define CANOPY_WORKER_NATIVE_PROBE 1
#import "../games/totk/runtime/canopy_host.m"
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
static pthread_mutex_t probe_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t probe_changed=PTHREAD_COND_INITIALIZER;
static pthread_key_t probe_tls;
static int probe_entered,probe_release,probe_destructor_entered,probe_destructor_release;
static int probe_exit_svc,probe_has_child,probe_child_release,probe_child_entered;
static void *probe_child_stack;
_Noreturn void runtime_fail(const char *message) {fprintf(stderr,"FAIL %s\n",message);exit(1);}
static void need(int yes,const char *message) {if(!yes)runtime_fail(message);}
void *runtime_symbol(const char *name) {(void)name;runtime_fail("unexpected symbol");}
void runtime_thread_init(void) {}
uint64_t runtime_now_ns(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000+(uint64_t)t.tv_nsec;}
static void kernel(unsigned num,uint64_t *r) {need(svc_thread((int)num,r)==1,"actual SVC dispatch");}
static void probe_destructor(void *value) {
    (void)value;pthread_mutex_lock(&probe_lock);probe_destructor_entered=1;pthread_cond_broadcast(&probe_changed);
    while(!probe_destructor_release)pthread_cond_wait(&probe_changed,&probe_lock);
    pthread_mutex_unlock(&probe_lock);
}
static void probe_guest(uint64_t argument) {
    (void)argument;pthread_mutex_lock(&probe_lock);probe_child_entered=1;pthread_cond_broadcast(&probe_changed);
    while(!probe_child_release)pthread_cond_wait(&probe_changed,&probe_lock);pthread_mutex_unlock(&probe_lock);
    uint64_t r[31]={0};kernel(0x0a,r);runtime_fail("guest exit returned");
}
static int probe_main(void *context) {
    (void)context;svc_thread_main_init();need(!pthread_setspecific(probe_tls,(void *)1),"actual main TLS setup");
    if(probe_has_child) {
        probe_child_stack=mmap(NULL,2<<20,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
        need(probe_child_stack!=MAP_FAILED,"guest stack");uint64_t r[31]={0};
        r[1]=(uintptr_t)probe_guest;r[3]=(uintptr_t)probe_child_stack+(2<<20);r[4]=44;kernel(8,r);need(!r[0],"actual child creation");
        uint32_t h=(uint32_t)r[1];r[0]=h;kernel(9,r);need(!r[0],"actual child start");r[0]=h;kernel(0x16,r);need(!r[0],"guest handle close retains child");
    }
    pthread_mutex_lock(&probe_lock);probe_entered=1;pthread_cond_broadcast(&probe_changed);
    while(!probe_release)pthread_cond_wait(&probe_changed,&probe_lock);pthread_mutex_unlock(&probe_lock);
    if(probe_exit_svc) {uint64_t r[31]={0};kernel(0x0a,r);runtime_fail("main ExitThread returned");}
    return 37;
}
static struct canopy_totk_lifecycle_state read_state(void) {
    struct canopy_totk_lifecycle_state s={0};s.abi=CANOPY_TOTK_LIFECYCLE_ABI;s.size=sizeof(s);
    need(!canopy_host_read_lifecycle_state(&s),"actual lifecycle query");return s;
}
static struct canopy_totk_lifecycle_state wait_for_join(void) {
    uint64_t deadline=runtime_now_ns()+UINT64_C(5000000000);struct canopy_totk_lifecycle_state s;
    do {s=read_state();if(s.phase==CANOPY_TOTK_MAIN_JOINED)return s;usleep(1000);}while(runtime_now_ns()<deadline);
    runtime_fail("main observer join timeout");
}
int main(int argc,char **argv) {@autoreleasepool {
    need(argc==2,"scenario");probe_exit_svc=!strcmp(argv[1],"svc-exit");probe_has_child=!strcmp(argv[1],"child-pending");
    need(probe_exit_svc || probe_has_child || !strcmp(argv[1],"return"),"known scenario");setenv("TOTK_FREE_CORES","1",1);
    need(!pthread_key_create(&probe_tls,probe_destructor),"main destructor key");
    struct canopy_totk_lifecycle_state s=read_state();need(s.phase==CANOPY_TOTK_MAIN_NOT_STARTED && !s.main_returned && !s.main_joined,"initial state truthful");
    struct canopy_totk_lifecycle_state bad=s;bad.abi=99;
    struct canopy_totk_lifecycle_state saved=bad;need(canopy_host_read_lifecycle_state(&bad)==-1 && !memcmp(&bad,&saved,sizeof(bad)),"strict ABI preserves output");
    bad=s;bad.size--;saved=bad;need(canopy_host_read_lifecycle_state(&bad)==-1 && !memcmp(&bad,&saved,sizeof(bad)),"strict size preserves output");
    need(canopy_host_read_lifecycle_state(NULL)==-1,"null query");
    need(!launch_main_worker(probe_main,NULL,64u<<20),"actual shared worker launch");
    pthread_mutex_lock(&probe_lock);while(!probe_entered || (probe_has_child && !probe_child_entered))pthread_cond_wait(&probe_changed,&probe_lock);pthread_mutex_unlock(&probe_lock);
    s=read_state();need(s.phase==CANOPY_TOTK_MAIN_RUNNING && !s.main_returned && !s.main_joined && !s.guest_admission_closed,"live main state");
    need(s.owned_guest_children==(unsigned)probe_has_child,"main and watcher excluded from child count");
    pthread_mutex_lock(&probe_lock);probe_release=1;pthread_cond_broadcast(&probe_changed);
    while(!probe_destructor_entered)pthread_cond_wait(&probe_changed,&probe_lock);pthread_mutex_unlock(&probe_lock);
    s=read_state();need(s.phase==CANOPY_TOTK_MAIN_CLEANUP_OBSERVED && !s.main_joined && s.guest_admission_closed,"cleanup not joined while TLS blocked");
    need(s.main_returned==(unsigned)!probe_exit_svc && s.main_return_code==(probe_exit_svc?0:37),"natural return distinct from actual SVC pthread_exit");
    need(!s.join_error,"no invented join error");
    pthread_mutex_lock(&probe_lock);probe_destructor_release=1;pthread_cond_broadcast(&probe_changed);pthread_mutex_unlock(&probe_lock);
    s=wait_for_join();need(s.main_joined && !s.join_error,"actual join after TLS completion");
    need(launch_main_worker(probe_main,NULL,64u<<20)==-1,"no relaunch after observed join");
    need(s.owned_guest_children==(unsigned)probe_has_child,"joined main does not imply child drain");
    if(probe_has_child) {
        uint64_t r[31]={0};r[1]=(uintptr_t)probe_guest;r[3]=0x10000;r[4]=44;kernel(8,r);need(r[0]==0xfa01,"main cleanup closes real child admission");
        pthread_mutex_lock(&probe_lock);probe_child_release=1;pthread_cond_broadcast(&probe_changed);pthread_mutex_unlock(&probe_lock);
        struct canopy_threads_state child={CANOPY_THREADS_ABI,sizeof(child),0,0,0,0,0};
        need(runtime_canopy_threads_drain(UINT64_C(1000000000),&child)==1,"real guest child joins naturally");
        need(!munmap(probe_child_stack,2<<20),"joined guest stack reclaim");s=read_state();need(!s.owned_guest_children && s.main_joined,"subset join facts only");
    }
    puts("{\"scope\":\"main worker and owned guest child observations only\",\"passed\":true}");return 0;
}}
