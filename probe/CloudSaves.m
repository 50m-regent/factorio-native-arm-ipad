#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "SaveSync.h"

static NSString *const bookmarkKey = @"FactorioCloudSavesFolder";
static const NSTimeInterval backupInterval = 5 * 60;

static NSURL *localSaves(void) {
    return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Factorio/user/saves"]
                       isDirectory:YES];
}

@interface FPCloudSaves : NSObject <UIDocumentPickerDelegate>
@property(nonatomic,weak) UIButton *button;
@property(nonatomic,strong) NSURL *folder;
@property(nonatomic,strong) dispatch_queue_t worker;
@property(nonatomic,copy) NSString *status;
@property(nonatomic,strong) UIDocumentPickerViewController *picker;
@property(nonatomic) NSTimeInterval nextBackup;
@property(nonatomic) BOOL working;
@property(nonatomic) BOOL importing;
@end

@implementation FPCloudSaves
- (UIViewController *)presenter {
    UIViewController *controller = self.button.window.rootViewController;
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

- (void)updateButton {
    [self.button setTitle:@"Cloud saves" forState:UIControlStateNormal];
    self.button.accessibilityValue = self.status;
}

- (void)restoreFolder {
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:bookmarkKey];
    if (!bookmark) return;
    self.working = YES;
    dispatch_async(self.worker, ^{
        BOOL stale = NO;
        NSURL *folder = [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithoutUI
                                            relativeToURL:nil bookmarkDataIsStale:&stale error:NULL];
        if (stale && [folder startAccessingSecurityScopedResource]) {
            NSData *renewed = [folder bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil
                                                 relativeToURL:nil error:NULL];
            if (renewed) [NSUserDefaults.standardUserDefaults setObject:renewed forKey:bookmarkKey];
            [folder stopAccessingSecurityScopedResource];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.working = NO;
            self.folder = folder;
            self.status = folder ? @"Backup enabled." : @"Choose the backup folder again to restore access.";
            [self updateButton];
            [self backUpIfDue];
        });
    });
}

- (void)backUpNow {
    if (self.working || self.picker || !self.folder ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    self.working = YES;
    self.status = @"Backing up…";
    self.nextBackup = NSProcessInfo.processInfo.systemUptime + backupInterval;
    [self updateButton];
    NSURL *folder = self.folder;
    dispatch_async(self.worker, ^{
        @autoreleasepool {
            NSError *error = nil;
            BOOL copied = NO;
            NSString *status;
            if ([folder startAccessingSecurityScopedResource]) {
                @try {
                    NSURL *local = localSaves();
                    if ([NSFileManager.defaultManager createDirectoryAtURL:local withIntermediateDirectories:YES
                                                               attributes:nil error:&error]) {
                        copied = FPBackUpLatestSave(local, folder, &error);
                    }
                    status = error ? error.localizedDescription : copied
                        ? @"Backup updated. iCloud upload may still be pending."
                        : @"No newer completed save to back up.";
                } @finally {
                    [folder stopAccessingSecurityScopedResource];
                }
            } else {
                status = @"Folder access is unavailable. Choose the backup folder again.";
            }
            if (error) NSLog(@"FACTORIO_PROBE: cloud backup: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.working = NO;
                self.status = status;
                [self updateButton];
            });
        }
    });
}

- (void)backUpIfDue {
    if (NSProcessInfo.processInfo.systemUptime >= self.nextBackup) [self backUpNow];
}

- (void)becameActive:(NSNotification *)notification {
    (void)notification;
    [self backUpIfDue];
}

- (void)openPickerForImport:(BOOL)importSave {
    UIViewController *presenter = [self presenter];
    if (!presenter.viewIfLoaded.window) return;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[importSave ? UTTypeZIP : UTTypeFolder] asCopy:NO];
    picker.delegate = self;
    if (self.folder) picker.directoryURL = self.folder;
    self.picker = picker;
    self.importing = importSave;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)openPickerForImport:(BOOL)importSave afterMenu:(UIAlertController *)menu {
    void (^openPicker)(void) = ^{ [self openPickerForImport:importSave]; };
    if (menu.isBeingDismissed && [menu.transitionCoordinator animateAlongsideTransition:nil
        completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            if (!context.isCancelled) openPicker();
        }]) return;
    if (menu.presentingViewController) {
        [menu dismissViewControllerAnimated:YES completion:openPicker];
    } else {
        openPicker();
    }
}

- (void)showMenu {
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n\nThe latest completed save is backed up to %@ about every five minutes while the app is active. Import a ZIP to open it from the game's Load menu.",
        self.folder.lastPathComponent ?: @"No backup folder selected.", self.status ?: @"",
        FPLatestCloudSaveName];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cloud saves" message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    if (!self.working && !self.picker) {
        __weak UIAlertController *menu = alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"Import save…" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                [self openPickerForImport:YES afterMenu:menu];
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Choose backup folder…" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                [self openPickerForImport:NO afterMenu:menu];
            }]];
        if (self.folder) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Back up now" style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) { [self backUpNow]; }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Stop automatic backup" style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
                    self.folder = nil;
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:bookmarkKey];
                    self.status = @"Automatic backup is off.";
                    [self updateButton];
                }]];
        }
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter] presentViewController:alert animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (self.picker == controller) self.picker = nil;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.picker != controller) return;
    self.picker = nil;
    NSURL *selected = urls.firstObject;
    if (!selected) return;

    if (![selected startAccessingSecurityScopedResource]) {
        self.status = @"Could not access the selected item. Try choosing it again.";
        [self updateButton];
        return;
    }
    self.working = YES;
    BOOL importSave = self.importing;
    self.status = @"Opening the selected item…";
    [self updateButton];
    dispatch_async(self.worker, ^{
        @autoreleasepool {
            NSError *error = nil;
            NSData *bookmark = nil;
            NSURL *imported = nil;
            @try {
                if (importSave) {
                    NSURL *local = localSaves();
                    if ([NSFileManager.defaultManager createDirectoryAtURL:local withIntermediateDirectories:YES
                                                               attributes:nil error:&error]) {
                        imported = FPImportSave(selected, local, &error);
                    }
                } else {
                    bookmark = [selected bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil
                                                     relativeToURL:nil error:&error];
                }
            } @finally {
                [selected stopAccessingSecurityScopedResource];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.working = NO;
                if (bookmark) {
                    [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:bookmarkKey];
                    self.folder = selected;
                    self.status = @"Backup enabled.";
                    self.nextBackup = 0;
                } else if (imported) {
                    self.status = [NSString stringWithFormat:@"Imported %@. Select it from the game's Load menu.",
                                   imported.lastPathComponent.stringByDeletingPathExtension];
                } else {
                    self.status = error.localizedDescription ?: @"Could not open the selected item.";
                }
                [self updateButton];
                if (bookmark) [self backUpIfDue];
            });
        }
    });
}
@end

void InstallCloudSaves(UIButton *button) {
    static FPCloudSaves *saves;
    if (!saves) {
        saves = [FPCloudSaves new];
        saves.worker = dispatch_queue_create("org.factorioipad.save-sync", DISPATCH_QUEUE_SERIAL);
        [NSNotificationCenter.defaultCenter addObserver:saves selector:@selector(becameActive:)
                                                   name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSTimer scheduledTimerWithTimeInterval:15 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            [saves backUpIfDue];
        }];
        [saves restoreFolder];
    }
    saves.button = button;
    [button addTarget:saves action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];
    [saves updateButton];
}
