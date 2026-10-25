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
    int self=!strcmp(argv[1],"--self-test");
    size_t cn=0,rn=0,n=0;unsigned char *code=load(argv[self?2:1],&cn),*request=load(argv[self?3:2],&rn);
    if(self){int status=code && request ? self_test(code,cn,request,rn):2;free(code);free(request);return status;}
    unsigned char *output=malloc(16u<<20);int status=1;
    if(code && request && output)status=canopy_shader_translate(code,cn,request,rn,output,16u<<20,&n);
    if(!status){FILE *f=fopen(argv[3],"wb");if(!f)status=6;
        else {if(fwrite(output,1,n,f)!=n)status=6;if(fclose(f))status=6;}}
    free(code);free(request);free(output);printf("{\"status\":%d,\"bytes\":%zu}\n",status,n);return status;
}
