#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

// Moves srcPath to the macOS Trash via NSFileManager.
// On success, returns 0 and sets *outTrashedPath (caller must free).
// On failure, returns non-zero and sets *outErrMsg (caller must free).
int xnk_trash_item(const char *srcPath, char **outTrashedPath, char **outErrMsg) {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:srcPath];
        NSURL *srcURL = [NSURL fileURLWithPath:path];
        NSURL *resultingURL = nil;
        NSError *err = nil;

        BOOL ok = [[NSFileManager defaultManager] trashItemAtURL:srcURL
                                                resultingItemURL:&resultingURL
                                                           error:&err];
        if (!ok) {
            NSString *msg = err ? [err localizedDescription] : @"Failed to move item to Trash";
            if (outErrMsg) {
                *outErrMsg = strdup([msg UTF8String]);
            }
            return 1;
        }

        if (outTrashedPath && resultingURL != nil) {
            *outTrashedPath = strdup([[resultingURL path] UTF8String]);
        }
        return 0;
    }
}

// Restores an item from trashedPath back to originalPath via NSFileManager.
// Returns 0 on success, non-zero on failure (sets *outErrMsg, caller must free).
int xnk_untrash_item(const char *trashedPath, const char *originalPath, char **outErrMsg) {
    @autoreleasepool {
        NSURL *srcURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:trashedPath]];
        NSURL *dstURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:originalPath]];
        NSError *err = nil;

        BOOL ok = [[NSFileManager defaultManager] moveItemAtURL:srcURL
                                                          toURL:dstURL
                                                          error:&err];
        if (!ok) {
            NSString *msg = err ? [err localizedDescription] : @"Failed to restore item from Trash";
            if (outErrMsg) {
                *outErrMsg = strdup([msg UTF8String]);
            }
            return 1;
        }
        return 0;
    }
}
