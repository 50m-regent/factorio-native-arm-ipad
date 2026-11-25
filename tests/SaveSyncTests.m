#import "../probe/SaveSync.h"

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4) return 2;
        NSString *mode = @(argv[1]);
        NSURL *local = [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
        NSError *error = nil;
        NSMutableDictionary *result = [NSMutableDictionary new];
        if ([mode isEqualToString:@"backup"]) {
            NSURL *remote = [NSURL fileURLWithPath:@(argv[3]) isDirectory:YES];
            result[@"copied"] = @(FPBackUpLatestSave(local, remote, &error));
        } else if ([mode isEqualToString:@"import"]) {
            NSURL *source = [NSURL fileURLWithPath:@(argv[3])];
            result[@"imported"] = FPImportSave(source, local, &error).lastPathComponent ?: @"";
        } else {
            return 2;
        }
        result[@"error"] = error.localizedDescription ?: @"";
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        [NSFileHandle.fileHandleWithStandardOutput writeData:json];
    }
    return 0;
}
