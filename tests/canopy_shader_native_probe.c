/* Original caller for an ACTUALLY linked static NativeAOT archive. No mocks. */
#include "inprocess_cross.h"
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <string.h>
static unsigned char *load(const char *path,size_t *length) {
    FILE *f=fopen(path,"rb");if(!f)return NULL;
    if(fseek(f,0,SEEK_END)){fclose(f);return NULL;}long n=ftell(f);
    if(n<0 || n>65536 || fseek(f,0,SEEK_SET)){fclose(f);return NULL;}
    unsigned char *p=malloc((size_t)n+1);if(!p){fclose(f);return NULL;}
    if(fread(p,1,(size_t)n,f)!=(size_t)n){free(p);fclose(f);return NULL;}
    fclose(f);*length=(size_t)n;return p;
}
struct task {const unsigned char *code,*request;size_t cn,rn;int status;};
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition=PTHREAD_COND_INITIALIZER;
static int ready,go;
static int cancel_now(void *context) { unsigned *calls=context;(*calls)++;return 1; }
struct delayed_cancel {unsigned calls,limit;};
static int cancel_later(void *context) {
    struct delayed_cancel *state=context;return ++state->calls>=state->limit;
}
static int first_cancel(unsigned char *code,size_t cn,unsigned char *request,size_t rn,unsigned limit) {
    unsigned char *output=malloc(16u<<20);if(!output)return 30;
    memset(output,0x5a,16u<<20);size_t length=99;
    struct delayed_cancel cancel={0,limit};
    struct canopy_shader_control control={0};control.version=1;control.size=sizeof(control);control.cancel=cancel_later;control.context=&cancel;
    int status=canopy_shader_translate_controlled(code,cn,request,rn,output,16u<<20,&length,&control);
    if(status!=6 || length || cancel.calls!=limit || output[0]!=0x5a){free(output);return 31;}
    // A canceled first use must not poison managed static tables or retain a
    // broken compiler pool. This is an actual full-translator call, not a mock.
    status=canopy_shader_translate(code,cn,request,rn,output,16u<<20,&length);
    free(output);if(status || !length)return 32;puts("{\"status\":0}");return 0;
}
static void *thread_call(void *context) {
    struct task *task=context;unsigned char *output=malloc(16u<<20);size_t n=0;
    pthread_mutex_lock(&mutex);ready++;pthread_cond_broadcast(&condition);
    while(!go){pthread_cond_wait(&condition,&mutex);}
    pthread_mutex_unlock(&mutex);
    task->status=output ? canopy_shader_translate(task->code,task->cn,task->request,task->rn,output,16u<<20,&n):6;
    free(output);return NULL;
}
static int self_test(unsigned char *code,size_t cn,unsigned char *request,size_t rn) {
    size_t n=99;unsigned char sentinel=0x5a;
    if(canopy_shader_translate(NULL,cn,request,rn,&sentinel,1,&n)!=1 || n || sentinel!=0x5a)return 10;
    if(canopy_shader_translate(code,cn,request,rn,&sentinel,1,&n)!=2 || n<=1 || sentinel!=0x5a)return 11;
    const unsigned char malformed[]="{";
    if(canopy_shader_translate(code,cn,malformed,1,&sentinel,1,&n)!=1 || n || sentinel!=0x5a)return 12;
    struct canopy_shader_control control={0};control.version=1;control.size=sizeof(control);
    unsigned calls=0;control.cancel=cancel_now;control.context=&calls;
    if(canopy_shader_translate_controlled(code,cn,request,rn,&sentinel,1,&n,&control)!=6 || n || sentinel!=0x5a || !calls)return 15;
    control.cancel=NULL;control.context=NULL;control.max_work=1;
    if(canopy_shader_translate_controlled(code,cn,request,rn,&sentinel,1,&n,&control)!=5 || n || sentinel!=0x5a)return 16;
    control.max_work=0;control.reserved=1;
    if(canopy_shader_translate_controlled(code,cn,request,rn,&sentinel,1,&n,&control)!=1 || n || sentinel!=0x5a)return 17;
    control.reserved=0;control.version=2;
    if(canopy_shader_translate_controlled(code,cn,request,rn,&sentinel,1,&n,&control)!=1)return 18;
    control.version=1;control.size--;
    if(canopy_shader_translate_controlled(code,cn,request,rn,&sentinel,1,&n,&control)!=1)return 19;
    control.size=sizeof(control);control.max_nodes=262145;
    if(canopy_shader_translate_controlled(code,cn,request,rn,&sentinel,1,&n,&control)!=1)return 20;
    const unsigned char graphics_request[]="{\"variant\":\"0000000000000000000000000000000000000000000000000000000000000000-000000000000\",\"stage\":\"vs\",\"chain\":\"original\"}";
    unsigned char graphics[0x60]={0};graphics[1]=20; /* SPH Fragment5, rq Vertex1 */
    if(canopy_shader_translate(graphics,sizeof(graphics),graphics_request,sizeof(graphics_request)-1,&sentinel,1,&n)!=1 || n || sentinel!=0x5a)return 21;
    struct task tasks[2]={{code,request,cn,rn,0},{code,request,cn,rn,0}};pthread_t threads[2];
    if(pthread_create(&threads[0],NULL,thread_call,&tasks[0]))return 13;
    if(pthread_create(&threads[1],NULL,thread_call,&tasks[1])){
        pthread_mutex_lock(&mutex);go=1;pthread_cond_broadcast(&condition);pthread_mutex_unlock(&mutex);
        pthread_join(threads[0],NULL);return 13;
    }
    pthread_mutex_lock(&mutex);
    while(ready!=2){pthread_cond_wait(&condition,&mutex);}
    go=1;pthread_cond_broadcast(&condition);pthread_mutex_unlock(&mutex);
    pthread_join(threads[0],NULL);pthread_join(threads[1],NULL);
    // A scheduler may serialize both successful calls. Any overlap must return
    // BUSY, with no corrupt output/crash; measured busy count is reported.
    for(unsigned i=0;i<2;i++)if(tasks[i].status!=0 && tasks[i].status!=4)return 14;
    printf("{\"status\":0,\"busyCount\":%u}\n",(unsigned)(tasks[0].status==4)+(unsigned)(tasks[1].status==4));return 0;
}
int main(int argc,char **argv) {
    if(argc!=4 || canopy_shader_abi_version()!=1)return 2;
    int self=!strcmp(argv[1],"--self-test"),first=!strncmp(argv[1],"--first-cancel=",15),mode=self||first;
    size_t cn=0,rn=0,n=0;unsigned char *code=load(argv[mode?2:1],&cn),*request=load(argv[mode?3:2],&rn);
    if(first){int status=code && request ? first_cancel(code,cn,request,rn,(unsigned)strtoul(argv[1]+15,NULL,10)):2;free(code);free(request);return status;}
    if(self){int status=code && request ? self_test(code,cn,request,rn):2;free(code);free(request);return status;}
    unsigned char *output=malloc(16u<<20);int status=1;
    if(code && request && output)status=canopy_shader_translate(code,cn,request,rn,output,16u<<20,&n);
    if(!status){FILE *f=fopen(argv[3],"wb");if(!f)status=6;
        else {if(fwrite(output,1,n,f)!=n)status=6;if(fclose(f))status=6;}}
    free(code);free(request);free(output);printf("{\"status\":%d,\"bytes\":%zu}\n",status,n);return status;
}
