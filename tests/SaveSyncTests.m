#import "../probe/SaveSync.h"

@interface FPSaveSyncEngine (TestAccess)
- (BOOL)copyName:(NSString *)name digest:(NSString *)digest source:(NSURL *)source
    destination:(NSURL *)destination error:(NSError **)error;
@end

// Mutate the source between inventory and copy to model an uncoordinated game save.
@interface FPRacingSaveSync : FPSaveSyncEngine
@end
@implementation FPRacingSaveSync
- (BOOL)copyName:(NSString *)name digest:(NSString *)digest source:(NSURL *)source
    destination:(NSURL *)destination error:(NSError **)error {
    NSURL *replacement=[source URLByAppendingPathComponent:@"replacement.bin"];
    if ([name isEqual:@"race.zip"]) {
        NSData *data=[NSData dataWithContentsOfURL:replacement];
        [data writeToURL:[source URLByAppendingPathComponent:name] atomically:YES];
    }
    return [super copyName:name digest:digest source:source destination:destination error:error];
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc<3) return 2;
        NSURL *local=[NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        NSURL *remote=[NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
        BOOL race=argc>3 && !strcmp(argv[3],"race");
        FPSaveSyncEngine *engine=race ? [FPRacingSaveSync new] : [FPSaveSyncEngine new];
        NSError *error=nil;
        NSUInteger first=[engine syncLocal:local remote:remote error:&error];
        NSString *failure=error.localizedDescription ?: @"";
        if (argc>3 && !strcmp(argv[3],"rewrite")) {
            NSURL *target=[local URLByAppendingPathComponent:@"factory.zip"];
            [NSFileManager.defaultManager removeItemAtURL:target error:NULL];
            [NSFileManager.defaultManager copyItemAtURL:[local URLByAppendingPathComponent:@"replacement.bin"] toURL:target error:NULL];
        }
        NSUInteger second=[engine syncLocal:local remote:remote error:&error];
        NSDictionary *result=@{@"copied":@(first),@"secondCopied":@(second),@"error":failure};
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        [NSFileHandle.fileHandleWithStandardOutput writeData:json];
    }
    return 0;
}
