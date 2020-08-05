//
//  iTermRestorableStateSaver.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 7/26/20.
//

#import "iTermRestorableStateSaver.h"

#import "DebugLogging.h"
#import "iTermRestorableStateRecord.h"
#import "NSArray+iTerm.h"
#import "NSData+iTerm.h"
#import "NSFileManager+iTerm.h"

@implementation iTermRestorableStateSaver {
    NSArray<id<iTermRestorableStateRecord>> *_records;
}

@synthesize delegate;

- (instancetype)initWithQueue:(dispatch_queue_t)queue
                     indexURL:(NSURL *)indexURL {
    self = [super init];
    if (self) {
        _queue = queue;
        _indexURL = [indexURL copy];
        _records = @[];
    }
    return self;
}

#pragma mark - iTermRestorableStateSaver

- (void)saveSynchronously:(BOOL)synchronously withCompletion:(void (^)(void))completion {
    NSMutableArray<iTermRestorableStateRecord *> *recordsToKeepUnchanged = [NSMutableArray array];
    NSMutableArray<iTermRestorableStateRecord *> *recordsNeedingNewContent = [NSMutableArray array];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"NSQuitAlwaysKeepsWindows"]) {
        DLog(@"NSQuitAlwaysKeepsWindows=YES");
        for (NSWindow *window in [self.delegate restorableStateWindows]) {
            iTermRestorableStateRecord *record = [_records objectPassingTest:^BOOL(iTermRestorableStateRecord *element, NSUInteger index, BOOL *stop) {
                return element.windowNumber == window.windowNumber;
            }];
            const BOOL needsRestoration = [self.delegate restorableStateWindowNeedsRestoration:window];
            if (record && !needsRestoration) {
                DLog(@"Keep %@ unchanged", @(window.windowNumber));
                [recordsToKeepUnchanged addObject:record];
                continue;
            }

            NSData *plaintext = [self restorableStateForWindow:window];
            if (!plaintext) {
                DLog(@"Failed to get plaintext for %@", @(window.windowNumber));
                continue;
            }

            if (record) {
                DLog(@"Modify contents of %@", @(window.windowNumber));
                record = [record withPlaintext:plaintext];
            } else {
                DLog(@"Create new restorable state for %@", @(window.windowNumber));
                record = [[iTermRestorableStateRecord alloc] initWithWindowNumber:window.windowNumber
                                                                       identifier:window.identifier
                                                                              key:[NSData randomAESKey]
                                                                        plaintext:plaintext];
            }
            [recordsNeedingNewContent addObject:record];
        }
    } else {
        DLog(@"NSQuitAlwaysKeepsWindows=NO");
    }
    _records = [recordsNeedingNewContent arrayByAddingObjectsFromArray:recordsToKeepUnchanged];
    __weak __typeof(self) weakSelf = self;
    if (synchronously) {
        dispatch_sync(_queue, ^{
            [weakSelf writeUnchanged:recordsToKeepUnchanged
                              update:recordsNeedingNewContent
                          completion:completion];
        });
    } else {
        dispatch_async(_queue, ^{
            [weakSelf writeUnchanged:recordsToKeepUnchanged
                              update:recordsNeedingNewContent
                          completion:completion];
        });
    }
}

// queue
- (void)writeUnchanged:(NSArray<iTermRestorableStateRecord *> *)recordsToKeepUnchanged
                update:(NSArray<iTermRestorableStateRecord *> *)recordsNeedingNewContent
            completion:(void (^)(void))completion {
    NSArray<NSURL *> *fileURLsToKeep = [[recordsToKeepUnchanged arrayByAddingObjectsFromArray:recordsNeedingNewContent] mapWithBlock:^id(iTermRestorableStateRecord *record) {
        return record.url;
    }];
    fileURLsToKeep = [fileURLsToKeep arrayByAddingObject:_indexURL];
    DLog(@"URLs to keep: %@", fileURLsToKeep);
    [self eraseFilesExcept:fileURLsToKeep];
    [self encryptAndSaveUnchangedRecords:recordsToKeepUnchanged
                          updatedRecords:recordsNeedingNewContent];

    dispatch_async(dispatch_get_main_queue(), ^{
        completion();
    });
}

// _queue
- (void)eraseFilesExcept:(NSArray<NSURL *> *)fileURLsToKeep {
    DLog(@"Erase files execpt %@", fileURLsToKeep);
    NSString *appSupport = [[NSFileManager defaultManager] applicationSupportDirectory];
    NSString *savedState = [appSupport stringByAppendingPathComponent:@"SavedState"];
    NSDirectoryEnumerator *enumerator =
    [[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:savedState] includingPropertiesForKeys:nil
                                            options:NSDirectoryEnumerationSkipsSubdirectoryDescendants
                                       errorHandler:nil];
    for (NSURL *url in enumerator) {
        if ([fileURLsToKeep containsObject:url.URLByResolvingSymlinksInPath]) {
            continue;
        }
        DLog(@"Erase %@", url.path);
        unlink(url.path.UTF8String);
    }
}

- (NSData *)restorableStateForWindow:(NSWindow *)window {
    NSKeyedArchiver *coder = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    coder.outputFormat = NSPropertyListBinaryFormat_v1_0;
    [self.delegate restorableStateEncodeWithCoder:coder window:window];
    [coder finishEncoding];

    return [coder encodedData];
}

// Runs on _queue
- (void)encryptAndSaveUnchangedRecords:(NSArray<iTermRestorableStateRecord *> *)recordsToKeepUnchanged
                        updatedRecords:(NSArray<iTermRestorableStateRecord *> *)recordsNeedingNewContent {
    NSMutableArray *plist = [NSMutableArray new];
    [recordsNeedingNewContent enumerateObjectsUsingBlock:^(iTermRestorableStateRecord * _Nonnull record, NSUInteger idx, BOOL * _Nonnull stop) {
        DLog(@"Write new content for %@", @(record.windowNumber));
        [record save];
        [plist addObject:record.indexEntry];
    }];
    [recordsToKeepUnchanged enumerateObjectsUsingBlock:^(iTermRestorableStateRecord * _Nonnull record, NSUInteger idx, BOOL * _Nonnull stop) {
        [plist addObject:record.indexEntry];
    }];
    DLog(@"Save index:\n%@", plist);
#warning TODO: Don't use property list serialization because it can't deal with nonstring dictionary keys. Use NSKeyedArchiver archivedDataWithRootObject.
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                   format:NSPropertyListXMLFormat_v1_0
                                                                  options:NSPropertyListImmutable
                                                                    error:nil];
    [plistData writeReadOnlyToURL:_indexURL];
}

@end