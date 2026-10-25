#import "save_editor_validation.h"
#include <assert.h>
#include <stdio.h>

static void refuse(NSString *value) { assert(!editorLocation([NSURL URLWithString:value])); }
int main(int argc,const char **argv) {
    @autoreleasepool {
        assert(argc==2);
        NSString *test = @(argv[1]);
        if ([test isEqual:@"canonical"]) {
            NSURL *url = [NSURL URLWithString:EditorURL];
            assert(editorLocation(url));
            assert([[[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO] percentEncodedPath]
                isEqual:@"/savegame-editors/zelda-totk/"]);
            assert(editorLocation([NSURL URLWithString:@"https://www.marcrobledo.com:443/savegame-editors/zelda-totk/"]));
        } else if ([test isEqual:@"origin"]) {
            refuse(@"http://www.marcrobledo.com/savegame-editors/zelda-totk/");
            refuse(@"https://marcrobledo.com/savegame-editors/zelda-totk/");
            refuse(@"https://www.marcrobledo.com.evil.test/savegame-editors/zelda-totk/");
            refuse(@"https://www.marcrobledo.com:444/savegame-editors/zelda-totk/");
            refuse(@"https://www.marcrobledo.com:80/savegame-editors/zelda-totk/");
            refuse(@"/savegame-editors/zelda-totk/");
            assert(!editorLocation(nil));
        } else if ([test isEqual:@"credentials"]) {
            refuse(@"https://user@www.marcrobledo.com/savegame-editors/zelda-totk/");
            refuse(@"https://user:password@www.marcrobledo.com/savegame-editors/zelda-totk/");
            refuse(@"https://@www.marcrobledo.com/savegame-editors/zelda-totk/");
        } else if ([test isEqual:@"path"]) {
            refuse(@"https://www.marcrobledo.com/savegame-editors/zelda-totk");
            refuse(@"https://www.marcrobledo.com/savegame-editors/zelda-totk/extra/");
            refuse(@"https://www.marcrobledo.com/savegame-editors/zelda-totk//");
            refuse(@"https://www.marcrobledo.com/savegame-editors/%7aelda-totk/");
            refuse(@"https://www.marcrobledo.com/savegame-editors/other/../zelda-totk/");
            refuse(@"https://www.marcrobledo.com/savegame-editors%2Fzelda-totk/");
        } else if ([test isEqual:@"query_fragment"]) {
            for (NSString *suffix in @[@"?",@"?x=1",@"?x=1#editor"]) refuse([EditorURL stringByAppendingString:suffix]);
            for (NSString *suffix in @[@"#",@"#editor"]) assert(editorLocation([NSURL URLWithString:[EditorURL stringByAppendingString:suffix]]));
        } else if ([test isEqual:@"progress"]) {
            NSMutableData *data = [NSMutableData dataWithLength:ProgressSize];
            uint8_t *bytes = data.mutableBytes;
            bytes[0]=0xde; bytes[1]=0xad; bytes[2]=0xbe; bytes[3]=0xef;
            bytes[4]=0x46; bytes[5]=0xe9; bytes[6]=0x49; bytes[7]=0;
            assert(validProgress(data));
            bytes[7]=1; assert(!validProgress(data)); bytes[7]=0;
            bytes[4]=0; bytes[5]=0; bytes[6]=0;
            bytes[0]=0x46; bytes[1]=0xe9; bytes[2]=0x49; bytes[3]=0;
            assert(!validProgress(data));
            assert(!validProgress(nil));
            assert(!validProgress([NSMutableData dataWithLength:ProgressSize-1]));
            assert(!validProgress([NSMutableData dataWithLength:ProgressSize+1]));
        } else assert(!"unknown test");
        puts("PASS");
    }
    return 0;
}
