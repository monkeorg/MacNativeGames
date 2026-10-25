#import "save_editor_validation.h"
#include <assert.h>
#include <stdio.h>

static void refuse(NSString *value) { assert(!editorLocation([NSURL URLWithString:value])); }

static void captionRecord(NSMutableData *data, NSUInteger offset, uint32_t hash, uint32_t value) {
    assert(offset + 8 <= data.length);
    uint8_t *bytes = data.mutableBytes;
    for (unsigned i = 0; i < 4; i++) {
        bytes[offset+i] = (uint8_t)(hash >> (i*8));
        bytes[offset+4+i] = (uint8_t)(value >> (i*8));
    }
}

static NSMutableData *savedCaption(void) {
    NSMutableData *data = [NSMutableData dataWithLength:0x1c0];
    captionRecord(data, 0x28, 0x9811a3f7, 2026);
    captionRecord(data, 0x30, 0xdfd840d3, 10);
    captionRecord(data, 0x38, 0xbd46f485, 25);
    return data;
}

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
        } else if ([test isEqual:@"caption_valid"]) {
            NSMutableData *data = savedCaption();
            assert(hasSavedCaption(data));
            captionRecord(data, 0x28, 0x9811a3f7, 1);
            captionRecord(data, 0x30, 0xdfd840d3, 1);
            captionRecord(data, 0x38, 0xbd46f485, 1);
            assert(hasSavedCaption(data));
            captionRecord(data, 0x28, 0xbd46f485, 31);
            captionRecord(data, 0x30, 0x9811a3f7, 9999);
            captionRecord(data, 0x38, 0, 0);
            captionRecord(data, 0x1b8, 0xdfd840d3, 12);
            assert(hasSavedCaption(data));
            [data increaseLengthBy:128];
            assert(hasSavedCaption(data));
        } else if ([test isEqual:@"caption_empty_missing"]) {
            assert(!hasSavedCaption([NSMutableData dataWithLength:0x1c0]));
            for (NSUInteger offset = 0x28; offset <= 0x38; offset += 8) {
                NSMutableData *data = savedCaption();
                captionRecord(data, offset, 0, 0);
                assert(!hasSavedCaption(data));
            }
        } else if ([test isEqual:@"caption_truncated"]) {
            assert(!hasSavedCaption(nil));
            NSData *data = savedCaption();
            for (NSUInteger length = 0; length < 0x1c0; length++)
                assert(!hasSavedCaption([data subdataWithRange:NSMakeRange(0, length)]));
        } else if ([test isEqual:@"caption_invalid"]) {
            const uint32_t hashes[] = {0x9811a3f7, 0xdfd840d3, 0xbd46f485};
            const uint32_t maximums[] = {9999, 12, 31};
            for (unsigned field = 0; field < 3; field++) {
                const uint32_t values[] = {0, maximums[field]+1, UINT32_MAX};
                for (unsigned i = 0; i < 3; i++) {
                    NSMutableData *data = savedCaption();
                    captionRecord(data, 0x28+field*8, hashes[field], values[i]);
                    assert(!hasSavedCaption(data));
                }
            }
        } else if ([test isEqual:@"caption_duplicates"]) {
            const uint32_t hashes[] = {0x9811a3f7, 0xdfd840d3, 0xbd46f485};
            const uint32_t values[] = {2026, 10, 25};
            for (unsigned field = 0; field < 3; field++) {
                NSMutableData *data = savedCaption();
                captionRecord(data, 0x1b8, hashes[field], values[field]);
                assert(!hasSavedCaption(data));
                captionRecord(data, 0x1b8, hashes[field], 0);
                assert(!hasSavedCaption(data));
            }
        } else if ([test isEqual:@"caption_bounds"]) {
            const NSUInteger offsets[] = {0x20, 0x29, 0x1c0};
            for (unsigned i = 0; i < 3; i++) {
                NSMutableData *data = savedCaption();
                [data increaseLengthBy:8];
                captionRecord(data, 0x28, 0, 0);
                captionRecord(data, offsets[i], 0x9811a3f7, 2026);
                assert(!hasSavedCaption(data));
            }
        } else assert(!"unknown test");
        puts("PASS");
    }
    return 0;
}
