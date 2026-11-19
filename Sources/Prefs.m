// SPDX-License-Identifier: GPL-3.0-or-later
#import "Unslop.h"

static NSString *K(NSString *key) { return [@"unslop." stringByAppendingString:key]; }

void UPrefsRegister(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"ads", @"promos", @"typing",
                          @"tab.explore", @"tab.stories", @"tab.marketplace",
                          @"tab.chatgpt", @"tab.dating", @"tab.pay",
                          @"theme.native", @"theme.chat", @"theme.tint"])
        d[K(k)] = @YES;
    [NSUserDefaults.standardUserDefaults registerDefaults:d];
}

BOOL UPref(NSString *key) { return [NSUserDefaults.standardUserDefaults boolForKey:K(key)]; }

void UPrefSet(NSString *key, BOOL value) {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:K(key)];
}
