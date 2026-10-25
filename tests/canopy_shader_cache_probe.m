#import <Foundation/Foundation.h>
#import "CanopyShaderCache.h"
int main(int argc,const char **argv) {@autoreleasepool {
    if(argc!=8)return 2;
    NSString *(^arg)(int)=^NSString *(int i){return [NSString stringWithUTF8String:argv[i]];};
    CanopyShaderCache *cache=[[CanopyShaderCache alloc] initWithRootURL:[NSURL fileURLWithPath:arg(2)]];
    NSString *mode=arg(5),*title=arg(6);NSError *error=nil;NSMutableDictionary *report=[NSMutableDictionary new];
    if([mode isEqual:@"list"]) {
        NSArray *identities=[cache identitiesForTitleID:title error:&error];if(identities)report[@"value"]=identities;
    } else if([mode hasPrefix:@"usage:"] || [mode hasPrefix:@"clear:"] || [mode hasPrefix:@"remove:"]) {
        NSString *hash=[mode componentsSeparatedByString:@":"][1];id value=nil;
        if([mode hasPrefix:@"usage:"])value=[cache usageForIdentityHash:hash titleID:title error:&error];
        else if([mode hasPrefix:@"clear:"])value=[cache clearRuntimeForIdentityHash:hash titleID:title error:&error] ? @YES:nil;
        else value=[cache removeIdentityHash:hash titleID:title error:&error] ? @YES:nil;
        if(value)report[@"value"]=value;
    } else {
        // Component-test identity only; production obtains this from the selected MTLDevice.
        NSDictionary *device=@{@"schema":@1,@"platform":@"macos",@"os":@"original fixture OS",@"device":arg(7),
            @"registry":@"0000000000000001",@"families":@[@1001],@"mathMode":@"safe",@"mslVersion":@"20300"};
        __block BOOL cancelled=[mode isEqual:@"cancel-early"];
        CanopyShaderCacheLease *lease=[cache prepareSeedURL:[NSURL fileURLWithPath:arg(1)] titleID:title
            sourceRomFSSHA256:arg(4) expectedManifestSHA256:arg(3) expectedChain:@"totk-native-v7-unverified"
            deviceIdentity:device cancelled:^BOOL{return cancelled;}
            progress:^(NSString *phase,uint64_t done,uint64_t total){(void)phase;
                if([mode isEqual:@"cancel-copy"] || ([mode isEqual:@"cancel-final"] && done==total))cancelled=YES;}
            error:&error];
        if(lease) {
            report[@"identity"]=lease.identityHash;report[@"metrics"]=lease.metrics;
            if([mode isEqual:@"active"]) {
                NSError *busy=nil;
                BOOL clear=[cache clearRuntimeForIdentityHash:lease.identityHash titleID:title error:&busy];
                report[@"clearRefused"]=@(!clear && busy.code==3);busy=nil;
                BOOL remove=[cache removeIdentityHash:lease.identityHash titleID:title error:&busy];
                report[@"removeRefused"]=@(!remove && busy.code==3);
                // Keep the shared lease alive through both destructive attempts.
                report[@"retainedIdentity"]=lease.identityHash;
            }
        }
    }
    report[@"ok"]=@(!error);
    if(error){report[@"errorCode"]=@(error.code);report[@"error"]=error.localizedDescription;}
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return 0;
}}
