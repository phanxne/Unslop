// SPDX-License-Identifier: GPL-3.0-or-later
// Native look: system bars, system accent, system colors/fonts on the chat list.
#import "Unslop.h"
#import <objc/runtime.h>

static void styleLabel(UILabel *l, UIFontWeight w, UIColor *c) {
    if (![l isKindOfClass:UILabel.class]) return;
    // Keep Viber's point size so its manual layout does not clip; swap family + color.
    l.font = [UIFont systemFontOfSize:l.font.pointSize weight:w];
    if (c) l.textColor = c;
    l.adjustsFontForContentSizeCategory = NO;
}

static id kv(id o, NSString *k) { return [o respondsToSelector:NSSelectorFromString(k)] ? [o valueForKey:k] : nil; }

static void restyleChatCell(UITableViewCell *cell) {
    UIColor *bg = UIColor.systemBackgroundColor;
    cell.backgroundColor = bg;
    cell.contentView.backgroundColor = bg;
    styleLabel(kv(cell, @"nameLabel"), UIFontWeightSemibold, UIColor.labelColor);
    styleLabel(kv(cell, @"messageTextLabel"), UIFontWeightRegular, UIColor.secondaryLabelColor);
    styleLabel(kv(cell, @"dateLabel"), UIFontWeightRegular, UIColor.secondaryLabelColor);
}

static void hookChatList(void) {
    Class c = NSClassFromString(@"VIBChatsListCell");
    SEL s = NSSelectorFromString(@"updateMessageTextDataAndAppearance");
    Method m = class_getInstanceMethod(c, s);
    if (!m) { ULOG(@"missing VIBChatsListCell updateMessageTextDataAndAppearance"); return; }
    void (*orig)(id, SEL) = (void *)method_getImplementation(m);
    class_replaceMethod(c, s, imp_implementationWithBlock(^(UITableViewCell *self_) {
        orig(self_, s);
        restyleChatCell(self_);
    }), method_getTypeEncoding(m));
}

static void applyBars(void) {
    UINavigationBarAppearance *n = UINavigationBarAppearance.new;
    [n configureWithDefaultBackground];
    UINavigationBar.appearance.standardAppearance = n;
    UINavigationBar.appearance.scrollEdgeAppearance = n;
    UINavigationBar.appearance.compactAppearance = n;

    UITabBarAppearance *t = UITabBarAppearance.new;
    [t configureWithDefaultBackground];
    UITabBar.appearance.standardAppearance = t;
    UITabBar.appearance.scrollEdgeAppearance = t;
}

static void applyTint(UIWindow *w) { w.tintColor = UIColor.systemBlueColor; }

static void hookWindowTint(void) {
    Class c = UIWindow.class;
    SEL s = @selector(becomeKeyWindow);
    Method m = class_getInstanceMethod(c, s);
    void (*orig)(id, SEL) = (void *)method_getImplementation(m);
    class_replaceMethod(c, s, imp_implementationWithBlock(^(UIWindow *w) {
        orig(w, s);
        applyTint(w);
    }), method_getTypeEncoding(m));
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:UIWindowScene.class])
            for (UIWindow *w in ((UIWindowScene *)sc).windows) applyTint(w);
}

void UInstallTheme(void) {
    if (UPref(@"theme.native")) { applyBars(); hookChatList(); }
    if (UPref(@"theme.tint")) hookWindowTint();
    ULOG(@"theme installed (native=%d tint=%d)", UPref(@"theme.native"), UPref(@"theme.tint"));
}
