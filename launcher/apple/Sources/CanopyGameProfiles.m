#import "CanopyGameProfiles.h"
#import "../../../games/totk/ios/Sources/save_validation.h"
#include "mng_game_profile.h"

static const struct mng_game_profile *CGProfile(NSString *titleID) {
    if (![titleID isKindOfClass:NSString.class] || titleID.length != 16) return NULL;
    uint64_t title = 0;
    for (NSUInteger i = 0; i < 16; i++) {
        unichar c = [titleID characterAtIndex:i];
        unsigned digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
        else return NULL;
        title = (title << 4) | digit;
    }
    return mng_game_profile_for_title(title);
}

NSString *CanopyGameNameForTitleID(NSString *titleID) {
    const struct mng_game_profile *profile = CGProfile(titleID);
    return profile ? [NSString stringWithUTF8String:profile->display_name] : nil;
}

NSString *CanopyGameVersionLabel(NSString *titleID, uint32_t revision, BOOL identified) {
    if (!identified) return @"Version unidentified";
    const struct mng_game_version *version = mng_game_version_for_revision(CGProfile(titleID), revision);
    if (version) return [NSString stringWithFormat:@"Version %s (revision %u)", version->display_version, revision];
    return [NSString stringWithFormat:@"Revision %u (display version unknown)", revision];
}

CanopySaveValidator CanopyGameSaveValidatorForTitleID(NSString *titleID) {
    const struct mng_game_profile *profile = CGProfile(titleID);
    if (!profile) return nil;
    switch (profile->save_validator) {
        case MNG_GAME_SAVE_TOTK_STRUCTURAL:
            return ^BOOL(NSURL *directory, NSError **error) {
                return TOTKSaveValidateDirectory(directory, error);
            };
        default:
            return nil;
    }
}
