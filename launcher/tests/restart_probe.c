/* Entirely original native engine fixture. It proves controller behavior, never
 * a Nintendo request, game thread context or commercial restart mechanism. */
#include "mng_restart.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void check(int value,const char *message) {if(!value){fprintf(stderr,"FAIL: %s\n",message);exit(2);}}
struct engine {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    struct mng_restart *controller;
    pthread_t thread;
    uint64_t pending;
    int quit,allowed,phase,progress,requests,transitions;
    unsigned char identity[16],backup[16],input[16];
};
static void *guest_thread(void *opaque) {
    struct engine *engine=opaque;pthread_mutex_lock(&engine->lock);
    for(;;) {
        while(!engine->quit && (!engine->pending || !engine->allowed))pthread_cond_wait(&engine->changed,&engine->lock);
        if(engine->quit)break;
        check(pthread_equal(pthread_self(),engine->thread),"fixture transition runs on its actual owner thread");
        uint64_t ticket=engine->pending;engine->pending=0;
        /* This source owns its Title transition. No guessed game API exists. */
        engine->phase=1;engine->progress=0;engine->transitions++;
        pthread_mutex_unlock(&engine->lock);
        check(mng_restart_finish(engine->controller,ticket,MNG_RESTART_TITLE_REACHED)==MNG_RESTART_OK,"ack follows actual fixture transition");
        pthread_mutex_lock(&engine->lock);pthread_cond_broadcast(&engine->changed);
    }
    pthread_mutex_unlock(&engine->lock);return NULL;
}
static int submit(void *opaque,struct mng_restart *controller,uint64_t ticket) {
    struct engine *engine=opaque;pthread_mutex_lock(&engine->lock);
    check(!engine->pending,"only one fixture engine request");engine->controller=controller;engine->pending=ticket;engine->requests++;
    pthread_cond_broadcast(&engine->changed);pthread_mutex_unlock(&engine->lock);return 0;
}
static int refused(void *opaque,struct mng_restart *controller,uint64_t ticket) {(void)opaque;(void)controller;(void)ticket;return -1;}
static int no_operation(void *opaque,struct mng_restart *controller,uint64_t ticket) {(void)opaque;(void)controller;(void)ticket;return 0;}
static int synchronous(void *opaque,struct mng_restart *controller,uint64_t ticket) {
    int *calls=opaque;(*calls)++;
    check(mng_restart_finish(controller,ticket,MNG_RESTART_GAME_RELOADED)==MNG_RESTART_OK,"synchronous completion has no lock deadlock");
    uint64_t other=0;check(mng_restart_begin(controller,&other)==MNG_RESTART_BUSY,"completed callback still on stack cannot overlap");
    check(mng_restart_destroy(controller)==MNG_RESTART_BUSY,"callback stack retains controller");return 0;
}
static struct mng_restart_snapshot snapshot(struct mng_restart *controller) {
    struct mng_restart_snapshot state={0};state.abi=MNG_RESTART_ABI;state.size=sizeof(state);
    check(mng_restart_snapshot(controller,&state)==MNG_RESTART_OK,"actual controller snapshot");return state;
}
static void confirmations(struct mng_restart *controller,uint64_t *ticket) {
    check(mng_restart_begin(controller,ticket)==MNG_RESTART_OK,"first confirmation");
    struct mng_restart_prompt prompt={0};prompt.abi=MNG_RESTART_ABI;prompt.size=sizeof(prompt);
    check(mng_restart_prompt(controller,&prompt)==MNG_RESTART_OK && !strcmp(prompt.cancel_label,"Cancel") &&
        !strcmp(prompt.affirmative_label,"Continue") && prompt.affirmative_destructive && strstr(prompt.message,"Unsaved progress"),"first destructive confirmation policy");
    check(mng_restart_confirm(controller,*ticket)==MNG_RESTART_BAD_STATE,"cannot bypass first confirmation");
    check(mng_restart_continue(controller,*ticket)==MNG_RESTART_OK,"first Continue");
    check(mng_restart_prompt(controller,&prompt)==MNG_RESTART_OK && !strcmp(prompt.cancel_label,"Cancel") &&
        !strcmp(prompt.affirmative_label,"Restart game") && prompt.affirmative_destructive,"second destructive confirmation policy");
}
int main(int argc,char **argv) {
    check(argc==2,"scenario");struct engine engine={0};engine.phase=2;engine.progress=91;
    memset(engine.identity,0x11,16);memset(engine.backup,0x22,16);memset(engine.input,0x33,16);
    unsigned char before[48];memcpy(before,engine.identity,16);memcpy(before+16,engine.backup,16);memcpy(before+32,engine.input,16);
    check(!pthread_mutex_init(&engine.lock,NULL) && !pthread_cond_init(&engine.changed,NULL),"fixture synchronization");
    struct mng_restart_provider provider={MNG_RESTART_ABI,sizeof(provider),&engine,submit};struct mng_restart *controller=NULL;
    check(mng_restart_create(NULL,&controller)==MNG_RESTART_INVALID && !controller,"no absent provider creates a mechanism");
    check(mng_restart_create(&provider,&controller)==MNG_RESTART_OK,"real fixture dispatcher binding");uint64_t ticket=0;
    if(!strcmp(argv[1],"cancel-first")) {
        check(mng_restart_begin(controller,&ticket)==MNG_RESTART_OK && mng_restart_cancel(controller,ticket)==MNG_RESTART_OK,"cancel first");
        check(!engine.requests && engine.phase==2 && engine.progress==91 && !snapshot(controller).submissions,"first cancel untouched");
    } else if(!strcmp(argv[1],"cancel-second")) {
        confirmations(controller,&ticket);check(mng_restart_cancel(controller,ticket)==MNG_RESTART_OK,"cancel second");
        check(!engine.requests && engine.phase==2 && engine.progress==91 && !snapshot(controller).submissions,"second cancel untouched");
    } else if(!strcmp(argv[1],"transition")) {
        check(!pthread_create(&engine.thread,NULL,guest_thread,&engine),"original engine thread");
        confirmations(controller,&ticket);check(mng_restart_confirm(controller,ticket)==MNG_RESTART_OK,"final confirmation");
        check(snapshot(controller).phase==MNG_RESTART_SUBMITTED && snapshot(controller).outcome==MNG_RESTART_NO_OUTCOME,"queueing is not completion");
        uint64_t other=777;check(mng_restart_begin(controller,&other)==MNG_RESTART_BUSY && other==777,"single flight preserves refused output");
        check(mng_restart_confirm(controller,ticket)==MNG_RESTART_BAD_STATE && engine.requests==1,"duplicate confirm cannot dispatch");
        check(mng_restart_cancel(controller,ticket)==MNG_RESTART_BAD_STATE,"confirmation cancellation cannot retract dispatched operation");
        check(mng_restart_destroy(controller)==MNG_RESTART_BUSY,"inflight controller retained");
        pthread_mutex_lock(&engine.lock);engine.allowed=1;pthread_cond_broadcast(&engine.changed);
        while(engine.transitions!=1 || snapshot(controller).phase!=MNG_RESTART_FINISHED)pthread_cond_wait(&engine.changed,&engine.lock);
        engine.quit=1;pthread_cond_broadcast(&engine.changed);pthread_mutex_unlock(&engine.lock);check(!pthread_join(engine.thread,NULL),"actual fixture engine join");
        check(snapshot(controller).outcome==MNG_RESTART_TITLE_REACHED && snapshot(controller).submissions==1 && engine.phase==1 && engine.progress==0,"actual fixture title transition acknowledged");
        check(mng_restart_finish(controller,ticket,MNG_RESTART_TITLE_REACHED)==MNG_RESTART_BAD_STATE,"duplicate completion refused");
        check(mng_restart_begin(controller,&other)==MNG_RESTART_OK && other!=ticket,"later independent request");
        check(mng_restart_continue(controller,ticket)==MNG_RESTART_STALE && mng_restart_finish(controller,ticket,MNG_RESTART_FAILED)==MNG_RESTART_STALE,"stale events cannot affect new prompt");
        check(mng_restart_cancel(controller,other)==MNG_RESTART_OK,"cancel later request");
    } else {
        check(mng_restart_destroy(controller)==MNG_RESTART_OK,"replace fixture provider");controller=NULL;
        int calls=0;provider.context=&calls;
        if(!strcmp(argv[1],"refused"))provider.submit=refused;
        else if(!strcmp(argv[1],"noop"))provider.submit=no_operation;
        else {check(!strcmp(argv[1],"synchronous"),"known scenario");provider.submit=synchronous;}
        check(mng_restart_create(&provider,&controller)==MNG_RESTART_OK,"provider variant");confirmations(controller,&ticket);
        check(mng_restart_confirm(controller,ticket)==MNG_RESTART_OK,"submission attempted");
        if(!strcmp(argv[1],"refused"))check(snapshot(controller).phase==MNG_RESTART_FINISHED && snapshot(controller).outcome==MNG_RESTART_FAILED,"dispatcher refusal is not restart");
        if(!strcmp(argv[1],"noop")) {
            check(snapshot(controller).phase==MNG_RESTART_SUBMITTED && snapshot(controller).outcome==MNG_RESTART_NO_OUTCOME,"a no-op cannot report restart");
            check(mng_restart_finish(controller,ticket,MNG_RESTART_FAILED)==MNG_RESTART_OK,"fixture observer reports no transition");
        }
        if(!strcmp(argv[1],"synchronous"))check(calls==1 && snapshot(controller).outcome==MNG_RESTART_GAME_RELOADED,"synchronous observation retained");
    }
    check(!memcmp(before,engine.identity,16) && !memcmp(before+16,engine.backup,16) && !memcmp(before+32,engine.input,16),"identity backups and inputs unchanged");
    check(mng_restart_destroy(controller)==MNG_RESTART_OK,"controller only destruction");
    check(!pthread_cond_destroy(&engine.changed) && !pthread_mutex_destroy(&engine.lock),"fixture only cleanup");
    puts("{\"status\":\"pass\",\"scope\":\"restart control plane with original fixture; not a TOTK restart\"}");return 0;
}
