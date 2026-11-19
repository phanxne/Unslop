// SPDX-License-Identifier: GPL-3.0-or-later
// Unslop - runtime tweak for Viber iOS 29.6.0. No Substrate needed:
// plain ObjC runtime method replacement, so it works as a sideloaded dylib.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>

#define ULOG(fmt, ...) NSLog(@"[Unslop] " fmt, ##__VA_ARGS__)

// ---- config -------------------------------------------------------------
// Tabs whose provider/root class name matches any of these are removed.
static NSArray<NSString *> *BlockedTabNames(void) {
    return @[@"Explore", @"Shortica", @"Marketplace", @"ChatGPT", @"Dating", @"ViberPay"];
}
// Growthbook feature switchers (class-name substrings) forced to isEnabled=NO.
static NSArray<NSString *> *KilledSwitchers(void) {
    return @[@"BannerAdsPlatform", @"ChatListAdClickers", @"ChatListAdPosition",
             @"AdsBigNativeChatListPlacement", @"AdsChatListBigLayoutCapping",
             @"AdsChatListExtraRequestInSession", @"AdsMediaViewSmallPlacements",
             @"AdsDatingFeedPosition", @"AdsExploreRefresh", @"AdsSearchScreen",
             @"LensesAdsFeature", @"SearchChatGPTEntrypoint", @"SearchChatGPTResultsBanner"];
}
// ------------------------------------------------------------------------

static BOOL replaceMethod(Class c, SEL s, BOOL meta, id blk) {
    if (!c) return NO;
    Method m = meta ? class_getClassMethod(c, s) : class_getInstanceMethod(c, s);
    if (!m) { ULOG(@"missing %@ -%@", NSStringFromClass(c), NSStringFromSelector(s)); return NO; }
    Class target = meta ? object_getClass(c) : c;
    class_replaceMethod(target, s, imp_implementationWithBlock(blk), method_getTypeEncoding(m));
    return YES;
}

static BOOL nameHits(NSString *name, NSArray<NSString *> *needles) {
    for (NSString *n in needles) if ([name containsString:n]) return YES;
    return NO;
}

#pragma mark - Ads

static void hookAds(void) {
    for (NSString *cn in @[@"_TtC12ViberAdsCore26BaseChatListAdsManagerImpl",
                           @"_TtC12ViberAdsCore26MainChatListAdsManagerImpl",
                           @"_TtC12ViberAdsCore27BusinessInboxAdsManagerImpl"]) {
        Class c = NSClassFromString(cn);
        replaceMethod(c, @selector(isFeatureEnabled), NO, ^BOOL(id s) { return NO; });
        replaceMethod(c, NSSelectorFromString(@"isAdLoaded"), NO, ^BOOL(id s) { return NO; });
        replaceMethod(c, NSSelectorFromString(@"currentAdUpdates"), NO, ^id(id s) { return @{}; });
        replaceMethod(c, NSSelectorFromString(@"placeholderUpdates"), NO, ^id(id s) { return @{}; });
        replaceMethod(c, NSSelectorFromString(@"sendAdRequestIfNeededWithViewController:"), NO,
                      ^(id s, id vc) {});
    }
    // Any remaining ad views: collapse.
    for (NSString *cn in @[@"_TtC12ViberAdsCore10ListAdView", @"_TtC12ViberAdsCore13ListAdBigView"]) {
        Class c = NSClassFromString(cn);
        replaceMethod(c, @selector(didMoveToWindow), NO, ^(UIView *v) {
            v.hidden = YES; v.alpha = 0;
        });
        replaceMethod(c, @selector(sizeThatFits:), NO, ^CGSize(UIView *v, CGSize z) { return CGSizeZero; });
        replaceMethod(c, @selector(intrinsicContentSize), NO, ^CGSize(UIView *v) { return CGSizeZero; });
    }
    // Feature switchers for ad placements and ChatGPT upsells.
    unsigned int n = 0; Class *all = objc_copyClassList(&n);
    int hit = 0;
    for (unsigned int i = 0; i < n; i++) {
        NSString *name = NSStringFromClass(all[i]);
        if (![name hasSuffix:@"FeatureSwitcherImpl"] || !nameHits(name, KilledSwitchers())) continue;
        if (replaceMethod(all[i], NSSelectorFromString(@"isEnabled"), NO, ^BOOL(id s) { return NO; })) hit++;
    }
    free(all);
    ULOG(@"ads hooked, %d switchers off", hit);
}

#pragma mark - Promo banners / nags

static void hookPromos(void) {
    Class p = NSClassFromString(@"VIBRemoteBannerPresenter");
    replaceMethod(p, @selector(showBanner:animated:), YES, ^(id c, id b, BOOL a) {});
    replaceMethod(p, @selector(presentBannerView:withPresenter:animated:), YES, ^(id c, id v, id pr, BOOL a) {});
    Class f = NSClassFromString(@"_TtC11ViberChatUI22ChatGPTLoginFooterView");
    replaceMethod(f, @selector(didMoveToWindow), NO, ^(UIView *v) { v.hidden = YES; });
    ULOG(@"promos hooked");
}

#pragma mark - Tabs

static NSString *providerClassName(UIViewController *vc) {
    Class lazy = NSClassFromString(@"_TtC20ViberUIComponentsApp28LazyTabBarRootViewController");
    if (!lazy || ![vc isKindOfClass:lazy]) return nil;
    Ivar iv = class_getInstanceVariable(lazy, "tabBarItemProvider");
    if (!iv) return nil;
    void *ptr = *(void **)((char *)(__bridge void *)vc + ivar_getOffset(iv));
    if (!ptr || ((uintptr_t)ptr & 7) || malloc_size(ptr) == 0) return nil;
    Class k = object_getClass((__bridge id)ptr);
    return k ? NSStringFromClass(k) : nil;
}

static BOOL tabBlocked(UIViewController *vc) {
    UIViewController *root = vc;
    if ([vc isKindOfClass:UINavigationController.class])
        root = ((UINavigationController *)vc).viewControllers.firstObject ?: vc;
    NSString *a = NSStringFromClass(root.class);
    NSString *b = providerClassName(vc) ?: providerClassName(root) ?: @"";
    return nameHits(a, BlockedTabNames()) || nameHits(b, BlockedTabNames());
}

static void hookTabs(void) {
    Class tb = UITabBarController.class;
    Method m = class_getInstanceMethod(tb, @selector(setViewControllers:animated:));
    if (!m) return;
    void (*orig)(id, SEL, NSArray *, BOOL) = (void *)method_getImplementation(m);
    class_replaceMethod(tb, @selector(setViewControllers:animated:), imp_implementationWithBlock(
        ^(UITabBarController *s, NSArray<UIViewController *> *vcs, BOOL a) {
            NSArray *out = vcs;
            if ([NSStringFromClass(s.class) containsString:@"RotatableTabBarController"]) {
                NSMutableArray *keep = [NSMutableArray array];
                for (UIViewController *vc in vcs) {
                    if (tabBlocked(vc)) ULOG(@"drop tab %@", NSStringFromClass(vc.class));
                    else [keep addObject:vc];
                }
                if (keep.count >= 2) out = keep;   // never strip to nothing
            }
            orig(s, @selector(setViewControllers:animated:), out, a);
        }), method_getTypeEncoding(m));
    ULOG(@"tabs hooked");
}

#pragma mark - Incoming typing indicators (display only)

static void hookTyping(void) {
    Class c = NSClassFromString(@"_TtC11ViberChatUI17TypingManagerImpl");
    replaceMethod(c, NSSelectorFromString(@"handleMemberIsTypingWithMemberID:isSecret:isDating:isActive:deviceName:activityType:"), NO,
                  ^(id s, id m, BOOL a, BOOL b, BOOL d, id n, long long t) {});
    replaceMethod(c, NSSelectorFromString(@"handleMemberIsTypingWithMemberID:isSecret:isDating:isActive:deviceName:displayTime:activityType:"), NO,
                  ^(id s, id m, BOOL a, BOOL b, BOOL d, id n, double dt, long long t) {});
    replaceMethod(c, NSSelectorFromString(@"handleGroupMemberIsTypingWithMemberID:groupID:isActive:deviceName:activityType:"), NO,
                  ^(id s, id m, unsigned long long g, BOOL a, id n, long long t) {});
    ULOG(@"typing indicators hooked");
}

#pragma mark - entry

static void installAll(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hookTabs(); hookAds(); hookPromos(); hookTyping(); });
}

__attribute__((constructor)) static void init(void) {
    installAll();
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
        object:nil queue:nil usingBlock:^(NSNotification *n) { installAll(); }];
}
