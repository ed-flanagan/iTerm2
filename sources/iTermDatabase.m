//
//  iTermDatabase.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 7/28/20.
//

#import "iTermDatabase.h"

#import "DebugLogging.h"
#import "FMDatabase.h"

@interface FMResultSet (iTerm)<iTermDatabaseResultSet>
@end

@interface iTermSqliteDatabaseImpl: NSObject<iTermDatabase>
- (instancetype)initWithDatabase:(FMDatabase *)db NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation iTermSqliteDatabaseFactory

- (nullable id<iTermDatabase>)withURL:(NSURL *)url {
    FMDatabase *db = [FMDatabase databaseWithPath:url.path];
    return [[iTermSqliteDatabaseImpl alloc] initWithDatabase:db];
}

@end

@implementation iTermSqliteDatabaseImpl {
    FMDatabase *_db;
}

- (instancetype)initWithDatabase:(FMDatabase *)db {
    self = [super init];
    if (self) {
        _db = db;
    }
    return self;
}

- (void)unlink {
    assert(!_db.isOpen);
    if (!_db.databaseURL) {
        return;
    }
    NSError *error = nil;
    NSArray<NSURL *> *urls = @[
        _db.databaseURL,
        [_db.databaseURL.URLByDeletingPathExtension URLByAppendingPathExtension:@"sqlite-shm"],
        [_db.databaseURL.URLByDeletingPathExtension URLByAppendingPathExtension:@"sqlite-wal"],
    ];
    for (NSURL *url in urls) {
        if (![[NSFileManager defaultManager] removeItemAtURL:url
                                                       error:&error]) {
            DLog(@"Failed to unlink %@: %@", url.path, error);
        }
    }
}

- (BOOL)executeUpdate:(NSString *)sql, ... {
    va_list args;
    va_start(args, sql);
    const BOOL result = [_db executeUpdate:sql withVAList:args];
    va_end(args);

#warning DNS
    va_start(args, sql);
    NSLog(@"%@", [self formatSQL:sql vaList:args]);
    va_end(args);

    if (gDebugLogging) {
        va_start(args, sql);
        [self logStatement:sql vaList:args];
        va_end(args);
    }
    return result;
}

- (NSNumber *)lastInsertRowId {
    const int64_t rowid = _db.lastInsertRowId;
    if (!rowid) {
        return nil;
    }
    return @(rowid);
}

- (NSString *)formatSQL:(NSString *)sql vaList:(va_list)args {
    NSString *fmt = [sql stringByReplacingOccurrencesOfString:@"?" withString:@"“%@”"];
    return [[NSString alloc] initWithFormat:fmt arguments:args];
}

- (void)logStatement:(NSString *)sql vaList:(va_list)args {
    if (!gDebugLogging) {
        return;
    }
    NSString *statement = [self formatSQL:sql vaList:args];
    NSLog(@"%@", statement);
    DebugLogImpl(__FILE__,
                 __LINE__,
                 __FUNCTION__,
                 statement);
}

- (id<iTermDatabaseResultSet> _Nullable)executeQuery:(NSString*)sql, ... {
    va_list args;
    va_start(args, sql);
    FMResultSet * _Nullable result = [_db executeQuery:sql withVAList:args];
    va_end(args);

    if (gDebugLogging) {
        va_start(args, sql);
        [self logStatement:sql vaList:args];
        va_end(args);
    }

    return result;
}

- (BOOL)open {
    DLog(@"Open");
    const BOOL ok = [_db open];
    if (ok) {
        DLog(@"OK");
        return YES;
    }
    DLog(@"Failed to open db: %@", _db.lastError);

    // Delete and re-open.
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSURL *url = [NSURL fileURLWithPath:[_db databasePath]];
    [fileManager removeItemAtPath:url.path error:&error];
    DLog(@"Remove %@: error=%@", url.path, error);
    if ([_db open]) {
        return YES;
    }
    DLog(@"Failed to open db after deletion: %@", _db.lastError);
    return NO;
}

- (BOOL)close {
    DLog(@"Close");
    return [_db close];
}

- (NSError *)lastError {
    return [_db lastError];
}

- (BOOL)transaction:(BOOL (^ NS_NOESCAPE)(void))block {
    [_db beginTransaction];
    DLog(@"Begin transaction");
    BOOL result;
    if (block()) {
        DLog(@"Commit");
        result = [_db commit];
    } else {
        DLog(@"Rollback");
        result = [_db rollback];
    }
    if (!result) {
        DLog(@"error=%@", _db.lastError);
    }
    return result;
}

@end
