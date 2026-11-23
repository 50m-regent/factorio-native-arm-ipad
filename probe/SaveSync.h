#import <Foundation/Foundation.h>

// Runs on one worker queue. Existing saves are never overwritten or deleted.
@interface FPSaveSyncEngine : NSObject
- (NSUInteger)syncLocal:(NSURL *)local remote:(NSURL *)remote error:(NSError **)error;
@end
