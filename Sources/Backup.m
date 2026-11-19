// SPDX-License-Identifier: GPL-3.0-or-later
// Manual chat backup and restore, the way Watusi does it for WhatsApp.
//
// A re-signed Viber cannot use Viber's iCloud backup, so Unslop can write the
// app's own data to a single file you keep in Files / iCloud Drive / AirDrop,
// and load it back after a reinstall. Restore is staged and applied at the next
// launch, before Viber opens its database.
#import "Unslop.h"

static NSString *const kMagic = @"UNSLOPBAK1\n";

// Folders inside the app container that hold chat data and settings.
static NSArray<NSString *> *roots(void) {
    return @[@"Documents", @"Library/Application Support", @"Library/Preferences"];
}
static NSURL *home(void) { return [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES]; }
static NSURL *pendingDir(void) { return [home() URLByAppendingPathComponent:@"Library/UnslopPending" isDirectory:YES]; }
static NSURL *pendingFile(void) { return [pendingDir() URLByAppendingPathComponent:@"restore.unslopbak"]; }

static BOOL skipPath(NSString *rel) {
    return [rel hasPrefix:@"Library/UnslopPending"] || [rel containsString:@"/UnslopPending/"];
}

static void putU32(NSFileHandle *h, uint32_t v) { NSData *d = [NSData dataWithBytes:&v length:4]; [h writeData:d]; }
static void putU64(NSFileHandle *h, uint64_t v) { NSData *d = [NSData dataWithBytes:&v length:8]; [h writeData:d]; }

NSURL *UCreateBackup(NSError **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDateFormatter *df = NSDateFormatter.new; df.dateFormat = @"yyyy-MM-dd-HHmm";
    NSString *name = [NSString stringWithFormat:@"Viber-Unslop-%@.unslopbak", [df stringFromDate:NSDate.date]];
    NSURL *out = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    [fm removeItemAtURL:out error:nil];
    if (![fm createFileAtPath:out.path contents:nil attributes:nil]) {
        if (err) *err = [NSError errorWithDomain:@"Unslop" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Cannot create backup file"}];
        return nil;
    }
    NSFileHandle *w = [NSFileHandle fileHandleForWritingToURL:out error:err];
    if (!w) return nil;
    [w writeData:[kMagic dataUsingEncoding:NSUTF8StringEncoding]];

    NSUInteger files = 0;
    for (NSString *root in roots()) {
        NSURL *base = [home() URLByAppendingPathComponent:root isDirectory:YES];
        NSDirectoryEnumerator *en = [fm enumeratorAtURL:base
            includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
            options:0 errorHandler:nil];
        for (NSURL *u in en) {
            @autoreleasepool {
                NSNumber *reg = nil; [u getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil];
                if (!reg.boolValue) continue;
                NSString *rel = [u.path substringFromIndex:home().path.length + 1];
                if (skipPath(rel)) continue;
                NSFileHandle *r = [NSFileHandle fileHandleForReadingFromURL:u error:nil];
                if (!r) continue;
                NSData *pathData = [rel dataUsingEncoding:NSUTF8StringEncoding];
                NSNumber *size = nil; [u getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
                putU32(w, (uint32_t)pathData.length); [w writeData:pathData];
                putU64(w, size.unsignedLongLongValue);
                uint64_t left = size.unsignedLongLongValue;
                while (left > 0) {
                    @autoreleasepool {
                        NSData *chunk = [r readDataOfLength:(NSUInteger)MIN(left, (uint64_t)(1 << 20))];
                        if (!chunk.length) break;
                        [w writeData:chunk]; left -= chunk.length;
                    }
                }
                [r closeFile]; files++;
            }
        }
    }
    putU32(w, 0);
    [w closeFile];
    ULOG(@"backup written: %lu files", (unsigned long)files);
    return out;
}

BOOL UStageRestore(NSURL *picked, NSError **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSFileHandle *h = [NSFileHandle fileHandleForReadingFromURL:picked error:err];
    if (!h) return NO;
    NSData *magic = [h readDataOfLength:kMagic.length];
    [h closeFile];
    if (![[[NSString alloc] initWithData:magic encoding:NSUTF8StringEncoding] isEqual:kMagic]) {
        if (err) *err = [NSError errorWithDomain:@"Unslop" code:2 userInfo:@{NSLocalizedDescriptionKey: @"This is not an Unslop backup file"}];
        return NO;
    }
    [fm createDirectoryAtURL:pendingDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtURL:pendingFile() error:nil];
    return [fm copyItemAtURL:picked toURL:pendingFile() error:err];
}

BOOL UHasPendingRestore(void) { return [NSFileManager.defaultManager fileExistsAtPath:pendingFile().path]; }

static BOOL safeRel(NSString *rel) {
    if (!rel.length || [rel hasPrefix:@"/"] || [rel containsString:@".."]) return NO;
    for (NSString *r in roots()) if ([rel hasPrefix:[r stringByAppendingString:@"/"]]) return YES;
    return NO;
}

// Runs first thing at launch, before Viber touches its data.
void UApplyPendingRestore(void) {
    if (!UHasPendingRestore()) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSFileHandle *h = [NSFileHandle fileHandleForReadingFromURL:pendingFile() error:nil];
    if (!h) return;
    [h readDataOfLength:kMagic.length];
    // Wipe current data, then extract.
    for (NSString *root in roots()) {
        NSURL *base = [home() URLByAppendingPathComponent:root isDirectory:YES];
        for (NSURL *item in [fm contentsOfDirectoryAtURL:base includingPropertiesForKeys:nil options:0 error:nil])
            [fm removeItemAtURL:item error:nil];
    }
    NSUInteger files = 0;
    for (;;) {
        @autoreleasepool {
            NSData *l = [h readDataOfLength:4];
            if (l.length < 4) break;
            uint32_t plen; memcpy(&plen, l.bytes, 4);
            if (plen == 0) break;
            NSString *rel = [[NSString alloc] initWithData:[h readDataOfLength:plen] encoding:NSUTF8StringEncoding];
            NSData *sd = [h readDataOfLength:8]; uint64_t size; memcpy(&size, sd.bytes, 8);
            BOOL ok = safeRel(rel);
            NSFileHandle *w = nil;
            if (ok) {
                NSURL *dst = [home() URLByAppendingPathComponent:rel];
                [fm createDirectoryAtURL:dst.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                [fm createFileAtPath:dst.path contents:nil attributes:nil];
                w = [NSFileHandle fileHandleForWritingToURL:dst error:nil];
            }
            uint64_t left = size;
            while (left > 0) {
                @autoreleasepool {
                    NSData *chunk = [h readDataOfLength:(NSUInteger)MIN(left, (uint64_t)(1 << 20))];
                    if (!chunk.length) { left = 0; break; }
                    [w writeData:chunk]; left -= chunk.length;
                }
            }
            [w closeFile]; if (ok) files++;
        }
    }
    [h closeFile];
    [fm removeItemAtURL:pendingFile() error:nil];
    ULOG(@"restore applied: %lu files", (unsigned long)files);
}
