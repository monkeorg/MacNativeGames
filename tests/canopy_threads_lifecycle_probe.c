/* Original synthetic guest entries through production SVC + ARM64 stack switch.
 * This proves child ownership only, never title exit or whole-runtime teardown. */
#include "thread_compat.h"
#include <stdatomic.h>
#include <time.h>
#include <sys/mman.h>
#include <unistd.h>
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed=PTHREAD_COND_INITIALIZER;
static pthread_key_t destructor_key;
static int release_guest,release_destructor,destructor_entered,delay_destructor;
static unsigned entered,destructed,created_count;
static void *stacks[64];
static atomic_int attempted_guest_drain;
_Noreturn void runtime_fail(const char *message) { fprintf(stderr,"FAIL: %s\n",message);exit(1); }
void *runtime_symbol(const char *name) { (void)name;runtime_fail("unexpected symbol"); }
void runtime_thread_init(void) {}
uint64_t runtime_now_ns(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000+(uint64_t)t.tv_nsec; }
static void need(int yes,const char *message) { if(!yes)runtime_fail(message); }
static void svc(unsigned num,uint64_t *r) { need(svc_thread((int)num,r)==1,"SVC dispatch"); }
static void destructor(void *value) {
    (void)value;pthread_mutex_lock(&lock);destructor_entered=1;pthread_cond_broadcast(&changed);
    while(delay_destructor && !release_destructor)pthread_cond_wait(&changed,&lock);
    destructed++;pthread_mutex_unlock(&lock);
}
static void guest(uint64_t argument) {
    need(!pthread_setspecific(destructor_key,(void *)1),"set destructor");
    if(argument) {
        struct canopy_threads_state s={CANOPY_THREADS_ABI,sizeof(s),0,0,0,0,0};
        atomic_store(&attempted_guest_drain,runtime_canopy_threads_drain(0,&s));
    }
    pthread_mutex_lock(&lock);entered++;pthread_cond_broadcast(&changed);
    while(!release_guest)pthread_cond_wait(&changed,&lock);
    pthread_mutex_unlock(&lock);uint64_t r[31]={0};svc(0x0a,r);runtime_fail("ExitThread returned");
}
static uint32_t create(unsigned slot,int start,int check_guest_drain) {
    need(slot<64,"fixture bound");
    stacks[slot]=mmap(NULL,2<<20,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    need(stacks[slot]!=MAP_FAILED,"guest stack");
    uint64_t r[31]={0};r[1]=(uintptr_t)guest;r[2]=(uint64_t)check_guest_drain;
    r[3]=(uintptr_t)stacks[slot]+(2<<20);r[4]=44;r[5]=0;svc(8,r);
    if(r[0]) { need(r[0]==0xfa01,"closed admission status");munmap(stacks[slot],2<<20);stacks[slot]=NULL;return 0; }
    uint32_t h=(uint32_t)r[1];if(start){r[0]=h;svc(9,r);need(!r[0],"start admitted child");}
    return h;
}
static void refuse_creation(void) {
    uint64_t r[31]={0};r[1]=(uintptr_t)guest;r[3]=0x10000;r[4]=44;r[5]=0;svc(8,r);
    need(r[0]==0xfa01,"no creation after admission close");
}
static void close_handle(uint32_t h) { uint64_t r[31]={h};svc(0x16,r);need(!r[0],"close guest handle"); }
struct drain_call {uint64_t timeout;int result;struct canopy_threads_state state;};
static void *drain_worker(void *p) {struct drain_call *d=p;d->result=runtime_canopy_threads_drain(d->timeout,&d->state);return NULL;}
static struct drain_call drain(uint64_t timeout) {
    struct drain_call d={timeout,-99,{CANOPY_THREADS_ABI,sizeof(d.state),0,0,0,0,0}};
    pthread_t worker;need(!pthread_create(&worker,NULL,drain_worker,&d),"drain host worker");
    need(!pthread_join(worker,NULL),"drain worker join");return d;
}
static struct canopy_threads_state snapshot(void) {
    struct canopy_threads_state s={CANOPY_THREADS_ABI,sizeof(s),0,0,0,0,0};
    need(!runtime_canopy_threads_snapshot(&s),"snapshot");return s;
}
static void wait_entered(unsigned count) {
    pthread_mutex_lock(&lock);while(entered<count)pthread_cond_wait(&changed,&lock);pthread_mutex_unlock(&lock);
}
static void release_all(void) {pthread_mutex_lock(&lock);release_guest=1;release_destructor=1;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&lock);}
static void *creator(void *unused) {
    (void)unused;
    for(unsigned i=0;i<64;i++) {
        uint32_t h=create(i,1,0);if(!h)break;close_handle(h);
        pthread_mutex_lock(&lock);created_count++;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&lock);
    }
    return NULL;
}
int main(int argc,char **argv) {
    need(argc==2,"scenario");setenv("TOTK_FREE_CORES","1",1);
    need(!pthread_key_create(&destructor_key,destructor),"destructor key");
    svc_thread_main_init();
    need(snapshot().owned_children==0,"main excluded from owned children");
    need(drain(0).result==-1,"drain requires closed admission");
    struct canopy_threads_state invalid={0};need(runtime_canopy_threads_snapshot(&invalid)==-1,"strict state ABI");
    if(!strcmp(argv[1],"unstarted")) {
        uint32_t h=create(0,0,0);need(h!=0,"create unstarted");close_handle(h);runtime_canopy_threads_close_admission();
        struct drain_call d=drain(1000000);need(d.result==0 && d.state.owned_children==1 && !d.state.joining_children,"unstarted remains pending");
        need(!entered,"no arbitrary guest admission/exit");
    } else if(!strcmp(argv[1],"race")) {
        pthread_t c;need(!pthread_create(&c,NULL,creator,NULL),"creator");
        pthread_mutex_lock(&lock);while(!created_count)pthread_cond_wait(&changed,&lock);pthread_mutex_unlock(&lock);
        runtime_canopy_threads_close_admission();need(!pthread_join(c,NULL),"creator joined");
        need(created_count>0 && created_count<=64,"bounded successful admissions");
        refuse_creation();
        release_all();struct drain_call d=drain(1000000000);
        need(d.result==1 && !d.state.owned_children && d.state.joined_children==created_count,"all raced admissions owned through join");
        need(destructed==created_count,"destructors complete before drained");
    } else {
        need(!strcmp(argv[1],"lifetime"),"known scenario");delay_destructor=1;
        uint32_t h=create(0,1,1);need(h!=0,"create child");wait_entered(1);close_handle(h);
        need(snapshot().owned_children==1,"close handle retains native ownership");
        need(atomic_load(&attempted_guest_drain)==-1,"guest cannot drain itself");
        runtime_canopy_threads_close_admission();need(drain(1000001).result==0,"running guest pending");
        pthread_mutex_lock(&lock);release_guest=1;pthread_cond_broadcast(&changed);
        while(!destructor_entered)pthread_cond_wait(&changed,&lock);pthread_mutex_unlock(&lock);
        struct drain_call d=drain(1000000);need(d.result==0 && d.state.owned_children==1,"guest exit alone is not host completion");
        need(!destructed,"delayed TLS destructor still owned");
        release_all();d=drain(1000000000);need(d.result==1 && d.state.joined_children==1 && !d.state.join_failures,"join proves destructor completion");
        need(destructed==1,"actual destructor finished");refuse_creation();
        need(drain(1000000001).result==-1,"bounded drain timeout contract");
    }
    /* Only joined children permit stack reclamation. Unstarted fixture exits
     * its process retaining that stack; it never represents a completed drain. */
    if(strcmp(argv[1],"unstarted"))for(unsigned i=0;i<64;i++)if(stacks[i])need(!munmap(stacks[i],2<<20),"joined guest stack reclaim");
    puts("{\"scope\":\"owned guest children only\",\"passed\":true}");return 0;
}
