#import "SaveSync.h"
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <stdio.h>

static NSError *syncError(NSString *message) {
    return [NSError errorWithDomain:@"FactorioSaveSync" code:1
                          userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSDictionary *fileStamp(NSURL *url) {
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) return nil;
    return [attributes dictionaryWithValuesForKeys:@[NSFileSize,NSFileModificationDate,NSFileSystemFileNumber]];
}

// Check the end-of-central-directory marker so a save still being written is skipped.
static BOOL completeZip(NSData *head, NSData *tail) {
    if (head.length<4 || memcmp(head.bytes,"PK\003\004",4) || tail.length<22) return NO;
    const unsigned char *bytes=tail.bytes;
    for (NSInteger offset=(NSInteger)tail.length-22;offset>=0;offset--) {
        if (!memcmp(bytes+offset,"PK\005\006",4)) {
            NSUInteger comment=bytes[offset+20]|(bytes[offset+21]<<8);
            if ((NSUInteger)offset+22+comment==tail.length) return YES;
        }
    }
    return NO;
}

@interface FPSaveSyncEngine ()
@property(nonatomic,strong) NSMutableDictionary *hashCache;
@end

@implementation FPSaveSyncEngine
- (instancetype)init {
    if ((self=[super init])) self.hashCache=[NSMutableDictionary new];
    return self;
}
- (NSString *)digest:(NSURL *)url stable:(BOOL)stable error:(NSError **)error {
    NSDictionary *before=fileStamp(url);
    if (!before) return nil;
    if (stable && [before[NSFileModificationDate] timeIntervalSinceNow]>-2) return nil;
    NSDictionary *cached=self.hashCache[url.path];
    if ([cached[@"stamp"] isEqual:before]) return cached[@"digest"];
    NSInputStream *stream=[NSInputStream inputStreamWithURL:url];
    [stream open];
    // CommonCrypto's streaming API avoids loading a large factory save into RAM.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[65536];
    NSMutableData *head=[NSMutableData new], *tail=[NSMutableData new];
    NSInteger length;
    while ((length=[stream read:buffer maxLength:sizeof(buffer)])>0) {
        CC_SHA256_Update(&context,buffer,(CC_LONG)length);
        if (head.length<4) [head appendBytes:buffer length:MIN((NSUInteger)length,4-head.length)];
        [tail appendBytes:buffer length:(NSUInteger)length];
        if (tail.length>65557) [tail replaceBytesInRange:NSMakeRange(0,tail.length-65557) withBytes:NULL length:0];
    }
    NSError *readError=stream.streamError;
    [stream close];
    if (length<0) { if (error) *error=readError ?: syncError(@"Could not read a save."); return nil; }
    if (![before isEqual:fileStamp(url)] || !completeZip(head,tail)) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(hash,&context);
#pragma clang diagnostic pop
    NSMutableString *digest=[NSMutableString new];
    for (NSUInteger i=0;i<sizeof(hash);i++) [digest appendFormat:@"%02x",hash[i]];
    self.hashCache[url.path]=@{@"stamp":before,@"digest":digest};
    return digest;
}
- (NSDictionary<NSString *,NSString *> *)inventory:(NSURL *)folder error:(NSError **)error {
    __block NSArray<NSURL *> *files=nil;
    __block NSError *operationError=nil;
    NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:folder options:0 error:error byAccessor:^(NSURL *url) {
        files=[NSFileManager.defaultManager contentsOfDirectoryAtURL:url includingPropertiesForKeys:nil
                                                           options:NSDirectoryEnumerationSkipsHiddenFiles error:&operationError];
    }];
    if (operationError && error) *error=operationError;
    if (!files) return nil;
    NSMutableDictionary *inventory=[NSMutableDictionary new];
    for (NSURL *file in files) {
        if (![file.pathExtension.lowercaseString isEqual:@"zip"]) continue;
        __block NSString *digest=nil;
        operationError=nil;
        [coordinator coordinateReadingItemAtURL:file options:0 error:error byAccessor:^(NSURL *url) {
            digest=[self digest:url stable:YES error:&operationError];
        }];
        if (operationError && error) *error=operationError;
        if (error && *error) return nil;
        if (digest) inventory[file.lastPathComponent]=digest;
    }
    return inventory;
}
- (BOOL)copyName:(NSString *)name digest:(NSString *)digest source:(NSURL *)source
    destination:(NSURL *)destination error:(NSError **)error {
    NSURL *sourceFile=[source URLByAppendingPathComponent:name];
    __block NSError *operationError=nil;
    __block BOOL copied=NO;
    NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
    // Coordinate the destination directory to include the temporary file and final rename.
    [coordinator coordinateReadingItemAtURL:sourceFile options:0 writingItemAtURL:destination
                                   options:NSFileCoordinatorWritingForMerging error:error
                                byAccessor:^(NSURL *from, NSURL *to) {
        NSFileManager *manager=NSFileManager.defaultManager;
        NSDictionary *before=fileStamp(from);
        if (!before) return;
        NSURL *staged=[to URLByAppendingPathComponent:[@".factorio-sync-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        if (![manager copyItemAtURL:from toURL:staged error:&operationError]) return;
        @try {
            NSString *copiedDigest=[self digest:staged stable:NO error:&operationError];
            [self.hashCache removeObjectForKey:staged.path];
            if (![before isEqual:fileStamp(from)] || ![digest isEqual:copiedDigest]) return;
            NSURL *target=[to URLByAppendingPathComponent:name];
            if ([manager fileExistsAtPath:target.path]) {
                NSString *base=name.stringByDeletingPathExtension;
                while ([base lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>150) base=[base substringToIndex:base.length-1];
                NSString *suffix=[NSString stringWithFormat:@"%@-sync-%@",base,digest];
                target=[to URLByAppendingPathComponent:[suffix stringByAppendingPathExtension:@"zip"]];
                NSUInteger index=1;
                while ([manager fileExistsAtPath:target.path]) {
                    NSString *existing=[self digest:target stable:NO error:&operationError];
                    if (operationError || [existing isEqual:digest]) return;
                    target=[to URLByAppendingPathComponent:[[suffix stringByAppendingFormat:@"-%lu",(unsigned long)index++] stringByAppendingPathExtension:@"zip"]];
                }
            }
            // Refuse replacement atomically, even if the game creates a save at this instant.
            copied=renamex_np(staged.fileSystemRepresentation,target.fileSystemRepresentation,RENAME_EXCL)==0;
            if (!copied) operationError=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                userInfo:@{NSLocalizedDescriptionKey:@"Could not publish the save without replacing a file. Sync will retry."}];
        } @finally {
            [manager removeItemAtURL:staged error:NULL];
        }
    }];
    if (operationError && error) *error=operationError;
    return copied;
}
- (NSUInteger)syncLocal:(NSURL *)local remote:(NSURL *)remote error:(NSError **)error {
    if (error) *error=nil;
    if ([local.URLByResolvingSymlinksInPath isEqual:remote.URLByResolvingSymlinksInPath]) {
        if (error) *error=syncError(@"Choose a separate folder in iCloud Drive.");
        return 0;
    }
    NSError *failure=nil;
    NSDictionary *localFiles=[self inventory:local error:&failure];
    NSDictionary *remoteFiles=failure ? nil : [self inventory:remote error:&failure];
    if (!localFiles || !remoteFiles) { if (error) *error=failure; return 0; }
    NSMutableSet *localHashes=[NSMutableSet setWithArray:localFiles.allValues];
    NSMutableSet *remoteHashes=[NSMutableSet setWithArray:remoteFiles.allValues];
    NSUInteger count=0;
    for (NSString *name in [localFiles.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *digest=localFiles[name];
        if (![remoteHashes containsObject:digest] && [self copyName:name digest:digest source:local destination:remote error:&failure]) {
            [remoteHashes addObject:digest]; count++;
        }
        if (failure) break;
    }
    if (!failure) for (NSString *name in [remoteFiles.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *digest=remoteFiles[name];
        if (![localHashes containsObject:digest] && [self copyName:name digest:digest source:remote destination:local error:&failure]) {
            [localHashes addObject:digest]; count++;
        }
        if (failure) break;
    }
    if (error) *error=failure;
    return count;
}
@end
