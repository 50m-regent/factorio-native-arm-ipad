#import <Foundation/Foundation.h>

extern NSString *const FPLatestCloudSaveName;

// Returns YES only when a new backup is published. A skipped backup has no error.
BOOL FPBackUpLatestSave(NSURL *localFolder, NSURL *cloudFolder, NSError **error);

// Imports a copy under an unused name and returns its local URL.
NSURL *FPImportSave(NSURL *source, NSURL *localFolder, NSError **error);
