#import "SaveSync.h"
#include <errno.h>
#include <stdio.h>

NSString *const FPLatestCloudSaveName = @"Factorio iPad Latest.zip";

static NSError *saveError(NSString *message) {
    return [NSError errorWithDomain:@"FactorioSaveSync" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSDictionary *fileStamp(NSURL *url) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) return nil;
    return [attributes dictionaryWithValuesForKeys:@[NSFileSize, NSFileModificationDate, NSFileSystemFileNumber]];
}

static BOOL isZipName(NSURL *url) {
    return [url.pathExtension.lowercaseString isEqualToString:@"zip"];
}

// A save still being written normally has no end-of-central-directory record.
static BOOL completeZip(NSURL *url, NSDictionary *stamp, NSError **error) {
    unsigned long long size = [stamp[NSFileSize] unsignedLongLongValue];
    if (size < 26) return NO;
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:error];
    if (!file) return NO;
    @try {
        NSData *head = [file readDataUpToLength:4 error:error];
        if (head.length != 4 || memcmp(head.bytes, "PK\003\004", 4)) return NO;
        NSUInteger tailLength = (NSUInteger)MIN(size, 65557);
        if (![file seekToOffset:size - tailLength error:error]) return NO;
        NSData *tail = [file readDataUpToLength:tailLength error:error];
        const uint8_t *bytes = tail.bytes;
        for (NSInteger offset = (NSInteger)tail.length - 22; offset >= 0; offset--) {
            if (memcmp(bytes + offset, "PK\005\006", 4)) continue;
            NSUInteger commentLength = bytes[offset + 20] | (bytes[offset + 21] << 8);
            if ((NSUInteger)offset + 22 + commentLength == tail.length) return YES;
        }
        return NO;
    } @finally {
        [file closeAndReturnError:NULL];
    }
}

static NSURL *stagedCopy(NSURL *source, NSURL *folder, NSDictionary *stamp, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *temporaryName = [@".factorio-save-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSURL *temporary = [folder URLByAppendingPathComponent:temporaryName];
    if ([manager copyItemAtURL:source toURL:temporary error:error]) {
        NSDictionary *copied = fileStamp(temporary);
        if ([stamp isEqual:fileStamp(source)] && [stamp[NSFileSize] isEqual:copied[NSFileSize]]
            && completeZip(temporary, copied, error)) {
            // Keep the source's timestamp when bringing an older save back into the game.
            if ([manager setAttributes:@{NSFileModificationDate: stamp[NSFileModificationDate]}
                          ofItemAtPath:temporary.path error:error]) return temporary;
        } else if (!*error) {
            *error = saveError(@"The save is incomplete or changed during copying. Try again.");
        }
    }
    [manager removeItemAtURL:temporary error:NULL];
    return nil;
}

BOOL FPBackUpLatestSave(NSURL *localFolder, NSURL *cloudFolder, NSError **error) {
    if (error) *error = nil;
    NSError *scanError = nil;
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:localFolder
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:&scanError];
    if (!files) {
        if (error) *error = scanError;
        return NO;
    }

    NSURL *latest = nil;
    NSDictionary *latestStamp = nil;
    for (NSURL *file in files) {
        if (!isZipName(file)) continue;
        NSDictionary *stamp = fileStamp(file);
        NSDate *modified = stamp[NSFileModificationDate];
        if (!modified || [modified timeIntervalSinceNow] > -2) continue;
        if (latestStamp) {
            NSComparisonResult age = [modified compare:latestStamp[NSFileModificationDate]];
            if (age == NSOrderedAscending || (age == NSOrderedSame &&
                [file.lastPathComponent compare:latest.lastPathComponent] != NSOrderedAscending)) continue;
        }
        if (completeZip(file, stamp, NULL) && [stamp isEqual:fileStamp(file)]) {
            latest = file;
            latestStamp = stamp;
        }
    }
    if (!latest) return NO;

    NSURL *destination = [cloudFolder URLByAppendingPathComponent:FPLatestCloudSaveName];
    if ([latest.URLByResolvingSymlinksInPath isEqual:destination.URLByResolvingSymlinksInPath]) {
        if (error) *error = saveError(@"Choose a separate folder in iCloud Drive.");
        return NO;
    }
    __block NSError *operationError = nil;
    NSError *coordinationError = nil;
    __block BOOL copied = NO;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateWritingItemAtURL:destination options:NSFileCoordinatorWritingForReplacing
                                     error:&coordinationError byAccessor:^(NSURL *target) {
        // Avoid replacing a backup from a later session or a newer device.
        NSDictionary *existing = fileStamp(target);
        NSDate *modified = latestStamp[NSFileModificationDate];
        if (existing && [modified compare:existing[NSFileModificationDate]] != NSOrderedDescending) return;
        NSURL *temporary = stagedCopy(latest, target.URLByDeletingLastPathComponent, latestStamp, &operationError);
        if (!temporary) return;
        copied = rename(temporary.fileSystemRepresentation, target.fileSystemRepresentation) == 0;
        if (!copied) {
            operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL];
        }
    }];
    if (error) *error = operationError ?: coordinationError;
    return copied;
}

NSURL *FPImportSave(NSURL *source, NSURL *localFolder, NSError **error) {
    if (error) *error = nil;
    if (!isZipName(source)) {
        if (error) *error = saveError(@"Choose a Factorio save ZIP.");
        return nil;
    }

    __block NSURL *imported = nil;
    __block NSError *operationError = nil;
    NSError *coordinationError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:source options:0 error:&coordinationError byAccessor:^(NSURL *file) {
        NSDictionary *stamp = fileStamp(file);
        if (!completeZip(file, stamp, &operationError)) {
            if (!operationError) operationError = saveError(@"This file is not a complete save ZIP.");
            return;
        }
        NSURL *temporary = stagedCopy(file, localFolder, stamp, &operationError);
        if (!temporary) return;

        NSString *base = source.lastPathComponent.stringByDeletingPathExtension;
        while ([base lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 200) {
            NSRange lastCharacter = [base rangeOfComposedCharacterSequenceAtIndex:base.length - 1];
            base = [base substringToIndex:lastCharacter.location];
        }
        if (!base.length || [base hasPrefix:@"."]) base = @"Imported save";
        for (NSUInteger index = 1; ; index++) {
            NSString *name = index == 1 ? base : [base stringByAppendingFormat:@" (%lu)", (unsigned long)index];
            NSURL *target = [localFolder URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"zip"]];
            if (renamex_np(temporary.fileSystemRepresentation, target.fileSystemRepresentation, RENAME_EXCL) == 0) {
                imported = target;
                return;
            }
            int failure = errno;
            if (failure != EEXIST) {
                operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
                [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL];
                return;
            }
        }
    }];
    if (error) *error = operationError ?: coordinationError;
    return imported;
}
