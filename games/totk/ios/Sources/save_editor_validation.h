#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>

static const NSUInteger ProgressSize = 2307856;
static NSString *const EditorURL = @"https://www.marcrobledo.com/savegame-editors/zelda-totk/";

static inline BOOL validProgress(NSData *data) {
    if (data.length != ProgressSize) return NO;
    const uint8_t *bytes = data.bytes;
    uint32_t header = (uint32_t)bytes[4] | (uint32_t)bytes[5] << 8 | (uint32_t)bytes[6] << 16 | (uint32_t)bytes[7] << 24;
    return header == 0x0049e946;
}

static inline BOOL hasSavedCaption(NSData *data) {
    if (data.length < 0x1c0) return NO;
    const uint8_t *bytes = data.bytes;
    uint32_t year = 0, month = 0, day = 0;
    unsigned seen = 0;
    // Caption metadata uses aligned little-endian hash/value records before 0x1c0.
    // Format: marcrobledo/savegame-editors, commit 450752f98876755944ea22eb457f4dc1468d79ea.
    for (NSUInteger offset = 0x28; offset < 0x1c0; offset += 8) {
        uint32_t hash = (uint32_t)bytes[offset] | (uint32_t)bytes[offset+1] << 8 |
            (uint32_t)bytes[offset+2] << 16 | (uint32_t)bytes[offset+3] << 24;
        unsigned field = hash == 0x9811a3f7 ? 1 : hash == 0xdfd840d3 ? 2 : hash == 0xbd46f485 ? 4 : 0;
        if (!field) continue;
        if (seen & field) return NO;
        seen |= field;
        uint32_t value = (uint32_t)bytes[offset+4] | (uint32_t)bytes[offset+5] << 8 |
            (uint32_t)bytes[offset+6] << 16 | (uint32_t)bytes[offset+7] << 24;
        if (field == 1) year = value;
        else if (field == 2) month = value;
        else day = value;
    }
    return seen == 7 && year >= 1 && year <= 9999 && month >= 1 && month <= 12 && day >= 1 && day <= 31;
}

static inline BOOL editorLocation(NSURL *url) {
    if (!url) return NO;
    NSURLComponents *location = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    return [location.scheme.lowercaseString isEqual:@"https"] &&
        [location.host.lowercaseString isEqual:@"www.marcrobledo.com"] &&
        (!location.port || location.port.integerValue == 443) && !location.user && !location.password &&
        [location.percentEncodedPath isEqual:@"/savegame-editors/zelda-totk/"] && !location.query;
}
