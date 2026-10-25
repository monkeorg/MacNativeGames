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

static inline BOOL editorLocation(NSURL *url) {
    if (!url) return NO;
    NSURLComponents *location = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    return [location.scheme.lowercaseString isEqual:@"https"] &&
        [location.host.lowercaseString isEqual:@"www.marcrobledo.com"] &&
        (!location.port || location.port.integerValue == 443) && !location.user && !location.password &&
        [location.percentEncodedPath isEqual:@"/savegame-editors/zelda-totk/"] && !location.query;
}
