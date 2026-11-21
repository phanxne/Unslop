// SPDX-License-Identifier: GPL-3.0-or-later
// Chat backup and restore.
//
// A re-signed Viber cannot use Viber's iCloud backup, so Unslop writes the app's
// own data to one file. Design goals: never produce a backup that cannot be
// restored, and never destroy current data on a bad restore.
//
//  * SQLite databases are copied with SQLite's online backup API, so the copy is
//    consistent even while Viber is writing (-wal/-shm/-journal files are skipped).
//  * Every backup ends with a SHA-256 of its contents and is re-read and verified
//    after writing.
//  * Restore is staged: the file is verified, extracted next to the live data,
//    every database is integrity-checked, and only then swapped in. The previous
//    data is kept in Library/UnslopPending/old until the next restore.
#import "Unslop.h"
#import <CommonCrypto/CommonDigest.h>
#import <sqlite3.h>
#import <stdlib.h>
#import <limits.h>

static NSString *const kMagic = @"UNSLOPBAK2\n";
#define kDigestLen CC_SHA256_DIGEST_LENGTH

// Folders inside the app container that hold chat data and settings.
static NSArray<NSString *> *roots(void) {
    return @[@"Documents", @"Library/Application Support", @"Library/Preferences"];
}
// NSHomeDirectory() returns a path through /var, but NSFileManager's
// enumerator resolves it to the real /private/var path, so slicing a
// relative path by home().path.length against an enumerated URL would cut
// into the middle of the container UUID. -stringByResolvingSymlinksInPath
// leaves it untouched here (the sandbox apparently doesn't let it stat
// through /var), so resolve with realpath(3) instead.
static NSURL *home(void) {
    const char *in = NSHomeDirectory().fileSystemRepresentation;
    char buf[PATH_MAX];
    const char *resolved = realpath(in, buf) ?: in;
    return [NSURL fileURLWithPath:[NSString stringWithUTF8String:resolved] isDirectory:YES];
}
static NSURL *pendingDir(void) { return [home() URLByAppendingPathComponent:@"Library/UnslopPending" isDirectory:YES]; }
static NSURL *pendingFile(void) { return [pendingDir() URLByAppendingPathComponent:@"restore.unslopbak"]; }
static NSURL *extractDir(void) { return [pendingDir() URLByAppendingPathComponent:@"extract" isDirectory:YES]; }
static NSURL *oldDir(void) { return [pendingDir() URLByAppendingPathComponent:@"old" isDirectory:YES]; }

static NSError *fail(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:@"Unslop" code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static BOOL skipPath(NSString *rel) {
    if ([rel hasPrefix:@"Library/UnslopPending"] || [rel containsString:@"/UnslopPending/"]) return YES;
    NSString *n = rel.lastPathComponent;
    // -wal/-shm/-journal are SQLite's own transient files; ".backup"/".tmp" are
    // atomic-write sidecars (e.g. preference stores) that can be replaced or
    // removed out from under us mid-read. None of these hold state that isn't
    // also in the file they are a transient copy of or working toward.
    return [n hasSuffix:@"-wal"] || [n hasSuffix:@"-shm"] || [n hasSuffix:@"-journal"] ||
           [n hasSuffix:@".backup"] || [n hasSuffix:@".tmp"];
}

static BOOL isSQLite(NSURL *u) {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingFromURL:u error:nil];
    NSData *d = [h readDataOfLength:16];
    [h closeFile];
    return d.length == 16 && memcmp(d.bytes, "SQLite format 3\0", 16) == 0;
}

// Consistent copy of a live database.
static BOOL snapshotSQLite(NSURL *src, NSURL *dst) {
    sqlite3 *in = NULL, *out = NULL;
    BOOL ok = NO;
    if (sqlite3_open_v2(src.fileSystemRepresentation, &in, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK &&
        sqlite3_open_v2(dst.fileSystemRepresentation, &out, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) == SQLITE_OK) {
        sqlite3_busy_timeout(in, 5000);
        sqlite3_backup *b = sqlite3_backup_init(out, "main", in, "main");
        if (b) {
            int rc;
            do { rc = sqlite3_backup_step(b, -1); if (rc == SQLITE_BUSY || rc == SQLITE_LOCKED) sqlite3_sleep(100); }
            while (rc == SQLITE_BUSY || rc == SQLITE_LOCKED);
            ok = sqlite3_backup_finish(b) == SQLITE_OK && rc == SQLITE_DONE;
        }
    }
    if (in) sqlite3_close(in);
    if (out) sqlite3_close(out);
    return ok;
}

static BOOL quickCheck(NSURL *u) {
    sqlite3 *db = NULL; BOOL ok = NO;
    if (sqlite3_open_v2(u.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "PRAGMA quick_check(1)", -1, &st, NULL) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW) {
            const unsigned char *t = sqlite3_column_text(st, 0);
            ok = t && strcmp((const char *)t, "ok") == 0;
        }
        if (st) sqlite3_finalize(st);
    }
    if (db) sqlite3_close(db);
    return ok;
}

#pragma mark - writer with running digest

typedef struct { __unsafe_unretained NSFileHandle *h; CC_SHA256_CTX ctx; } Out;
static void emit(Out *o, NSData *d) { CC_SHA256_Update(&o->ctx, d.bytes, (CC_LONG)d.length); [o->h writeData:d]; }
static void emitU32(Out *o, uint32_t v) { emit(o, [NSData dataWithBytes:&v length:4]); }
static void emitU64(Out *o, uint64_t v) { emit(o, [NSData dataWithBytes:&v length:8]); }

// Walks a backup file. If `dest` is set, extracts into it. Always checks the digest.
static BOOL readBackup(NSURL *file, NSURL *dest, NSUInteger *count, NSError **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSFileHandle *h = [NSFileHandle fileHandleForReadingFromURL:file error:err];
    if (!h) return NO;
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    NSData *mg = [h readDataOfLength:kMagic.length];
    if (![[[NSString alloc] initWithData:mg encoding:NSUTF8StringEncoding] isEqual:kMagic]) {
        [h closeFile]; if (err) *err = fail(2, @"This is not a valid Unslop backup file"); return NO;
    }
    CC_SHA256_Update(&ctx, mg.bytes, (CC_LONG)mg.length);
    NSUInteger n = 0;
    BOOL ok = YES;
    for (;;) {
        @autoreleasepool {
            NSData *l = [h readDataOfLength:4];
            if (l.length < 4) { ULOG(@"readBackup: short length-prefix read (%lu bytes) at n=%lu", (unsigned long)l.length, (unsigned long)n); ok = NO; break; }
            CC_SHA256_Update(&ctx, l.bytes, 4);
            uint32_t plen; memcpy(&plen, l.bytes, 4);
            if (plen == 0) break;
            if (plen > 4096) { ULOG(@"readBackup: implausible plen=%u at n=%lu", plen, (unsigned long)n); ok = NO; break; }
            NSData *pd = [h readDataOfLength:plen];
            NSData *sd = [h readDataOfLength:8];
            if (pd.length < plen || sd.length < 8) { ULOG(@"readBackup: short name/size read at n=%lu (pd=%lu want=%u, sd=%lu)", (unsigned long)n, (unsigned long)pd.length, plen, (unsigned long)sd.length); ok = NO; break; }
            CC_SHA256_Update(&ctx, pd.bytes, (CC_LONG)plen);
            CC_SHA256_Update(&ctx, sd.bytes, 8);
            uint64_t size; memcpy(&size, sd.bytes, 8);
            NSString *rel = [[NSString alloc] initWithData:pd encoding:NSUTF8StringEncoding];
            BOOL safe = rel.length && ![rel hasPrefix:@"/"] && ![rel containsString:@".."];
            if (safe) { BOOL inRoot = NO; for (NSString *r in roots()) if ([rel hasPrefix:[r stringByAppendingString:@"/"]]) inRoot = YES; safe = inRoot; }
            if (!safe) { ULOG(@"readBackup: unsafe path at n=%lu: %@", (unsigned long)n, rel); ok = NO; break; }
            NSFileHandle *w = nil;
            if (dest) {
                NSURL *dst = [dest URLByAppendingPathComponent:rel];
                [fm createDirectoryAtURL:dst.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                [fm createFileAtPath:dst.path contents:nil attributes:nil];
                w = [NSFileHandle fileHandleForWritingToURL:dst error:nil];
                if (!w) { ok = NO; break; }
            }
            uint64_t left = size;
            while (left > 0) {
                NSData *c = [h readDataOfLength:(NSUInteger)MIN(left, (uint64_t)(1 << 20))];
                if (!c.length) { ULOG(@"readBackup: short read on %@ (wanted %llu more of %llu)", rel, left, size); ok = NO; break; }
                CC_SHA256_Update(&ctx, c.bytes, (CC_LONG)c.length);
                [w writeData:c]; left -= c.length;
            }
            [w closeFile];
            if (!ok) break;
            n++;
        }
        if (!ok) break;
    }
    NSData *want = ok ? [h readDataOfLength:kDigestLen] : nil;
    [h closeFile];
    uint8_t got[kDigestLen]; CC_SHA256_Final(got, &ctx);
    if (!ok || want.length != kDigestLen || memcmp(got, want.bytes, kDigestLen) != 0) {
        ULOG(@"readBackup fail: ok=%d want.length=%lu (n=%lu files read)", ok, (unsigned long)want.length, (unsigned long)n);
        if (err) *err = fail(3, @"The backup file is damaged or incomplete");
        return NO;
    }
    if (count) *count = n;
    return YES;
}

BOOL UVerifyBackup(NSURL *file, NSUInteger *count, NSError **err) { return readBackup(file, nil, count, err); }

#pragma mark - create

NSURL *UCreateBackup(NSError **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDateFormatter *df = NSDateFormatter.new; df.dateFormat = @"yyyy-MM-dd-HHmm";
    NSString *name = [NSString stringWithFormat:@"Viber-Unslop-%@.unslopbak", [df stringFromDate:NSDate.date]];
    NSURL *out = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    NSURL *scratch = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"unslop-snap"]];
    [fm removeItemAtURL:out error:nil];
    [fm removeItemAtURL:scratch error:nil];
    [fm createDirectoryAtURL:scratch withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm createFileAtPath:out.path contents:nil attributes:nil]) {
        if (err) *err = fail(1, @"Cannot create backup file"); return nil;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:out error:err];
    if (!fh) return nil;
    Out o; o.h = fh; CC_SHA256_Init(&o.ctx);
    emit(&o, [kMagic dataUsingEncoding:NSUTF8StringEncoding]);

    NSUInteger files = 0;
    NSString *problem = nil;
    for (NSString *root in roots()) {
        NSURL *base = [home() URLByAppendingPathComponent:root isDirectory:YES];
        NSDirectoryEnumerator *en = [fm enumeratorAtURL:base includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                options:0 errorHandler:nil];
        for (NSURL *u in en) {
            @autoreleasepool {
                NSNumber *reg = nil; [u getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil];
                if (!reg.boolValue) continue;
                NSString *rel = [u.path substringFromIndex:home().path.length + 1];
                if (skipPath(rel)) continue;
                // Work from a private copy so the size cannot change under us.
                NSURL *snap = [scratch URLByAppendingPathComponent:@"f"];
                [fm removeItemAtURL:snap error:nil];
                BOOL copied = isSQLite(u) ? snapshotSQLite(u, snap) : [fm copyItemAtURL:u toURL:snap error:nil];
                if (!copied) { problem = [NSString stringWithFormat:@"Could not read %@", rel.lastPathComponent]; }
                else {
                    NSFileHandle *r = [NSFileHandle fileHandleForReadingFromURL:snap error:nil];
                    uint64_t size = [[fm attributesOfItemAtPath:snap.path error:nil][NSFileSize] unsignedLongLongValue];
                    NSData *pd = [rel dataUsingEncoding:NSUTF8StringEncoding];
                    emitU32(&o, (uint32_t)pd.length); emit(&o, pd); emitU64(&o, size);
                    uint64_t left = size;
                    while (left > 0) {
                        NSData *c = [r readDataOfLength:(NSUInteger)MIN(left, (uint64_t)(1 << 20))];
                        if (!c.length) { problem = @"Read error"; break; }
                        emit(&o, c); left -= c.length;
                    }
                    [r closeFile]; files++;
                }
            }
            if (problem) break;
        }
        if (problem) break;
    }
    [fm removeItemAtURL:scratch error:nil];
    if (problem) { [fh closeFile]; [fm removeItemAtURL:out error:nil]; if (err) *err = fail(4, problem); return nil; }
    emitU32(&o, 0);
    uint8_t dg[kDigestLen]; CC_SHA256_Final(dg, &o.ctx);
    [fh writeData:[NSData dataWithBytes:dg length:kDigestLen]];
    [fh closeFile];

    // Prove it reads back before telling anyone it is a good backup.
    NSUInteger back = 0;
    BOOL verOK = UVerifyBackup(out, &back, err);
    ULOG(@"backup write: files=%lu verOK=%d back=%lu", (unsigned long)files, verOK, (unsigned long)back);
    if (!verOK || back != files) {
        [fm removeItemAtURL:out error:nil];
        if (err && !*err) *err = fail(5, @"Backup verification failed");
        return nil;
    }
    ULOG(@"backup verified: %lu files", (unsigned long)files);
    return out;
}

#pragma mark - restore

BOOL UStageRestore(NSURL *picked, NSError **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!UVerifyBackup(picked, NULL, err)) return NO;   // reject bad files before anything changes
    [fm createDirectoryAtURL:pendingDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtURL:pendingFile() error:nil];
    return [fm copyItemAtURL:picked toURL:pendingFile() error:err];
}

BOOL UHasPendingRestore(void) { return [NSFileManager.defaultManager fileExistsAtPath:pendingFile().path]; }

// Runs first thing at launch, before Viber touches its data.
void UApplyPendingRestore(void) {
    if (!UHasPendingRestore()) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *err = nil;
    [fm removeItemAtURL:extractDir() error:nil];
    [fm createDirectoryAtURL:extractDir() withIntermediateDirectories:YES attributes:nil error:nil];

    // 1. Extract beside the live data and check everything.
    NSUInteger n = 0;
    BOOL ok = readBackup(pendingFile(), extractDir(), &n, &err);
    if (ok) {
        NSDirectoryEnumerator *en = [fm enumeratorAtURL:extractDir() includingPropertiesForKeys:nil options:0 errorHandler:nil];
        for (NSURL *u in en) if (isSQLite(u) && !quickCheck(u)) { ok = NO; ULOG(@"restore: bad database %@", u.lastPathComponent); break; }
    }
    if (!ok) {
        ULOG(@"restore aborted, current data untouched: %@", err.localizedDescription);
        [fm removeItemAtURL:extractDir() error:nil];
        [fm removeItemAtURL:pendingFile() error:nil];
        return;
    }

    // 2. Swap. Current data moves to old/ instead of being deleted.
    [fm removeItemAtURL:oldDir() error:nil];
    [fm createDirectoryAtURL:oldDir() withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *root in roots()) {
        NSURL *live = [home() URLByAppendingPathComponent:root isDirectory:YES];
        NSURL *fresh = [extractDir() URLByAppendingPathComponent:root isDirectory:YES];
        NSURL *keep = [oldDir() URLByAppendingPathComponent:[root stringByReplacingOccurrencesOfString:@"/" withString:@"_"]];
        if (![fm fileExistsAtPath:fresh.path]) continue;   // backup had nothing for this root
        if ([fm fileExistsAtPath:live.path]) [fm moveItemAtURL:live toURL:keep error:nil];
        [fm createDirectoryAtURL:live.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![fm moveItemAtURL:fresh toURL:live error:nil] && [fm fileExistsAtPath:keep.path])
            [fm moveItemAtURL:keep toURL:live error:nil];   // roll this root back
    }
    [fm removeItemAtURL:extractDir() error:nil];
    [fm removeItemAtURL:pendingFile() error:nil];
    ULOG(@"restore applied: %lu files", (unsigned long)n);
}
