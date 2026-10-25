#import "CanopyDiagnostics.h"
#import <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>

static BOOL CDBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();
}
static BOOL CDInteger(id value,uint64_t maximum) {
    if(![value isKindOfClass:NSNumber.class] || CDBoolean(value))return NO;
    double number=[value doubleValue];
    return isfinite(number) && number>=0 && floor(number)==number && number<=(double)maximum &&
        [value unsignedLongLongValue]<=maximum;
}
static BOOL CDHex(id value,NSUInteger length) {
    return [value isKindOfClass:NSString.class] && [value length]==length &&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static NSString *CDPhase(CanopyDiagnosticsPhase phase) {
    switch(phase) {
        case CanopyDiagnosticsPhaseIdle:return @"idle";
        case CanopyDiagnosticsPhaseInspecting:return @"inspecting";
        case CanopyDiagnosticsPhasePreparing:return @"preparing";
        case CanopyDiagnosticsPhaseVerifying:return @"verifying";
        case CanopyDiagnosticsPhaseComposing:return @"composing";
        case CanopyDiagnosticsPhasePrepared:return @"prepared";
        case CanopyDiagnosticsPhasePreflight:return @"preflight";
        case CanopyDiagnosticsPhaseStarting:return @"starting";
        case CanopyDiagnosticsPhaseActive:return @"active";
        case CanopyDiagnosticsPhaseInputCaptured:return @"inputCaptured";
        case CanopyDiagnosticsPhaseCancelling:return @"cancelling";
        case CanopyDiagnosticsPhaseFailed:return @"failed";
        case CanopyDiagnosticsPhaseClosed:return @"closed";
        case CanopyDiagnosticsPhaseUnsupported:return @"unsupported";
        default:return @"unknown";
    }
}
static NSString *CDError(CanopyDiagnosticsError error) {
    switch(error) {
        case CanopyDiagnosticsErrorNone:return @"none";
        case CanopyDiagnosticsErrorCancelled:return @"cancelled";
        case CanopyDiagnosticsErrorInvalid:return @"validationFailed";
        case CanopyDiagnosticsErrorUnsupported:return @"unsupported";
        case CanopyDiagnosticsErrorKeys:return @"keysUnavailable";
        case CanopyDiagnosticsErrorIntegrity:return @"integrity";
        case CanopyDiagnosticsErrorIO:return @"io";
        case CanopyDiagnosticsErrorBusy:return @"busy";
        case CanopyDiagnosticsErrorUnverified:return @"unverified";
        case CanopyDiagnosticsErrorNativeStart:return @"nativeStart";
        case CanopyDiagnosticsErrorNativeBackend:return @"nativeBackend";
        case CanopyDiagnosticsErrorLimit:return @"resourceLimit";
        default:return @"unknown";
    }
}
static NSDictionary *CDPreparation(id supplied) {
    if(![supplied isKindOfClass:NSDictionary.class])return @{};
    NSDictionary *entry=supplied;
    NSMutableDictionary *safe=[NSMutableDictionary new];
    for(NSString *key in @[@"titleID",@"applicationID",@"patchTitleID"])
        if(CDHex(entry[key],16))safe[key]=[entry[key] copy];
    for(NSString *key in @[@"generationID",@"sourceSHA256",@"updateSourceSHA256"])
        if(CDHex(entry[key],64))safe[key]=[entry[key] copy];
    if([@[@"canopy-assets-v1",@"canopy-assets-v2",@"canopy-assets-v3"] containsObject:entry[@"recipeID"]])safe[@"recipeID"]=[entry[@"recipeID"] copy];
    for(NSString *key in @[@"sourceSize",@"updateSourceSize"])
        if(CDInteger(entry[key],INT64_MAX))safe[key]=entry[key];
    for(NSString *key in @[@"titleVersion",@"baseTitleVersion"])
        if(CDInteger(entry[key],UINT32_MAX))safe[key]=entry[key];
    for(NSString *key in @[@"versionIdentified",@"updateApplied"])
        if(CDBoolean(entry[key]))safe[key]=entry[key];
    if(CDInteger(entry[@"assetCount"],128))safe[@"assetCount"]=entry[@"assetCount"];
    if(CDInteger(entry[@"assetBytes"],UINT64_C(64)<<30))safe[@"assetBytes"]=entry[@"assetBytes"];
    if(CDInteger(entry[@"contentRole"],255) && [@[@0,@128,@129] containsObject:entry[@"contentRole"]])safe[@"contentRole"]=entry[@"contentRole"];
    // Catalog entries nest these flags; preparation completions expose the
    // same booleans directly. Normalize both actual caller contracts.
    NSDictionary *suppliedIntegrity=[entry[@"integrity"] isKindOfClass:NSDictionary.class] ? entry[@"integrity"]:entry;
    NSMutableDictionary *integrity=[NSMutableDictionary new];
    for(NSString *key in @[@"exefsVerified",@"romfsVerified"])
        if(CDBoolean(suppliedIntegrity[key]))integrity[key]=suppliedIntegrity[key];
    // No signature verifier is connected by this preparation pipeline.
    if(CDBoolean(suppliedIntegrity[@"signatureVerified"]) && ![suppliedIntegrity[@"signatureVerified"] boolValue])integrity[@"signatureVerified"]=@NO;
    if(integrity.count)safe[@"integrity"]=[integrity copy];
    return [safe copy];
}
static NSDictionary *CDMetrics(id supplied) {
    if(![supplied isKindOfClass:NSDictionary.class])return @{};
    NSDictionary *metrics=supplied;
    NSMutableDictionary *safe=[NSMutableDictionary new];
    // Logical bytes observed by actual import/storage operations. Never total
    // renderer work, physical allocation, clone savings or frame throughput.
    for(NSString *key in @[@"seedCopiedBytes",@"seedReusedBytes",@"metadataWrittenBytes",@"seedBytes",@"runtimeBytes",@"clearedBytes"])
        if(CDInteger(metrics[key],UINT64_C(1)<<40))safe[key]=metrics[key];
    if(CDInteger(metrics[@"seedFiles"],100002))safe[@"seedFiles"]=metrics[@"seedFiles"];
    if(CDInteger(metrics[@"filesAndDirectories"],200010))safe[@"filesAndDirectories"]=metrics[@"filesAndDirectories"];
    if(CDBoolean(metrics[@"cacheReused"]))safe[@"cacheReused"]=metrics[@"cacheReused"];
    // Native preparation reports bytes for hashing/writing, blocks for IVFC
    // and records for BKTR. Never relabel all progress counts as bytes.
    if(CDInteger(metrics[@"phaseDone"],INT64_MAX) && CDInteger(metrics[@"phaseTotal"],INT64_MAX) &&
        [metrics[@"phaseDone"] unsignedLongLongValue]<=[metrics[@"phaseTotal"] unsignedLongLongValue]) {
        safe[@"phaseDone"]=metrics[@"phaseDone"];safe[@"phaseTotal"]=metrics[@"phaseTotal"];
        id unit=metrics[@"phaseUnit"];
        safe[@"phaseUnit"]=[@[@"bytes",@"blocks",@"records"] containsObject:unit] ? [unit copy]:@"unspecified";
    }
    return [safe copy];
}
static NSDictionary *CDMemory(void) {
    id resident=NSNull.null,footprint=NSNull.null;
    mach_task_basic_info_data_t basic={0};mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    if(task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&basic,&count)==KERN_SUCCESS && count>=MACH_TASK_BASIC_INFO_COUNT)
        resident=@(basic.resident_size);
    task_vm_info_data_t vm={0};count=TASK_VM_INFO_COUNT;
    if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vm,&count)==KERN_SUCCESS &&
        (size_t)count*sizeof(natural_t)>=offsetof(task_vm_info_data_t,phys_footprint)+sizeof(vm.phys_footprint))footprint=@(vm.phys_footprint);
    return @{@"residentBytes":resident,@"residentStatus":resident==NSNull.null?@"unavailable":@"available",
        @"physicalFootprintBytes":footprint,@"footprintStatus":footprint==NSNull.null?@"unavailable":@"available",
        @"scope":@"wholeProcess",@"source":@"mach_task_self"};
}
static NSDictionary *CDThermal(void) {
    if(@available(macOS 10.10.3,iOS 11.0,*)) {
        NSString *state=nil;
        switch(NSProcessInfo.processInfo.thermalState) {
            case NSProcessInfoThermalStateNominal:state=@"nominal";break;
            case NSProcessInfoThermalStateFair:state=@"fair";break;
            case NSProcessInfoThermalStateSerious:state=@"serious";break;
            case NSProcessInfoThermalStateCritical:state=@"critical";break;
            default:break;
        }
        if(state)return @{@"state":state,@"status":@"available",@"source":@"NSProcessInfo"};
    }
    return @{@"state":NSNull.null,@"status":@"unavailable",@"source":@"NSProcessInfo"};
}
static NSDictionary *CDSample(NSDictionary *entry,CanopyDiagnosticsPhase phase,CanopyDiagnosticsError error,NSDictionary *metrics) {
    NSMutableDictionary *session=[@{@"phase":CDPhase(phase),@"errorCode":CDError(error)} mutableCopy];
    NSMutableDictionary *configuration=[NSMutableDictionary new];
    if([metrics isKindOfClass:NSDictionary.class]) {
        if(CDBoolean(metrics[@"nativeEntryInvoked"]))session[@"nativeEntryInvoked"]=metrics[@"nativeEntryInvoked"];
        if(CDInteger(metrics[@"frameLimit"],60) && [@[@30,@40,@60] containsObject:metrics[@"frameLimit"]])configuration[@"frameLimit"]=metrics[@"frameLimit"];
    }
    return @{@"preparation":CDPreparation(entry),@"session":[session copy],@"metrics":CDMetrics(metrics),
        @"configuration":[configuration copy],@"memory":CDMemory(),@"thermal":CDThermal(),
        @"rates":@{@"gameplayFPS":NSNull.null,@"presentationFPS":NSNull.null,@"generatedFPS":NSNull.null,
            @"status":@"unavailable",@"reason":@"No trusted frame counter is connected. Frame limits are configuration."}};
}

@implementation CanopyDiagnostics {
    BOOL _enabled;
    NSMutableArray<NSDictionary *> *_samples;
}
- (instancetype)init {if((self=[super init])){_enabled=NO;_samples=[NSMutableArray new];}return self;}
- (BOOL)enabled {@synchronized(self){return _enabled;}}
- (void)setEnabled:(BOOL)value {@synchronized(self){_enabled=value;if(!value)[_samples removeAllObjects];}}
- (NSUInteger)recordedSampleCount {@synchronized(self){return _samples.count;}}
+ (CanopyDiagnosticsPhase)phaseForRuntimeState:(NSString *)state {
    NSDictionary *phases=@{@"idle":@(CanopyDiagnosticsPhaseIdle),@"preparing":@(CanopyDiagnosticsPhasePreflight),
        @"starting":@(CanopyDiagnosticsPhaseStarting),@"active":@(CanopyDiagnosticsPhaseActive),
        @"inputCaptured":@(CanopyDiagnosticsPhaseInputCaptured),@"cancelling":@(CanopyDiagnosticsPhaseCancelling),
        @"failed":@(CanopyDiagnosticsPhaseFailed),@"closed":@(CanopyDiagnosticsPhaseClosed),@"unsupported":@(CanopyDiagnosticsPhaseUnsupported)};
    NSNumber *phase=[state isKindOfClass:NSString.class]?phases[state]:nil;
    return phase ? (CanopyDiagnosticsPhase)phase.integerValue:CanopyDiagnosticsPhaseUnknown;
}
+ (CanopyDiagnosticsError)errorForError:(NSError *)error {
    if(!error)return CanopyDiagnosticsErrorNone;
    if(![error isKindOfClass:NSError.class])return CanopyDiagnosticsErrorUnknown;
    if([error.domain isEqual:@"CanopyPreparation"]) {
        switch(error.code) {
            case 1:return CanopyDiagnosticsErrorInvalid;case 2:return CanopyDiagnosticsErrorIO;
            case 3:return CanopyDiagnosticsErrorUnsupported;case 4:return CanopyDiagnosticsErrorKeys;
            case 5:return CanopyDiagnosticsErrorIntegrity;case 6:return CanopyDiagnosticsErrorCancelled;
            case 7:case 8:return CanopyDiagnosticsErrorLimit;default:return CanopyDiagnosticsErrorUnknown;
        }
    }
    if([error.domain isEqual:@"CanopyRuntime"]) {
        switch(error.code) {
            case 3:case 6:return CanopyDiagnosticsErrorUnsupported;case 4:return CanopyDiagnosticsErrorInvalid;
            case 5:return CanopyDiagnosticsErrorNativeStart;case 7:return CanopyDiagnosticsErrorCancelled;
            default:return CanopyDiagnosticsErrorUnknown;
        }
    }
    if([error.domain isEqual:@"CanopyShaderCache"]) {
        switch(error.code) {case 1:return CanopyDiagnosticsErrorUnverified;case 2:return CanopyDiagnosticsErrorCancelled;
            case 3:return CanopyDiagnosticsErrorBusy;default:return CanopyDiagnosticsErrorUnknown;}
    }
    return CanopyDiagnosticsErrorUnknown;
}
- (BOOL)recordPreparedEntry:(NSDictionary *)entry phase:(CanopyDiagnosticsPhase)phase errorCode:(CanopyDiagnosticsError)error metrics:(NSDictionary *)metrics {
    if(!self.enabled)return NO;
    NSDictionary *sample=CDSample(entry,phase,error,metrics);
    @synchronized(self){if(!_enabled)return NO;if(_samples.count==16)[_samples removeObjectAtIndex:0];[_samples addObject:sample];}
    return YES;
}
- (NSDictionary *)snapshotPreparedEntry:(NSDictionary *)entry phase:(CanopyDiagnosticsPhase)phase errorCode:(CanopyDiagnosticsError)error metrics:(NSDictionary *)metrics {
    NSArray *history;BOOL enabled;
    @synchronized(self){history=[_samples copy];enabled=_enabled;}
    return @{@"schemaVersion":@1,@"origin":@"userRequested",@"collectionEnabled":@(enabled),
        @"sample":CDSample(entry,phase,error,metrics),@"recordedSamples":history};
}
- (NSData *)redactedJSONPreparedEntry:(NSDictionary *)entry phase:(CanopyDiagnosticsPhase)phase errorCode:(CanopyDiagnosticsError)error
    metrics:(NSDictionary *)metrics error:(NSError **)failure {
    NSDictionary *snapshot=[self snapshotPreparedEntry:entry phase:phase errorCode:error metrics:metrics];
    NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingSortedKeys error:NULL];
    if(!data || data.length>65536) {
        if(failure)*failure=[NSError errorWithDomain:@"CanopyDiagnostics" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The redacted diagnostic snapshot could not be exported within its size limit."}];
        return nil;
    }
    return data;
}
@end
