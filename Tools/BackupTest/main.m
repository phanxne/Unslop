// SPDX-License-Identifier: GPL-3.0-or-later
// Simulator test for chat backup and restore (see `make test-backup`). Writes the result to /tmp/ubk.txt.
#import <UIKit/UIKit.h>
#import "Unslop.h"
@interface AD : UIResponder <UIApplicationDelegate> @property UIWindow *window; @end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *h = NSHomeDirectory();
    NSMutableString *log = NSMutableString.new;
    NSData *bin = [NSData dataWithBytes:(uint8_t[]){0,1,2,3,250,251,252,253,0,0,9} length:11];
    NSMutableData *big = NSMutableData.new; for (int i = 0; i < 3000000; i++) { uint8_t b = (uint8_t)(i * 31); [big appendBytes:&b length:1]; }
    [fm createDirectoryAtPath:[h stringByAppendingPathComponent:@"Documents/chats"] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[h stringByAppendingPathComponent:@"Library/Application Support/UnslopGroups/g"] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[h stringByAppendingPathComponent:@"Library/Preferences"] withIntermediateDirectories:YES attributes:nil error:nil];
    [bin writeToFile:[h stringByAppendingPathComponent:@"Documents/chats/a.bin"] atomically:YES];
    [big writeToFile:[h stringByAppendingPathComponent:@"Library/Application Support/UnslopGroups/g/viber.db"] atomically:YES];
    [@"pref" writeToFile:[h stringByAppendingPathComponent:@"Library/Preferences/x.plist"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSError *e = nil; NSURL *bk = UCreateBackup(&e);
    [log appendFormat:@"backup %@ size=%llu err=%@\n", bk.lastPathComponent, [[fm attributesOfItemAtPath:bk.path error:nil] fileSize], e];
    // wipe + corrupt
    [fm removeItemAtPath:[h stringByAppendingPathComponent:@"Documents/chats/a.bin"] error:nil];
    [@"junk" writeToFile:[h stringByAppendingPathComponent:@"Library/Application Support/UnslopGroups/g/viber.db"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"junk2" writeToFile:[h stringByAppendingPathComponent:@"Documents/extra.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    BOOL staged = UStageRestore(bk, &e);
    [log appendFormat:@"staged=%d pending=%d\n", staged, UHasPendingRestore()];
    UApplyPendingRestore();
    NSData *ra = [NSData dataWithContentsOfFile:[h stringByAppendingPathComponent:@"Documents/chats/a.bin"]];
    NSData *d = [NSData dataWithContentsOfFile:[h stringByAppendingPathComponent:@"Library/Application Support/UnslopGroups/g/viber.db"]];
    [log appendFormat:@"a.bin match=%d  viber.db match=%d (len %lu)  extra removed=%d pending cleared=%d\n",
        [ra isEqualToData:bin], [d isEqualToData:big], (unsigned long)d.length,
        ![fm fileExistsAtPath:[h stringByAppendingPathComponent:@"Documents/extra.txt"]], !UHasPendingRestore()];
    // bad file rejection
    [@"hello" writeToFile:@"/tmp/notbackup.unslopbak" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [log appendFormat:@"reject bad file=%d\n", !UStageRestore([NSURL fileURLWithPath:@"/tmp/notbackup.unslopbak"], &e)];
    [log writeToFile:@"/tmp/ubk.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = UIViewController.new; [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int c, char **v) { @autoreleasepool { return UIApplicationMain(c, v, nil, @"AD"); } }
