#import <Foundation/Foundation.h>
#import "CanopyDiagnostics.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void Check(BOOL condition,const char *message) {
    if(!condition){fprintf(stderr,"FAIL: %s\n",message);exit(1);}
}
static NSDictionary *Entry(void) {
    return @{@"titleID":@"0100123456780000",@"applicationID":@"0100123456780000",
        @"patchTitleID":@"0100123456780800",@"generationID":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],
        @"sourceSHA256":[@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0],
        @"updateSourceSHA256":[@"c" stringByPaddingToLength:64 withString:@"c" startingAtIndex:0],
        @"sourceSize":@1234,@"updateSourceSize":@567,@"recipeID":@"canopy-assets-v3",
        @"titleVersion":@12,@"baseTitleVersion":@7,@"versionIdentified":@YES,@"updateApplied":@YES,
        @"assetCount":@3,@"assetBytes":@512,@"contentRole":@129,
        @"integrity":@{@"exefsVerified":@YES,@"romfsVerified":@YES,@"signatureVerified":@NO}};
}
static NSDictionary *Metrics(void) {
    return @{@"seedCopiedBytes":@0,@"seedReusedBytes":@123,@"seedFiles":@6,@"cacheReused":@YES,
             @"metadataWrittenBytes":@456,@"frameLimit":@60,@"nativeEntryInvoked":@YES};
}
static NSDictionary *Snapshot(CanopyDiagnostics *diagnostics,NSDictionary *entry,NSDictionary *metrics) {
    return [diagnostics snapshotPreparedEntry:entry phase:CanopyDiagnosticsPhaseActive
        errorCode:CanopyDiagnosticsErrorNone metrics:metrics];
}
static void DefaultOff(void) {
    CanopyDiagnostics *diagnostics=[CanopyDiagnostics new];
    Check(!diagnostics.enabled&&diagnostics.recordedSampleCount==0,"collection did not default off");
    Check(![diagnostics recordPreparedEntry:Entry() phase:CanopyDiagnosticsPhasePrepared
        errorCode:CanopyDiagnosticsErrorNone metrics:Metrics()],"disabled collection recorded");
    NSDictionary *snapshot=Snapshot(diagnostics,Entry(),Metrics());
    Check(![snapshot[@"collectionEnabled"] boolValue]&&[snapshot[@"recordedSamples"] count]==0,"disabled collection retained data");
    Check([snapshot[@"sample"][@"preparation"][@"titleID"] isEqual:Entry()[@"titleID"]],"user-demand snapshot unavailable when off");
}
static void History(void) {
    CanopyDiagnostics *diagnostics=[CanopyDiagnostics new];diagnostics.enabled=YES;
    for(unsigned i=0;i<20;i++){
        NSMutableDictionary *entry=[Entry() mutableCopy];entry[@"titleVersion"]=@(i);
        Check([diagnostics recordPreparedEntry:entry phase:CanopyDiagnosticsPhasePrepared
            errorCode:CanopyDiagnosticsErrorNone metrics:Metrics()],"enabled recording failed");
    }
    NSArray *samples=Snapshot(diagnostics,nil,nil)[@"recordedSamples"];
    Check(diagnostics.recordedSampleCount==16&&samples.count==16,"history exceeded bound");
    Check([samples[0][@"preparation"][@"titleVersion"] isEqual:@4]&&
        [samples[15][@"preparation"][@"titleVersion"] isEqual:@19],"history ordering lost");
    diagnostics.enabled=NO;
    Check(diagnostics.recordedSampleCount==0&&[Snapshot(diagnostics,nil,nil)[@"recordedSamples"] count]==0,"disabling did not clear");
}
static void Redaction(NSString *privateRoot) {
    NSString *secret=@"private-origin-secret-key";
    NSMutableDictionary *entry=[Entry() mutableCopy];
    entry[@"sourceURL"]=[NSURL fileURLWithPath:privateRoot];entry[@"deviceIdentifier"]=@"device-serial-private";
    entry[@"displayName"]=@"private-source.nsp";entry[@"profileID"]=@"private-profile";
    entry[@"stderr"]=@"raw-stderr-private";entry[@"keys"]=secret;entry[@"saveBytes"]=[secret dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *metrics=[Metrics() mutableCopy];metrics[@"device"]=@"device-serial-private";
    metrics[@"privatePath"]=privateRoot;metrics[@"gameplayFPS"]=@999;metrics[@"hudFPS"]=@999;
    CanopyDiagnostics *diagnostics=[CanopyDiagnostics new];diagnostics.enabled=YES;
    Check([diagnostics recordPreparedEntry:entry phase:CanopyDiagnosticsPhaseActive errorCode:CanopyDiagnosticsErrorIO metrics:metrics],"redaction record");
    NSError *error=nil;
    NSData *data=[diagnostics redactedJSONPreparedEntry:entry phase:CanopyDiagnosticsPhaseActive errorCode:CanopyDiagnosticsErrorIO metrics:metrics error:&error];
    Check(data&&error==nil&&data.length<=65536,"redacted export failed");
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    for(NSString *forbidden in @[secret,privateRoot,@"device-serial-private",@"private-source.nsp",@"private-profile",@"raw-stderr-private",@"saveBytes",@"hudFPS"])
        Check([text rangeOfString:forbidden].location==NSNotFound,"private data escaped whitelist");
    NSDictionary *decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    Check([decoded[@"sample"][@"metrics"][@"seedReusedBytes"] isEqual:@123],"actual reuse metric dropped");
    Check([decoded[@"sample"][@"session"][@"errorCode"] isEqual:@"io"],"closed error missing");
}
static void Malformed(void) {
    NSDictionary *entry=@{@"titleID":@"private-path",@"applicationID":[NSURL fileURLWithPath:@"/private/secret"],
        @"generationID":[@"A" stringByPaddingToLength:64 withString:@"A" startingAtIndex:0],@"recipeID":@"/private/recipe",
        @"sourceSize":@YES,@"updateSourceSize":@(UINT64_MAX),@"titleVersion":@((uint64_t)UINT32_MAX+1),
        @"baseTitleVersion":@(NAN),@"versionIdentified":@1,@"updateApplied":@"true",@"contentRole":@200,
        @"assetCount":@129,@"assetBytes":@((UINT64_C(64)<<30)+1),
        @"integrity":@{@"exefsVerified":@1,@"romfsVerified":@"true",@"signatureVerified":@YES}};
    NSDictionary *metrics=@{@"seedCopiedBytes":@(-1),@"seedReusedBytes":@(INFINITY),@"metadataWrittenBytes":@1.5,
        @"frameLimit":@120,@"seedFiles":@100003,@"cacheReused":@1,@"nativeEntryInvoked":@1,
        @"phaseDone":@11,@"phaseTotal":@10};
    CanopyDiagnostics *diagnostics=[CanopyDiagnostics new];
    NSDictionary *snapshot=[diagnostics snapshotPreparedEntry:entry phase:(CanopyDiagnosticsPhase)999
        errorCode:(CanopyDiagnosticsError)-99 metrics:metrics];
    NSDictionary *sample=snapshot[@"sample"];
    Check([sample[@"preparation"] count]==0&&[sample[@"metrics"] count]==0&&[sample[@"configuration"] count]==0,"malformed values survived");
    Check([sample[@"session"][@"phase"] isEqual:@"unknown"]&&[sample[@"session"][@"errorCode"] isEqual:@"unknown"],"enum value escaped");
    NSError *failure=nil;
    Check([diagnostics redactedJSONPreparedEntry:entry phase:0 errorCode:0 metrics:metrics error:&failure]!=nil&&failure==nil,"bad ignored data broke export");
}
static void MemoryAndRates(void) {
    CanopyDiagnostics *diagnostics=[CanopyDiagnostics new];
    NSMutableDictionary *metrics=[Metrics() mutableCopy];
    for(NSString *key in @[@"gameplayFPS",@"presentationFPS",@"generatedFPS",@"fps",@"residentBytes",@"physicalFootprintBytes"])
        metrics[key]=@999;
    NSDictionary *sample=Snapshot(diagnostics,Entry(),metrics)[@"sample"],*memory=sample[@"memory"],*thermal=sample[@"thermal"];
    Check([memory[@"scope"] isEqual:@"wholeProcess"]&&[memory[@"source"] isEqual:@"mach_task_self"],"memory scope mislabeled");
    for(NSArray *pair in @[@[@"residentStatus",@"residentBytes"],@[@"footprintStatus",@"physicalFootprintBytes"]]) {
        if([memory[pair[0]] isEqual:@"available"])Check([memory[pair[1]] isKindOfClass:NSNumber.class]&&[memory[pair[1]] unsignedLongLongValue]>0,"bad real memory sample");
        else Check([memory[pair[0]] isEqual:@"unavailable"]&&memory[pair[1]]==NSNull.null,"unavailable memory guessed zero");
    }
    Check([thermal[@"source"] isEqual:@"NSProcessInfo"],"thermal source");
    if([thermal[@"status"] isEqual:@"available"])Check([@[@"nominal",@"fair",@"serious",@"critical"] containsObject:thermal[@"state"]],"thermal enum");
    else Check(thermal[@"state"]==NSNull.null,"thermal guessed");
    NSDictionary *rates=sample[@"rates"];
    Check(rates[@"gameplayFPS"]==NSNull.null&&rates[@"presentationFPS"]==NSNull.null&&rates[@"generatedFPS"]==NSNull.null,"invented FPS");
    Check([rates[@"status"] isEqual:@"unavailable"]&&[sample[@"configuration"][@"frameLimit"] isEqual:@60],"ceiling confused with FPS");
    Check([sample[@"session"][@"nativeEntryInvoked"] isEqual:@YES],"observed session fact lost");
}
static void Mappings(void) {
    Check([CanopyDiagnostics phaseForRuntimeState:@"preparing"]==CanopyDiagnosticsPhasePreflight,"runtime preparation phase");
    Check([CanopyDiagnostics phaseForRuntimeState:@"inputCaptured"]==CanopyDiagnosticsPhaseInputCaptured,"runtime captured phase");
    Check([CanopyDiagnostics phaseForRuntimeState:@"private-path"]==CanopyDiagnosticsPhaseUnknown,"unknown state accepted");
    Check([CanopyDiagnostics errorForError:nil]==CanopyDiagnosticsErrorNone,"nil error");
    NSDictionary *mapping=@{@1:@(CanopyDiagnosticsErrorInvalid),@2:@(CanopyDiagnosticsErrorIO),@3:@(CanopyDiagnosticsErrorUnsupported),
        @4:@(CanopyDiagnosticsErrorKeys),@5:@(CanopyDiagnosticsErrorIntegrity),@6:@(CanopyDiagnosticsErrorCancelled),@7:@(CanopyDiagnosticsErrorLimit),@8:@(CanopyDiagnosticsErrorLimit)};
    for(NSNumber *code in mapping) {
        NSError *error=[NSError errorWithDomain:@"CanopyPreparation" code:code.integerValue userInfo:@{NSLocalizedDescriptionKey:@"private-key-in-error"}];
        Check([CanopyDiagnostics errorForError:error]==[mapping[code] integerValue],"preparation error mapping");
    }
    NSError *native=[NSError errorWithDomain:@"CanopyRuntime" code:5 userInfo:nil];
    Check([CanopyDiagnostics errorForError:native]==CanopyDiagnosticsErrorNativeStart,"native start category");
    NSError *unknown=[NSError errorWithDomain:@"/private/source" code:123 userInfo:nil];
    Check([CanopyDiagnostics errorForError:unknown]==CanopyDiagnosticsErrorUnknown,"unknown domain copied");
}
static void PreparationContract(void) {
    NSMutableDictionary *entry=[Entry() mutableCopy];[entry removeObjectForKey:@"integrity"];
    entry[@"exefsVerified"]=@YES;entry[@"romfsVerified"]=@YES;entry[@"signatureVerified"]=@NO;
    entry[@"jobID"]=@"private-internal-job";
    CanopyDiagnostics *diagnostics=[CanopyDiagnostics new];
    NSDictionary *sample=Snapshot(diagnostics,entry,@{@"phaseDone":@3,@"phaseTotal":@12,@"phaseUnit":@"blocks"})[@"sample"];
    Check([sample[@"preparation"][@"integrity"] isEqual:@{@"exefsVerified":@YES,@"romfsVerified":@YES,@"signatureVerified":@NO}],"flat preparation flags lost");
    Check(sample[@"preparation"][@"jobID"]==nil,"internal job identity retained");
    Check([sample[@"metrics"][@"phaseDone"] isEqual:@3]&&[sample[@"metrics"][@"phaseUnit"] isEqual:@"blocks"],"progress mislabeled");
    sample=Snapshot(diagnostics,entry,@{@"phaseDone":@0,@"phaseTotal":@0,@"phaseUnit":@"/private/secret"})[@"sample"];
    Check([sample[@"metrics"][@"phaseUnit"] isEqual:@"unspecified"],"unrecognized unit text retained");
}
static void ImmutableAndBounded(void) {
    CanopyDiagnostics *diagnostics=[CanopyDiagnostics new];diagnostics.enabled=YES;
    NSMutableDictionary *entry=[Entry() mutableCopy],*metrics=[Metrics() mutableCopy];
    NSMutableString *source=[entry[@"sourceSHA256"] mutableCopy];entry[@"sourceSHA256"]=source;
    Check([diagnostics recordPreparedEntry:entry phase:CanopyDiagnosticsPhasePrepared errorCode:0 metrics:metrics],"immutable record");
    NSString *original=[source copy];[source setString:[@"d" stringByPaddingToLength:64 withString:@"d" startingAtIndex:0]];
    metrics[@"seedReusedBytes"]=@999;
    NSDictionary *record=Snapshot(diagnostics,nil,nil)[@"recordedSamples"][0];
    Check([record[@"preparation"][@"sourceSHA256"] isEqual:original]&&[record[@"metrics"][@"seedReusedBytes"] isEqual:@123],"retained mutable input");
    for(unsigned i=0;i<10000;i++)entry[[NSString stringWithFormat:@"private-unknown-%u",i]]=@"private-ignored-value";
    for(unsigned i=0;i<32;i++)Check([diagnostics recordPreparedEntry:entry phase:CanopyDiagnosticsPhasePrepared errorCode:0 metrics:metrics],"bounded record");
    NSError *error=nil;NSData *data=[diagnostics redactedJSONPreparedEntry:entry phase:CanopyDiagnosticsPhasePrepared errorCode:0 metrics:metrics error:&error];
    Check(data&&data.length<=65536&&diagnostics.recordedSampleCount==16,"export/history unbounded");
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    Check([text rangeOfString:@"private-ignored"].location==NSNotFound,"unrecognized fields exported");
}
static void Concurrent(void) {
    CanopyDiagnostics *diagnostics=[CanopyDiagnostics new];diagnostics.enabled=YES;
    dispatch_group_t group=dispatch_group_create();
    for(unsigned worker=0;worker<3;worker++)dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{@autoreleasepool{
        for(unsigned i=0;i<64;i++)(void)[diagnostics recordPreparedEntry:Entry() phase:CanopyDiagnosticsPhaseActive errorCode:0 metrics:Metrics()];
    }});
    for(unsigned i=0;i<32;i++) {
        diagnostics.enabled=(i&1)!=0;
        NSDictionary *snapshot=Snapshot(diagnostics,nil,nil);
        if(![snapshot[@"collectionEnabled"] boolValue])Check([snapshot[@"recordedSamples"] count]==0,"disabled concurrent history retained");
        Check([snapshot[@"recordedSamples"] count]<=16,"concurrent history limit");
    }
    Check(!dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)),"concurrent diagnostics deadline");
    diagnostics.enabled=NO;Check(diagnostics.recordedSampleCount==0,"concurrent final clear");
}
static void Sources(NSString *privateRoot) {
    CanopyDiagnostics *diagnostics=[CanopyDiagnostics new];CanopyDiagnosticsSources *sources=[CanopyDiagnosticsSources new];
    __block NSUInteger reads=0;
    sources.preparedEntry=^NSDictionary *{Check(NSThread.isMainThread,"provider off main");reads++;return Entry();};
    sources.metrics=^NSDictionary *{return @{@"seedReusedBytes":@10,@"frameLimit":@40,@"nativeEntryInvoked":@YES,@"hudFPS":@999,@"privatePath":privateRoot,@"storageListedJobs":@99};};
    sources.phase=^CanopyDiagnosticsPhase{return CanopyDiagnosticsPhaseInputCaptured;};
    sources.errorCode=^CanopyDiagnosticsError{return CanopyDiagnosticsErrorBusy;};
    sources.storageSnapshot=^NSDictionary *{return @{@"complete":@NO,@"issues":@[privateRoot],
        @"generations":@[@{@"verification":@"verified",@"logicalAssetBytes":@30},@{@"verification":@"notChecked",@"logicalAssetBytes":@999}],
        @"jobs":@[@{@"identifier":@"not exported"}],@"shaders":@[@{@"usageState":@"available",@"seedBytes":@40,@"runtimeBytes":@50},
            @{@"usageState":@"unavailable",@"seedBytes":@100,@"runtimeBytes":@100}]};};
    NSDictionary *snapshot=[sources snapshotWithDiagnostics:diagnostics recordIfEnabled:YES];
    Check(reads==1&&diagnostics.recordedSampleCount==0,"provider demand/off contract");
    NSDictionary *sample=snapshot[@"sample"],*metrics=sample[@"metrics"];
    Check([sample[@"configuration"][@"frameLimit"] isEqual:@40]&&[sample[@"session"][@"nativeEntryInvoked"] isEqual:@YES],"source adapter dropped actual configuration/session observations");
    Check([sample[@"session"][@"phase"] isEqual:@"inputCaptured"]&&[sample[@"session"][@"errorCode"] isEqual:@"busy"],"actual provider enums dropped");
    Check([metrics[@"storageListedGenerations"] isEqual:@2]&&[metrics[@"storageVerifiedGenerations"] isEqual:@1]&&
        [metrics[@"storageVerifiedAssetBytes"] isEqual:@30]&&[metrics[@"storageListedJobs"] isEqual:@1],"listed vs verified storage conflated");
    Check([metrics[@"storageListedShaders"] isEqual:@2]&&[metrics[@"storageAvailableShaders"] isEqual:@1]&&
        [metrics[@"storageAvailableSeedBytes"] isEqual:@40]&&[metrics[@"storageAvailableRuntimeBytes"] isEqual:@50],"shader available totals wrong");
    Check([metrics[@"storageListingComplete"] isEqual:@NO]&&sample[@"rates"][@"gameplayFPS"]==NSNull.null,"partial storage/FPS guessed");
    diagnostics.enabled=YES;
    for(unsigned i=0;i<20;i++)(void)[sources snapshotWithDiagnostics:diagnostics recordIfEnabled:YES];
    Check(diagnostics.recordedSampleCount==16&&reads==21,"source history bound");
    NSError *error=nil;NSData *json=[sources redactedJSONWithDiagnostics:diagnostics error:&error];
    Check(json&&json.length<=65536&&error==nil&&reads==22,"source export bounds");
    NSDictionary *exported=[NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    Check([exported[@"sample"][@"configuration"][@"frameLimit"] isEqual:@40]&&
        [exported[@"sample"][@"session"][@"nativeEntryInvoked"] isEqual:@YES],"source export dropped actual configuration/session observations");
    NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    Check([text rangeOfString:privateRoot].location==NSNotFound&&[text rangeOfString:@"not exported"].location==NSNotFound,"source/storage private text escaped");
    diagnostics.enabled=NO;(void)[sources snapshotWithDiagnostics:diagnostics recordIfEnabled:NO];
    Check(diagnostics.recordedSampleCount==0,"source disable did not clear");
}
static void StorageBounds(void) {
    CanopyDiagnostics *diagnostics=[CanopyDiagnostics new];CanopyDiagnosticsSources *sources=[CanopyDiagnosticsSources new];
    NSMutableArray *tooMany=[NSMutableArray new];for(unsigned i=0;i<129;i++)[tooMany addObject:@{}];
    sources.storageSnapshot=^NSDictionary *{return @{@"complete":@1,@"generations":tooMany,@"jobs":@"private text",@"shaders":@[
        @{@"usageState":@"available",@"seedBytes":@YES,@"runtimeBytes":@40},
        @{@"usageState":@"available",@"seedBytes":@(-1),@"runtimeBytes":@40},
        @{@"usageState":@"available",@"seedBytes":@40,@"runtimeBytes":@((UINT64_C(128)<<30)+1)}]};};
    NSDictionary *metrics=[sources snapshotWithDiagnostics:diagnostics recordIfEnabled:NO][@"sample"][@"metrics"];
    Check(metrics[@"storageListedGenerations"]==nil&&metrics[@"storageListedJobs"]==nil&&metrics[@"storageListingComplete"]==nil,"unbounded/malformed storage accepted");
    Check([metrics[@"storageAvailableShaders"] isEqual:@0]&&[metrics[@"storageAvailableSeedBytes"] isEqual:@0],"malformed bytes added");
    CanopyDiagnosticsSources *empty=[CanopyDiagnosticsSources new];NSDictionary *sample=[empty snapshotWithDiagnostics:diagnostics recordIfEnabled:NO][@"sample"];
    Check([sample[@"preparation"] count]==0&&[sample[@"metrics"] count]==0&&[sample[@"session"][@"phase"] isEqual:@"unknown"],"missing source guessed");
    for(NSDictionary *invalid in @[@{@"frameLimit":@YES,@"nativeEntryInvoked":@1},@{@"frameLimit":@120,@"nativeEntryInvoked":@"true"},@{@"frameLimit":@40.5}]) {
        empty.metrics=^NSDictionary *{return invalid;};
        NSDictionary *invalidSample=[empty snapshotWithDiagnostics:diagnostics recordIfEnabled:NO][@"sample"];
        Check([invalidSample[@"configuration"] count]==0&&invalidSample[@"session"][@"nativeEntryInvoked"]==nil,"source adapter forwarded malformed configuration/session fields");
    }
}
static void FolderProvenance(void) {
    NSMutableDictionary *entry=[Entry() mutableCopy];entry[@"sourceKind"]=@"asset-folder";entry[@"recipeID"]=@"canopy-assets-v4";
    entry[@"memberInventorySHA256"]=[@"d" stringByPaddingToLength:64 withString:@"d" startingAtIndex:0];
    entry[@"sourceMemberCount"]=@4;entry[@"sourceMemberBytes"]=@123;
    entry[@"integrity"]=@{@"exefsVerified":@NO,@"romfsVerified":@NO,@"assetHashesVerified":@YES,@"romfsStructureVerified":@YES};
    NSDictionary *prepared=Snapshot([CanopyDiagnostics new],entry,nil)[@"sample"][@"preparation"];
    Check([prepared[@"sourceKind"] isEqual:@"asset-folder"]&&[prepared[@"recipeID"] isEqual:@"canopy-assets-v4"]&&
        [prepared[@"sourceMemberCount"] isEqual:@4]&&[prepared[@"sourceMemberBytes"] isEqual:@123],"actual folder provenance dropped");
    Check(prepared[@"sourceSHA256"]==nil&&prepared[@"sourceSize"]==nil&&prepared[@"updateSourceSHA256"]==nil&&prepared[@"updateSourceSize"]==nil,"folder claimed physical container identity");
    Check([prepared[@"integrity"][@"assetHashesVerified"] isEqual:@YES]&&[prepared[@"integrity"][@"romfsStructureVerified"] isEqual:@YES],"structure and hash distinction lost");
}
int main(int argc,const char *argv[]) {@autoreleasepool {
    Check(argc==3,"arguments");NSString *mode=@(argv[1]),*root=@(argv[2]);
    if([mode isEqual:@"default"])DefaultOff();else if([mode isEqual:@"history"])History();
    else if([mode isEqual:@"redaction"])Redaction(root);else if([mode isEqual:@"malformed"])Malformed();
    else if([mode isEqual:@"memory"])MemoryAndRates();else if([mode isEqual:@"mapping"])Mappings();
    else if([mode isEqual:@"preparation"])PreparationContract();
    else if([mode isEqual:@"bounded"])ImmutableAndBounded();else if([mode isEqual:@"concurrent"])Concurrent();
    else if([mode isEqual:@"sources"])Sources(root);else if([mode isEqual:@"storageBounds"])StorageBounds();
    else if([mode isEqual:@"folder"])FolderProvenance();
    else Check(NO,"unknown scenario");
    puts("{\"status\":\"pass\",\"scope\":\"bounded diagnostic metadata, not gameplay or performance acceptance\"}");
}return 0;}
