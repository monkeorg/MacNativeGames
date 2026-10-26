#import "CanopyShaderTranslator.h"
#if defined(CANOPY_LINKED_SHADER_TRANSLATOR)
#include "../../../games/totk/tools/totk_xlate/inprocess_cross.h"
#include "nvn_refl.h"
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <dirent.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifndef CANOPY_SHADER_PROVIDER_RECIPE_SHA256
#error Linked translator requires an exact captured native product recipe
#endif
static pthread_mutex_t CTLock=PTHREAD_MUTEX_INITIALIZER;
static _Atomic int CTActive, CTTerminal;
/* Low bit marks the atomic index-publication cutoff, higher bits are epoch. */
static _Atomic uint64_t CTState;
static int CTDirectory=-1;
static uint64_t CTBytes;
static unsigned CTFiles;
static NSString *CTChain, *CTPath;
static const uint64_t CTQuota=UINT64_C(1024)*1024*1024;
static int CTCancel(void *context){
    uint64_t state=atomic_load_explicit(&CTState,memory_order_acquire);
    if((state&(UINT64_C(1)<<63))||atomic_load_explicit(&CTTerminal,memory_order_acquire)||!atomic_load_explicit(&CTActive,memory_order_acquire))return 1;
    return context && (state&~UINT64_C(1))!=*(uint64_t *)context;
}
static int CTCurrent(uint64_t epoch){return epoch!=0&&!CTCancel(&epoch);}
/* Fixed metadata only: no eviction can turn draw-frequency failures into new
 * untracked attempts. A fresh focus epoch is an explicit retry boundary. */
#define CT_FAILURE_RECORDS 256u
#define CT_ATTEMPTS_PER_EPOCH 3u
struct ct_admission {
    unsigned char digest[32];
    uint64_t epoch,ticket,next_ns;
    unsigned attempts;
    int used,in_flight;
};
static struct ct_admission CTAdmissions[CT_FAILURE_RECORDS];
static pthread_mutex_t CTAdmissionLock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t CTNextTicket,CTRetrySerial,CTRetryEpoch,CTRetryBucket;
static uint64_t CTNow(void){
    struct timespec t;
    if(clock_gettime(CLOCK_MONOTONIC,&t)||t.tv_sec<0||t.tv_nsec<0||t.tv_nsec>=1000000000||
       (uint64_t)t.tv_sec>(UINT64_MAX-(uint64_t)t.tv_nsec)/UINT64_C(1000000000))return 0;
    return (uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;
}
static struct ct_admission *CTFindJob(const struct totk_shader_job *job){
    if(!job||!job->ticket)return NULL;
    for(unsigned i=0;i<CT_FAILURE_RECORDS;i++){
        struct ct_admission *entry=&CTAdmissions[i];
        if(entry->used&&entry->epoch==job->epoch&&entry->ticket==job->ticket&&
           !memcmp(entry->digest,job->request_sha256,32))return entry;
    }return NULL;
}
static void CTFinish(struct totk_shader_job *job,enum totk_shader_outcome outcome){
    if(!job)return;
    job->outcome=(uint32_t)outcome;
    pthread_mutex_lock(&CTAdmissionLock);
    struct ct_admission *entry=CTFindJob(job);
    if(entry&&entry->in_flight){
        if(outcome==TOTK_SHADER_OK)memset(entry,0,sizeof(*entry));
        else{
            entry->in_flight=0;
            uint64_t now=CTNow();
            uint64_t delay=outcome==TOTK_SHADER_BUSY?UINT64_C(100000000):
                outcome==TOTK_SHADER_READY_LIMIT?UINT64_C(1000000000):
                entry->attempts<2?UINT64_C(250000000):UINT64_C(1000000000);
            entry->next_ns=outcome==TOTK_SHADER_CANCELLED||!now||now>UINT64_MAX-delay?UINT64_MAX:now+delay;
        }
    }
    pthread_mutex_unlock(&CTAdmissionLock);
}
static BOOL CTAdmit(struct totk_shader_job *job){
    uint64_t now=CTNow();
    if(!now||!CTCurrent(job->epoch)){job->outcome=TOTK_SHADER_CANCELLED;return NO;}
    pthread_mutex_lock(&CTAdmissionLock);
    if(!CTCurrent(job->epoch)){pthread_mutex_unlock(&CTAdmissionLock);job->outcome=TOTK_SHADER_CANCELLED;return NO;}
    struct ct_admission *found=NULL,*empty=NULL;
    for(unsigned i=0;i<CT_FAILURE_RECORDS;i++){
        struct ct_admission *entry=&CTAdmissions[i];
        if(entry->used&&entry->epoch!=job->epoch)memset(entry,0,sizeof(*entry));
        if(entry->used&&!memcmp(entry->digest,job->request_sha256,32))found=entry;
        if(!entry->used&&!empty)empty=entry;
    }
    BOOL ok=NO;
    if(found&&found->in_flight)job->outcome=TOTK_SHADER_BUSY;
    else if(found&&found->attempts>=CT_ATTEMPTS_PER_EPOCH)job->outcome=TOTK_SHADER_ATTEMPTS_EXHAUSTED;
    else if(found&&now<found->next_ns)job->outcome=TOTK_SHADER_BACKOFF;
    else if(!(found?:empty)||CTNextTicket==UINT64_MAX)job->outcome=TOTK_SHADER_ADMISSION_LIMIT;
    else{
        struct ct_admission *entry=found?:empty;
        if(!entry->used){memset(entry,0,sizeof(*entry));memcpy(entry->digest,job->request_sha256,32);entry->used=1;entry->epoch=job->epoch;}
        job->ticket=++CTNextTicket;entry->ticket=job->ticket;entry->in_flight=1;ok=YES;
    }
    pthread_mutex_unlock(&CTAdmissionLock);return ok;
}
static BOOL CTSpend(struct totk_shader_job *job){
    pthread_mutex_lock(&CTAdmissionLock);struct ct_admission *entry=CTFindJob(job);
    BOOL ok=CTCurrent(job->epoch)&&entry&&entry->in_flight&&entry->attempts<CT_ATTEMPTS_PER_EPOCH;
    if(ok)entry->attempts++;
    pthread_mutex_unlock(&CTAdmissionLock);return ok;
}
static uint64_t CTRetryToken(void){
    uint64_t now=CTNow(),epoch=atomic_load_explicit(&CTState,memory_order_acquire)&~UINT64_C(1);
    if(!now||!CTCurrent(epoch))return 0;
    uint64_t bucket=now/UINT64_C(250000000);
    pthread_mutex_lock(&CTAdmissionLock);
    if(epoch!=CTRetryEpoch||bucket>CTRetryBucket){
        if(CTRetrySerial!=UINT64_MAX)CTRetrySerial++;
        CTRetryEpoch=epoch;CTRetryBucket=bucket;
    }
    uint64_t token=CTRetrySerial;pthread_mutex_unlock(&CTAdmissionLock);return token;
}
static BOOL CTHex(NSString *s,NSUInteger length){
    if(![s isKindOfClass:NSString.class]||s.length!=length)return NO;
    for(NSUInteger i=0;i<length;i++){unichar c=[s characterAtIndex:i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return NO;}return YES;
}
static BOOL CTVariant(NSString *s){return [s isKindOfClass:NSString.class]&&s.length==77&&[s characterAtIndex:64]=='-'&&CTHex([s substringToIndex:64],64)&&CTHex([s substringFromIndex:65],12);}
static BOOL CTRegular(int fd,struct stat *st){return !fstat(fd,st)&&S_ISREG(st->st_mode)&&st->st_uid==geteuid()&&st->st_nlink==1&&(st->st_mode&0077)==0;}
static BOOL CTWrite(int fd,NSData *data,uint64_t epoch){
    size_t at=0;while(at<data.length){if(CTCancel(&epoch))return NO;size_t n=MIN((size_t)65536,data.length-at);ssize_t got=write(fd,(const uint8_t *)data.bytes+at,n);if(got<0&&errno==EINTR)continue;if(got<=0||(size_t)got>n)return NO;at+=(size_t)got;}return !fsync(fd);
}
/* Payloads are never replaced: an old index cannot observe half of a new
 * payload pair. A crash may leave unindexed files; only exact bytes reuse. */
static BOOL CTExisting(const char *name,NSData *data,uint64_t epoch){
    int fd=openat(CTDirectory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(fd<0)return NO;
    struct stat st,after;BOOL ok=CTRegular(fd,&st)&&st.st_size==(off_t)data.length;
    uint8_t bytes[65536];size_t at=0;
    while(ok&&at<data.length){if(CTCancel(&epoch)){ok=NO;break;}size_t n=MIN(sizeof(bytes),data.length-at);ssize_t got=read(fd,bytes,n);if(got<0&&errno==EINTR)continue;if(got<=0||(size_t)got>n||memcmp(bytes,(const uint8_t *)data.bytes+at,(size_t)got)){ok=NO;break;}at+=(size_t)got;}
    if(ok)ok=!fstat(fd,&after)&&st.st_dev==after.st_dev&&st.st_ino==after.st_ino&&st.st_size==after.st_size&&st.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec&&st.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec&&st.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec&&st.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec;
    close(fd);return ok;
}
static BOOL CTPublish(NSString *name,NSData *data,BOOL index,uint64_t epoch){
    if(!data||data.length>(16u<<20)||CTDirectory<0||CTCancel(&epoch))return NO;
    const char *leaf=name.UTF8String;struct stat prior;BOOL existed=NO;
    if(!fstatat(CTDirectory,leaf,&prior,AT_SYMLINK_NOFOLLOW)){
        existed=YES;
        if(!S_ISREG(prior.st_mode)||prior.st_uid!=geteuid()||prior.st_nlink!=1||(prior.st_mode&0077))return NO;
        if(!index)return CTExisting(leaf,data,epoch);
    }else if(errno!=ENOENT)return NO;
    if(data.length>CTQuota-CTBytes||(!existed&&CTFiles>=16384))return NO;
    NSString *temporary=[@".native-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd=openat(CTDirectory,temporary.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return NO;
    BOOL ok=CTWrite(fd,data,epoch);close(fd);
    if(ok&&CTCancel(&epoch))ok=NO;
    BOOL publishing=NO;
    if(ok&&index){
        uint64_t expected=epoch;
        /* Focus cancellation before this CAS wins. After it, a complete index
         * publication is authoritative; late focus does not undo cache facts. */
        publishing=atomic_compare_exchange_strong_explicit(&CTState,&expected,epoch|1,memory_order_acq_rel,memory_order_acquire);
        ok=publishing;
    }
    if(ok){
        if(index)ok=!renameat(CTDirectory,temporary.UTF8String,CTDirectory,leaf);
        else ok=!renameatx_np(CTDirectory,temporary.UTF8String,CTDirectory,leaf,RENAME_EXCL);
    }
    unlinkat(CTDirectory,temporary.UTF8String,0);
    if(ok){CTBytes+=data.length;if(!existed)CTFiles++;ok=!fsync(CTDirectory);}
    if(publishing)atomic_fetch_and_explicit(&CTState,~UINT64_C(1),memory_order_release);
    return ok;
}
static BOOL CTJSON(id value,unsigned depth,NSUInteger *nodes){
    if(depth>16||++*nodes>65536)return NO;
    if([value isKindOfClass:NSString.class])return [(NSString *)value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=(8u<<20);
    if(value==NSNull.null||[value isKindOfClass:NSNumber.class])return YES;
    if([value isKindOfClass:NSArray.class]){for(id item in value)if(!CTJSON(item,depth+1,nodes))return NO;return YES;}
    if([value isKindOfClass:NSDictionary.class]){for(id key in value)if(![key isKindOfClass:NSString.class]||!CTJSON(key,depth+1,nodes)||!CTJSON(value[key],depth+1,nodes))return NO;return YES;}return NO;
}
static BOOL CTDependencies(id value){
    if(![value isKindOfClass:NSDictionary.class]||[value count]!=4)return NO;
    for(NSString *kind in @[@"tex",@"img",@"attr",@"fout"]){
        id table=value[kind];if(![table isKindOfClass:NSDictionary.class]||[table count]>1024)return NO;
        for(id slot in table){if(![slot isKindOfClass:NSString.class]||![slot length]||[slot length]>4)return NO;
            for(NSUInteger i=0;i<[slot length];i++)if([slot characterAtIndex:i]<'0'||[slot characterAtIndex:i]>'9')return NO;
            if(![kind isEqual:@"img"]){if(![table[slot] isKindOfClass:NSString.class]||[table[slot] length]>64)return NO;}
            else {id image=table[slot];if(![image isKindOfClass:NSDictionary.class]||[image count]>2)return NO;for(id k in image)if(!([k isEqual:@"type"]||[k isEqual:@"fmt"])||![image[k] isKindOfClass:NSString.class]||[image[k] length]>64)return NO;}
        }
    }return YES;
}
static NSDictionary *CTTranslate(NSDictionary *request,NSData *code,struct totk_shader_job *job){
    if(!job)return nil;memset(job,0,sizeof(*job));job->outcome=TOTK_SHADER_INVALID;
    job->epoch=atomic_load_explicit(&CTState,memory_order_acquire)&~UINT64_C(1);
    uint64_t epoch=job->epoch;NSDictionary *result=nil;uint8_t *output=NULL;BOOL locked=NO,admitted=NO;
    @try{do{
        if(CTCancel(&epoch)){job->outcome=TOTK_SHADER_CANCELLED;break;}
        NSString *variant=request[@"variant"],*stage=request[@"stage"];
        if(!CTVariant(variant)||![code isKindOfClass:NSData.class]||code.length<16||code.length>65536||(code.length&7))break;
        NSMutableDictionary *rq=[NSMutableDictionary dictionary];
        for(NSString *key in @[@"variant",@"stage",@"c1",@"tex",@"img",@"attr",@"fout",@"local",@"depth_minus_w"]){id v=request[key];if(v)rq[key]=v;}
        rq[@"chain"]=CTChain;NSUInteger nodes=0;if(!CTJSON(rq,0,&nodes))break;
        NSData *json=[NSJSONSerialization dataWithJSONObject:rq options:NSJSONWritingSortedKeys error:NULL];if(!json.length||json.length>65536)break;
        CC_SHA256_CTX hash;CC_SHA256_Init(&hash);uint64_t lengths[]={code.length,json.length};
        CC_SHA256_Update(&hash,"canopy-native-request-v1",24);CC_SHA256_Update(&hash,lengths,sizeof(lengths));
        CC_SHA256_Update(&hash,code.bytes,(CC_LONG)code.length);CC_SHA256_Update(&hash,json.bytes,(CC_LONG)json.length);
        CC_SHA256_Final(job->request_sha256,&hash);
        if(!CTAdmit(job))break;admitted=YES;
        if(pthread_mutex_trylock(&CTLock)){job->outcome=TOTK_SHADER_BUSY;break;}locked=YES;
        job->outcome=TOTK_SHADER_TRANSLATION;
        output=malloc(16u<<20);if(!output){job->outcome=TOTK_SHADER_QUOTA;break;}size_t written=0;
        const struct canopy_shader_control control={1,sizeof(control),0,0,0,0,0,0,CTCancel,&epoch};
        if(CTCancel(&epoch)||!CTSpend(job)){job->outcome=TOTK_SHADER_CANCELLED;break;}
        int status=canopy_shader_translate_controlled(code.bytes,code.length,json.bytes,json.length,output,16u<<20,&written,&control);
        if(status){job->outcome=status>=1&&status<=6?(uint32_t)status:TOTK_SHADER_TRANSLATION;break;}
        if(!written||written>(16u<<20)||CTCancel(&epoch))break;
        NSData *encoded=[NSData dataWithBytesNoCopy:output length:written freeWhenDone:YES];
        if(!encoded)break;
        output=NULL; /* Parsed objects may retain their input's backing storage. */
        id envelope=[NSJSONSerialization JSONObjectWithData:encoded options:0 error:NULL];nodes=0;
        if(![envelope isKindOfClass:NSDictionary.class]||[envelope count]!=3||!CTJSON(envelope,0,&nodes))break;
        id metal=envelope[@"metal"],reflection=envelope[@"reflection"];
        if(![metal isKindOfClass:NSString.class]||![reflection isKindOfClass:NSDictionary.class]||!CTDependencies(reflection[@"deps"])||
           ![reflection[@"key"] isEqual:[variant stringByAppendingString:@"_b"]]||![reflection[@"chain"] isEqual:CTChain]||
           ![reflection[@"route"] isEqual:@"B"]||![reflection[@"stage"] isEqual:stage]||![reflection[@"entry"] isKindOfClass:NSString.class]||![reflection[@"entry"] length]||[reflection[@"entry"] length]>256)break;
        nvn_refl parsed;char error[160];if(nvn_refl_from_json(reflection,&parsed,error,sizeof(error)))break;
        NSData *msl=[metal dataUsingEncoding:NSUTF8StringEncoding],*refl=[NSJSONSerialization dataWithJSONObject:reflection options:NSJSONWritingSortedKeys error:NULL];
        NSString *base64=envelope[@"spirv_base64"];if(![base64 isKindOfClass:NSString.class]||base64.length>(6u<<20))break;
        NSData *spirv=[[NSData alloc] initWithBase64EncodedString:base64 options:0];
        static const uint8_t magic[]={3,2,35,7};
        if(!msl.length||msl.length>(8u<<20)||!refl.length||refl.length>(8u<<20)||spirv.length<20||spirv.length>(4u<<20)||(spirv.length&3)||memcmp(spirv.bytes,magic,4)||[metal containsString:@"double "]||[metal containsString:@"unsupported_GLSLstd450"])break;
        if(!CTPublish([variant stringByAppendingString:@"_b.metal"],msl,NO,epoch)||!CTPublish([variant stringByAppendingString:@"_b.json"],refl,NO,epoch)||!CTPublish([variant stringByAppendingString:@"_b.spv"],spirv,NO,epoch)){job->outcome=TOTK_SHADER_CACHE_IO;break;}
        if(CTCancel(&epoch))break;
        result=reflection;job->outcome=TOTK_SHADER_OK;
    }while(0);
    }@catch(NSException *exception){(void)exception;result=nil;job->outcome=TOTK_SHADER_TRANSLATION;}
    free(output);if(locked)pthread_mutex_unlock(&CTLock);
    if(!result&&admitted)CTFinish(job,CTCurrent(epoch)?(enum totk_shader_outcome)job->outcome:TOTK_SHADER_CANCELLED);
    return result;
}
static int CTIndex(NSString *shader,NSArray *rows,struct totk_shader_job *job){
    if(!job)return -1;
    if(!CTHex(shader,64)||![rows isKindOfClass:NSArray.class]||rows.count>16384){CTFinish(job,TOTK_SHADER_INVALID);return -1;}
    if(!CTCurrent(job->epoch)){CTFinish(job,TOTK_SHADER_CANCELLED);return -1;}
    pthread_mutex_lock(&CTLock);BOOL ok=NO;
    @try{do{BOOL valid=YES;for(id row in rows)if(![row isKindOfClass:NSDictionary.class]||[row count]!=2||!CTVariant(row[@"variant"])||![row[@"variant"] hasPrefix:shader]||!CTDependencies(row[@"deps"])){valid=NO;break;}if(!valid)break;
        pthread_mutex_lock(&CTAdmissionLock);struct ct_admission *entry=CTFindJob(job);BOOL active=entry&&entry->in_flight;pthread_mutex_unlock(&CTAdmissionLock);
        if(!active)break;
        ok=CTPublish([shader stringByAppendingString:@".variants"],[NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingSortedKeys error:NULL],YES,job->epoch);
    }while(0);
    }@catch(NSException *exception){(void)exception;}
    pthread_mutex_unlock(&CTLock);
    CTFinish(job,ok?TOTK_SHADER_OK:CTCurrent(job->epoch)?TOTK_SHADER_CACHE_IO:TOTK_SHADER_CANCELLED);
    return ok?0:-1;
}
const char *CanopyShaderTranslatorRecipe(void){return CANOPY_SHADER_PROVIDER_RECIPE_SHA256;}
static NSString *CTFile(NSString *name){
    if(![name isKindOfClass:NSString.class]||!name.length||name.length>128)return nil;
    for(NSUInteger i=0;i<name.length;i++){unichar c=[name characterAtIndex:i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-'||c=='.'))return nil;}
    if([name isEqual:@"."]||[name isEqual:@".."])return nil;
    return [CTPath stringByAppendingPathComponent:name];
}
static NSArray<NSString *> *CTFilesList(void){
    pthread_mutex_lock(&CTLock);NSMutableArray *names=[NSMutableArray array];
    int fd=openat(CTDirectory,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC);DIR *scan=fd>=0?fdopendir(fd):NULL;
    if(!scan){if(fd>=0)close(fd);pthread_mutex_unlock(&CTLock);return @[];}
    struct dirent *entry;BOOL valid=YES;unsigned count=0;
    for(;;){errno=0;entry=readdir(scan);if(!entry){if(errno)valid=NO;break;}if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        if(++count>16384){valid=NO;break;}NSString *name=@(entry->d_name);struct stat st;
        if(CTFile(name)&&!fstatat(CTDirectory,entry->d_name,&st,AT_SYMLINK_NOFOLLOW)&&S_ISREG(st.st_mode)&&st.st_uid==geteuid()&&st.st_nlink==1&&!(st.st_mode&0077))[names addObject:name];
        else{valid=NO;break;}
    }
    closedir(scan);pthread_mutex_unlock(&CTLock);return valid?[names sortedArrayUsingSelector:@selector(compare:)]:@[];
}
static struct totk_shader_provider CTProvider={TOTK_SHADER_PROVIDER_ABI,sizeof(CTProvider),CANOPY_SHADER_PROVIDER_RECIPE_SHA256,NULL,CTTranslate,CTIndex,CTFinish,CTCurrent,CTRetryToken,CTFile,CTFilesList};
const struct totk_shader_provider *CanopyShaderTranslatorProvider(void){return CTDirectory>=0?&CTProvider:NULL;}
void CanopyShaderTranslatorSetActive(int active){
    int value=!!active;if(atomic_load_explicit(&CTActive,memory_order_acquire)!=value){
        /* Epoch changes first: an index cutoff cannot overtake cancellation. */
        uint64_t before=atomic_fetch_add_explicit(&CTState,2,memory_order_acq_rel);
        if(before>=(UINT64_C(1)<<63)-2)atomic_store_explicit(&CTTerminal,1,memory_order_release);
        atomic_store_explicit(&CTActive,value,memory_order_release);
    }
}
void CanopyShaderTranslatorTerminate(void){
    /* Same atomic state as the publication CAS: terminal-before-cutoff wins. */
    atomic_fetch_or_explicit(&CTState,UINT64_C(1)<<63,memory_order_acq_rel);
    atomic_store_explicit(&CTTerminal,1,memory_order_release);CanopyShaderTranslatorSetActive(0);
}
int CanopyShaderTranslatorInstall(const char *cache,const char *chain){
    NSCAssert(NSThread.isMainThread,@"Native shader provider installs before renderer startup");
    if(CTDirectory>=0||!cache||!chain||!chain[0]||strlen(chain)>128||canopy_shader_abi_version()!=1||!CTHex(@CANOPY_SHADER_PROVIDER_RECIPE_SHA256,64))return -1;
    int root=open(cache,O_RDONLY|O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC);struct stat st;
    if(root<0)return -1;if(fstat(root,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&0077)){close(root);return -1;}
    NSString *leaf=[@"native-" stringByAppendingString:@CANOPY_SHADER_PROVIDER_RECIPE_SHA256];
    if(mkdirat(root,leaf.UTF8String,0700)&&errno!=EEXIST){close(root);return -1;}
    int fd=openat(root,leaf.UTF8String,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);BOOL valid=fd>=0&&!fstat(fd,&st)&&S_ISDIR(st.st_mode)&&st.st_uid==geteuid()&&!(st.st_mode&0077)&&!fsync(root);close(root);
    if(!valid){if(fd>=0)close(fd);return -1;}
    /* Bounded scan counts crash leftovers; nonregular entries refuse, no GC. */
    int scanfd=openat(fd,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC);DIR *scan=scanfd>=0?fdopendir(scanfd):NULL;if(!scan){if(scanfd>=0)close(scanfd);close(fd);return -1;}
    unsigned count=0;struct dirent *entry;uint64_t bytes=0;
    for(;;){errno=0;entry=readdir(scan);if(!entry){if(errno)valid=NO;break;}if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;if(++count>16384||fstatat(fd,entry->d_name,&st,AT_SYMLINK_NOFOLLOW)||!S_ISREG(st.st_mode)||st.st_uid!=geteuid()||st.st_nlink!=1||(st.st_mode&0077)||st.st_size<0||(uint64_t)st.st_size>CTQuota-bytes){valid=NO;break;}bytes+=(uint64_t)st.st_size;}
    closedir(scan);if(!valid){close(fd);return -1;}
    CTPath=[@(cache) stringByAppendingPathComponent:leaf];
    CTChain=@(chain);CTProvider.chain=CTChain.UTF8String;CTBytes=bytes;CTFiles=count;CTDirectory=fd;atomic_store_explicit(&CTState,2,memory_order_release);CanopyShaderTranslatorSetActive(1);return 0;
}
#else
int CanopyShaderTranslatorInstall(const char *cache,const char *chain){(void)cache;(void)chain;return 0;}
void CanopyShaderTranslatorSetActive(int active){(void)active;}
void CanopyShaderTranslatorTerminate(void){}
const struct totk_shader_provider *CanopyShaderTranslatorProvider(void){return NULL;}
const char *CanopyShaderTranslatorRecipe(void){return NULL;}
#endif
