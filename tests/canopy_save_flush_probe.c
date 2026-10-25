/* Original private-file caller of the actual guarded host FS implementation.
 * Linux uses a deterministic F_FULLFSYNC adapter backed by real fsync; this
 * checks lifetime/error semantics, not Apple device flush durability. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifndef F_FULLFSYNC
#define F_FULLFSYNC 0x7f55
#endif
static int probe_fcntl(int,int,...);
#define fcntl probe_fcntl
#include "FS_HOST_SOURCE"
#undef fcntl
static int fail_flush,sync_count,barrier,entered,released,observed_fd;
static struct stat observed_before,observed_after;
static pthread_mutex_t test_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t test_condition=PTHREAD_COND_INITIALIZER;
static int probe_fcntl(int fd,int command,...) {
    if(command!=F_FULLFSYNC) {va_list args;va_start(args,command);int n=va_arg(args,int);va_end(args);return fcntl(fd,command,n);}
    sync_count++;
    if(barrier) {
        pthread_mutex_lock(&test_lock);
        if(!entered) {
            observed_fd=fd;if(fstat(fd,&observed_before))abort();entered=1;
            pthread_cond_broadcast(&test_condition);
            while(!released)pthread_cond_wait(&test_condition,&test_lock);
            if(fstat(fd,&observed_after))abort();
        }
        pthread_mutex_unlock(&test_lock);
    }
    if(fail_flush){errno=EIO;return -1;}
    return fsync(fd);
}
_Noreturn void runtime_fail(const char *message){fprintf(stderr,"unexpected runtime failure: %s\n",message);exit(3);}
void runtime_account_uid(uint64_t out[2]){out[0]=1;out[1]=2;}
uint64_t runtime_now_ns(void){return UINT64_C(10000000000);}
void dm_guest_write_prepare(void *p,size_t n){(void)p;(void)n;}
void runtime_autoload_save_file_opened(const char *p){(void)p;}
void runtime_fs_log(const char *what,const char *p){(void)what;(void)p;}
int runtime_romfs_owns(const char *p){(void)p;return 0;}
int runtime_romfs_handle(uint64_t h){(void)h;return 0;}
unsigned runtime_romfs_open(uint64_t *o,const char *p,int m){(void)o;(void)p;(void)m;return 1;}
unsigned runtime_romfs_read(uint64_t *o,uint64_t h,int64_t f,void *b,uint64_t n){(void)o;(void)h;(void)f;(void)b;(void)n;return 1;}
unsigned runtime_romfs_size(int64_t *o,uint64_t h){(void)o;(void)h;return 1;}
void runtime_romfs_close(uint64_t h){(void)h;}
unsigned runtime_romfs_entry_type(int *o,const char *p){(void)o;(void)p;return 1;}
static void check(int yes,const char *message){if(!yes){fprintf(stderr,"FAIL:%s\n",message);exit(4);}}
#if defined(CANOPY_HOST_RUNTIME)
static uint64_t handle;
static unsigned committed,written_result;
static _Atomic int attempted,finished;
static void *commit_thread(void *unused){(void)unused;committed=commit("save");return NULL;}
static void *close_thread(void *unused){(void)unused;atomic_store(&attempted,1);close_file(handle);atomic_store(&finished,1);return NULL;}
static void *write_thread(void *unused){(void)unused;atomic_store(&attempted,1);written_result=write_file(handle,0,"new!",4,NULL);atomic_store(&finished,1);return NULL;}
static void namespace_moves(const char *root) {
    char temporary[2048],other_save[2048],path[2048];
    snprintf(temporary,sizeof(temporary),"%s/temp",root);snprintf(other_save,sizeof(other_save),"%s/other",root);
    check(!mkdir(temporary,0700)&&!mkdir(other_save,0700),"private sibling directories");
    check(!mount_add("temp",M_TEMP,temporary)&&!mount_add("other",M_SAVE,other_save),"sibling mounts");
    uint64_t h;check(!open_file(&h,"save:/save.bin",OPEN_WRITE),"open current save");
    check(!write_file(h,0,"keep",4,NULL),"seed save bytes");close_file(h);check(!commit("save"),"seed save commit");
    check(!create_file("temp:/payload",4)&&!open_file(&h,"temp:/payload",OPEN_WRITE),"create temp payload");
    check(!write_file(h,0,"move",4,NULL),"write temp payload");close_file(h);sync_count=0;
    check(!atomic_load(&save_dirty),"temp mutation dirtied save");
    check(rename_file("temp:/payload","save:/save.bin")==R_INVALID_PATH,"cross-kind rename accepted");
    check(rename_file("temp:/payload","save:/moved.bin")==R_INVALID_PATH,"temp entered save ownership");
    check(rename_file("save:/save.bin","other:/moved.bin")==R_INVALID_PATH,"different save-root rename accepted");
    check(!atomic_load(&save_dirty)&&!commit("save")&&!sync_count,"refused move changed dirty/flush state");
    int fd;char bytes[4];snprintf(path,sizeof(path),"%s/save.bin",root);fd=open(path,O_RDONLY);
    check(fd>=0&&pread(fd,bytes,4,0)==4&&!memcmp(bytes,"keep",4),"current save bytes changed");close(fd);
    snprintf(path,sizeof(path),"%s/temp/payload",root);fd=open(path,O_RDONLY);
    check(fd>=0&&pread(fd,bytes,4,0)==4&&!memcmp(bytes,"move",4),"refused source bytes changed");close(fd);
    check(!create_file("save:/pending.bin",4)&&!open_file(&h,"save:/pending.bin",OPEN_WRITE),"same-save staging");
    check(!write_file(h,0,"data",4,NULL),"same-save payload");close_file(h);
    check(!rename_file("save:/pending.bin","save:/moved.bin")&&atomic_load(&save_dirty),"same-save rename refused");
    check(!commit("save")&&sync_count>0&&!atomic_load(&save_dirty),"renamed owned payload not flushed");
    snprintf(path,sizeof(path),"%s/moved.bin",root);fd=open(path,O_RDONLY);
    check(fd>=0&&pread(fd,bytes,4,0)==4&&!memcmp(bytes,"data",4),"same-save payload changed");close(fd);
}
static void concurrent(int writing,const char *root) {
    check(!open_file(&handle,"save:/save.bin",OPEN_READ|OPEN_WRITE),"open concurrent");
    check(!write_file(handle,0,"old!",4,NULL),"write old");
    pthread_t a,b;barrier=1;
    check(!pthread_create(&a,NULL,commit_thread,NULL),"spawn commit");
    pthread_mutex_lock(&test_lock);while(!entered)pthread_cond_wait(&test_condition,&test_lock);pthread_mutex_unlock(&test_lock);
    check(pthread_mutex_trylock(&canopy_io_lock)==EBUSY,"commit does not own IO lifetime");
    check(!pthread_create(&b,NULL,writing ? write_thread:close_thread,NULL),"spawn concurrent operation");
    while(!atomic_load(&attempted))sched_yield();
    check(!atomic_load(&finished),"concurrent mutation escaped commit lock");
    char path[2048];snprintf(path,sizeof(path),"%s/unrelated",root);
    int unrelated=open(path,O_CREAT|O_EXCL|O_RDWR,0600);check(unrelated>=0 && unrelated!=observed_fd,"flush descriptor was reused");
    pthread_mutex_lock(&test_lock);released=1;pthread_cond_broadcast(&test_condition);pthread_mutex_unlock(&test_lock);
    check(!pthread_join(a,NULL)&&!pthread_join(b,NULL),"join");
    check(!committed && observed_before.st_dev==observed_after.st_dev && observed_before.st_ino==observed_after.st_ino,"flushed wrong inode");
    check(atomic_load(&save_dirty)==1,"concurrent change was cleared");
    if(writing) {
        check(!written_result,"concurrent write failed");char bytes[4];int fd;
        check(file_of(handle,&fd,NULL)&&pread(fd,bytes,4,0)==4&&!memcmp(bytes,"new!",4),"concurrent write lost");close_file(handle);
    } else {
        check(flush_file(handle)==R_INVALID_ARGUMENT,"guest closed handle remained valid");
        uint64_t next;check(!open_file(&next,"save:/save.bin",OPEN_READ)&&next!=handle,"pending slot was reused");close_file(next);
    }
    close(unrelated);barrier=0;check(!commit("save")&&!atomic_load(&save_dirty),"commit pending retry");
}
#endif
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    check(!mount_add("save",M_SAVE,argv[2]),"mount");
    check(!create_file("save:/save.bin",4),"create");
    check(!commit("save"),"initial commit");sync_count=0;
#if defined(CANOPY_HOST_RUNTIME)
    if(!strcmp(argv[1],"namespace"))namespace_moves(argv[2]);
    else if(!strcmp(argv[1],"close-race"))concurrent(0,argv[2]);
    else if(!strcmp(argv[1],"write-race"))concurrent(1,argv[2]);
    else if(!strcmp(argv[1],"bound")) {
        for(unsigned i=0;i<NFILES;i++){uint64_t h;check(!open_file(&h,"save:/save.bin",OPEN_WRITE),"bounded open");close_file(h);}
        uint64_t h;check(open_file(&h,"save:/save.bin",OPEN_WRITE)==R_INVALID_ARGUMENT,"pending FD bound missing");
        check(!atomic_load(&save_writers)&&atomic_load(&save_dirty),"pending writer count/dirty");
    } else {
        uint64_t h;check(!open_file(&h,"save:/save.bin",OPEN_WRITE),"open");
        check(!write_file(h,0,"data",4,NULL),"write");
        int fd;check(file_of(h,&fd,NULL)!=NULL,"lookup");
        if(!strcmp(argv[1],"closed-error")) {
            close_file(h);check(!atomic_load(&save_writers),"closed writer still guest-open");
            check(flush_file(h)==R_INVALID_ARGUMENT,"closed flush accepted");
            check(write_file(h,0,"oops",4,NULL)==R_INVALID_ARGUMENT,"closed write accepted");
            fail_flush=1;check(commit("save")==R_INVALID_ARGUMENT && sync_count==1,"commit swallowed fullsync error");
            check(atomic_load(&save_dirty)&&fcntl(fd,F_GETFD)>=0,"failure dropped pending ownership/dirty");
            atomic_store(&save_changed_ns,0);check(runtime_fs_save_busy(),"failed dirty save aged into clean");
            fail_flush=0;check(!commit("save")&&!atomic_load(&save_dirty),"pending retry failed");
            check(fcntl(fd,F_GETFD)<0&&errno==EBADF,"successful commit leaked pending FD");
        } else if(!strcmp(argv[1],"flush-error")) {
            fail_flush=1;check(flush_file(h)==R_INVALID_ARGUMENT && atomic_load(&save_dirty),"flush swallowed error");
            int32_t option=1;check(write_file(h,0,"new!",4,&option)==R_INVALID_ARGUMENT&&atomic_load(&save_dirty),"write-with-flush swallowed error");
            fail_flush=0;check(!flush_file(h),"flush retry");close_file(h);check(!commit("save"),"commit after flush");
        } else if(!strcmp(argv[1],"resize")) {
            check(!set_file_size(h,8)&&atomic_load(&save_dirty),"resize dirty");close_file(h);
            check(!commit("save")&&!atomic_load(&save_dirty),"resize flush");
        } else if(!strcmp(argv[1],"unknown")) {
            check(commit("missing")==R_PATH_NOT_FOUND&&atomic_load(&save_dirty)&&!sync_count,"unknown commit cleared dirty");
            close_file(h);check(!commit("save"),"cleanup");
        } else return 2;
    }
#else
    if(strcmp(argv[1],"legacy"))return 2;
    uint64_t h;check(!open_file(&h,"save:/save.bin",OPEN_WRITE),"legacy open");fail_flush=1;
    check(commit("save")==0&&!atomic_load(&save_dirty),"standalone behavior changed");
    close_file(h);atomic_store(&save_changed_ns,0);
    check(!runtime_fs_save_busy(),"standalone age heuristic changed");
#endif
    puts("{\"status\":\"pass\",\"scope\":\"actual source, private synthetic files; no teardown/durability ACK\"}");return 0;
}
