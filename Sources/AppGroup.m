// SPDX-License-Identifier: GPL-3.0-or-later
// A re-signed app cannot hold Viber's app group, so the system returns nil for
// its shared container and Viber fails on launch. Fall back to a folder inside
// the app's own sandbox, which is all a single-app install needs.
#import "Unslop.h"
#import <objc/runtime.h>

void UInstallAppGroupFallback(void) {
    SEL sel = @selector(containerURLForSecurityApplicationGroupIdentifier:);
    Method m = class_getInstanceMethod(NSFileManager.class, sel);
    if (!m) return;
    NSURL *(*orig)(id, SEL, NSString *) = (void *)method_getImplementation(m);
    class_replaceMethod(NSFileManager.class, sel, imp_implementationWithBlock(
        ^NSURL *(NSFileManager *fm, NSString *group) {
            NSURL *url = orig(fm, sel, group);
            if (url || !group.length) return url;
            NSURL *base = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
            NSURL *dir = [[base URLByAppendingPathComponent:@"UnslopGroups" isDirectory:YES]
                          URLByAppendingPathComponent:group isDirectory:YES];
            [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
            return dir;
        }), method_getTypeEncoding(m));
    ULOG(@"app group fallback installed");
}
