#import "LBXHelperSwap.h"
#import "LBXHelperPaths.h"
#import "LBXHelperProtocol.h"
#include <stdio.h>
#include <unistd.h>
#include <errno.h>

static NSError *LBXSwapError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:LBXHelperErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

static BOOL LBXRename(NSString *from, NSString *to, NSError **error) {
    if (rename(from.fileSystemRepresentation, to.fileSystemRepresentation) != 0) {
        if (error)
            *error = LBXSwapError(LBXHelperErrorOperationFailed,
                                  [NSString stringWithFormat:@"rename failed errno=%d", errno]);
        return NO;
    }
    return YES;
}

static BOOL LBXSwapPair(NSString *a, NSString *b, BOOL contents, NSError **error) {
    NSString *left = LBXHelperStandardizeAllowedPath(a);
    NSString *right = LBXHelperStandardizeAllowedPath(b);
    if (!left || !right) {
        if (error) *error = LBXSwapError(LBXHelperErrorPathDenied, @"swap path outside control trees");
        return NO;
    }
    if ([left isEqual:right]) {
        if (error) *error = LBXSwapError(LBXHelperErrorInvalidArgument, @"identical swap paths");
        return NO;
    }

    if (contents) {
        // Directory contents swap via three-rename through a sibling temp name.
        NSString *tmp = [[left stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:[NSString stringWithFormat:@".sbx-swap-%@",
                                                                         NSUUID.UUID.UUIDString]];
        if (!LBXHelperPathUnderControlTree(tmp)) {
            if (error) *error = LBXSwapError(LBXHelperErrorPathDenied, @"temp path denied");
            return NO;
        }
        if (!LBXRename(left, tmp, error)) return NO;
        if (!LBXRename(right, left, error)) {
            rename(tmp.fileSystemRepresentation, left.fileSystemRepresentation);
            return NO;
        }
        if (!LBXRename(tmp, right, error)) {
            // Best-effort unwind; caller sees failure.
            rename(left.fileSystemRepresentation, right.fileSystemRepresentation);
            rename(tmp.fileSystemRepresentation, left.fileSystemRepresentation);
            return NO;
        }
        return YES;
    }

    // Path-pair swap: move A→tmp, B→A, tmp→B when both exist; otherwise plain move.
    BOOL leftExists = access(left.fileSystemRepresentation, F_OK) == 0;
    BOOL rightExists = access(right.fileSystemRepresentation, F_OK) == 0;
    if (leftExists && rightExists) {
        NSString *tmp = [[left stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:[NSString stringWithFormat:@".sbx-pair-%@",
                                                                         NSUUID.UUID.UUIDString]];
        if (!LBXHelperPathUnderControlTree(tmp)) {
            if (error) *error = LBXSwapError(LBXHelperErrorPathDenied, @"temp path denied");
            return NO;
        }
        if (!LBXRename(left, tmp, error)) return NO;
        if (!LBXRename(right, left, error)) {
            rename(tmp.fileSystemRepresentation, left.fileSystemRepresentation);
            return NO;
        }
        if (!LBXRename(tmp, right, error)) {
            rename(left.fileSystemRepresentation, right.fileSystemRepresentation);
            rename(tmp.fileSystemRepresentation, left.fileSystemRepresentation);
            return NO;
        }
        return YES;
    }
    if (leftExists && !rightExists) return LBXRename(left, right, error);
    if (!leftExists && rightExists) return LBXRename(right, left, error);
    if (error) *error = LBXSwapError(LBXHelperErrorInvalidArgument, @"neither swap path exists");
    return NO;
}

BOOL LBXHelperAtomicBatchSwap(NSArray *operations, BOOL contents, NSError **error) {
    if (![operations isKindOfClass:NSArray.class] || operations.count == 0 || operations.count > 256) {
        if (error) *error = LBXSwapError(LBXHelperErrorInvalidArgument, @"invalid swap batch");
        return NO;
    }
    for (id row in operations) {
        if (![row isKindOfClass:NSDictionary.class]) {
            if (error) *error = LBXSwapError(LBXHelperErrorInvalidArgument, @"invalid swap row");
            return NO;
        }
        NSDictionary *op = row;
        NSString *from = op[@"from"] ?: op[@"source"] ?: op[@"a"];
        NSString *to = op[@"to"] ?: op[@"dest"] ?: op[@"b"];
        if (![from isKindOfClass:NSString.class] || ![to isKindOfClass:NSString.class]) {
            if (error) *error = LBXSwapError(LBXHelperErrorInvalidArgument, @"swap row missing paths");
            return NO;
        }
        if (!LBXSwapPair(from, to, contents, error)) return NO;
    }
    return YES;
}
