#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "SaveSync.h"

static NSString *const bookmarkKey=@"FactorioCloudSavesFolder";

@interface FPCloudSaves : NSObject <UIDocumentPickerDelegate>
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) NSURL *folder;
@property(nonatomic,strong) FPSaveSyncEngine *engine;
@property(nonatomic,strong) dispatch_queue_t worker;
@property(nonatomic,copy) NSString *status;
@property(nonatomic) BOOL syncing;
@end

@implementation FPCloudSaves
- (UIViewController *)presenter {
    UIViewController *controller=self.button.window.rootViewController;
    while (controller.presentedViewController) controller=controller.presentedViewController;
    return controller;
}
- (void)updateButton {
    [self.button setTitle:self.syncing ? @"Syncing…" : @"Cloud saves" forState:UIControlStateNormal];
    self.button.accessibilityValue=self.status;
}
- (void)message:(NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Cloud saves" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter] presentViewController:alert animated:YES completion:nil];
}
- (void)restoreFolder {
    NSData *bookmark=[NSUserDefaults.standardUserDefaults dataForKey:bookmarkKey];
    if (!bookmark) return;
    self.syncing=YES;
    [self updateButton];
    // Bookmark resolution can contact a File Provider; keep it off the game/UI thread.
    dispatch_async(self.worker,^{
        BOOL stale=NO;
        NSError *error=nil;
        NSURL *folder=[NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithoutUI
                                         relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
        if (folder && stale && [folder startAccessingSecurityScopedResource]) {
            NSData *renewed=[folder bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
            if (renewed) [NSUserDefaults.standardUserDefaults setObject:renewed forKey:bookmarkKey];
            [folder stopAccessingSecurityScopedResource];
        }
        dispatch_async(dispatch_get_main_queue(),^{
            self.syncing=NO;
            self.folder=folder;
            self.status=folder ? @"Waiting to sync." : @"Folder access expired. Choose the folder again.";
            [self updateButton];
            [self syncNow];
        });
    });
}
- (void)syncNow {
    if (self.syncing || !self.folder || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
    self.syncing=YES;
    [self updateButton];
    NSURL *folder=self.folder;
    NSURL *local=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Factorio/user/saves"] isDirectory:YES];
    dispatch_async(self.worker,^{
        @autoreleasepool {
            NSError *error=nil;
            NSUInteger count=0;
            BOOL access=[folder startAccessingSecurityScopedResource];
            if (!access) {
                error=[NSError errorWithDomain:@"FactorioSaveSync" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Folder access is unavailable. Choose the folder again."}];
            } else {
                @try {
                    if ([NSFileManager.defaultManager createDirectoryAtURL:local withIntermediateDirectories:YES attributes:nil error:&error]) {
                        count=[self.engine syncLocal:local remote:folder error:&error];
                    }
                } @finally {
                    [folder stopAccessingSecurityScopedResource];
                }
            }
            NSString *status=error ? error.localizedDescription : [NSString stringWithFormat:@"Checked %@. Copied %lu save(s). iCloud upload may still be pending.",
                [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle],(unsigned long)count];
            if (error) NSLog(@"FACTORIO_PROBE: cloud save sync: %@",error);
            dispatch_async(dispatch_get_main_queue(),^{
                self.syncing=NO;
                self.status=status;
                [self updateButton];
            });
        }
    });
}
- (void)chooseFolder {
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate=self;
    picker.allowsMultipleSelection=NO;
    [[self presenter] presentViewController:picker animated:YES completion:nil];
}
- (void)showMenu {
    NSString *message=[NSString stringWithFormat:@"%@\n\n%@\n\nChoose a folder in iCloud Drive. Saves sync both ways every 15 seconds while this app is active. Different versions of the same name are kept as separate saves. Deletions are not synced. Save in the game before switching devices. On Mac, copy saves to or from this folder. Open the copied save to continue.",
        self.folder ? self.folder.lastPathComponent : @"No folder selected.",self.status ?: @"Sync is off."];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Cloud saves" message:message preferredStyle:UIAlertControllerStyleAlert];
    if (!self.syncing) {
        if (self.folder) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Sync now" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self syncNow]; }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Stop syncing" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
                self.folder=nil;
                [NSUserDefaults.standardUserDefaults removeObjectForKey:bookmarkKey];
                self.status=@"Sync is off. Existing copies have been kept.";
                [self updateButton];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"Choose folder…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self chooseFolder]; }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter] presentViewController:alert animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *folder=urls.firstObject;
    if (!folder || ![folder startAccessingSecurityScopedResource]) {
        [self message:@"Could not access this folder. Try choosing it again."]; return;
    }
    NSError *error=nil;
    NSData *bookmark=[folder bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
    [folder stopAccessingSecurityScopedResource];
    if (!bookmark) { [self message:error.localizedDescription ?: @"Could not remember this folder."]; return; }
    [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:bookmarkKey];
    self.folder=folder;
    self.status=@"Folder selected. Waiting to sync.";
    [self updateButton];
    [self syncNow];
}
@end

void InstallCloudSaves(UIButton *button) {
    static FPCloudSaves *sync;
    if (sync) return;
    sync=[FPCloudSaves new];
    sync.button=button;
    sync.engine=[FPSaveSyncEngine new];
    sync.worker=dispatch_queue_create("org.factorioipad.save-sync",DISPATCH_QUEUE_SERIAL);
    [button addTarget:sync action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];
    [sync updateButton];
    [sync restoreFolder];
    [NSNotificationCenter.defaultCenter addObserver:sync selector:@selector(syncNow) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSTimer scheduledTimerWithTimeInterval:15 repeats:YES block:^(NSTimer *timer) { [sync syncNow]; }];
}
