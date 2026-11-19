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


#pragma mark - Chat bubbles and input field

// Viber's palette -> native. Decided by the incoming color so Viber's own
// light/dark choice is respected: saturated (accent) -> system blue, light
// neutral -> light gray, dark neutral -> dark gray.
UIColor *UMapBubbleColor(UIColor *c) {
    if (![c isKindOfClass:UIColor.class]) return c;
    CGFloat h, sat, b, a;
    if (![c getHue:&h saturation:&sat brightness:&b alpha:&a]) {
        CGFloat w; if (![c getWhite:&w alpha:&a]) return c;
        sat = 0; b = w;
    }
    if (a < 0.1) return c;
    if (sat > 0.35) return [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:a];
    if (b > 0.5)    return [UIColor colorWithWhite:0.91 alpha:a];
    return [UIColor colorWithWhite:0.17 alpha:a];
}

static void hookChat(void) {
    Class bs = NSClassFromString(@"_TtC21ViberChatUIInterfaces21BubbleBackgroundStyle");
    Method solid = class_getClassMethod(bs, NSSelectorFromString(@"solidWith:"));
    if (solid) {
        id (*origSolid)(id, SEL, id) = (void *)method_getImplementation(solid);
        SEL solidSel = NSSelectorFromString(@"solidWith:");
        UReplace(bs, solidSel, YES, ^id(Class cls, id color) {
            return origSolid(cls, solidSel, UMapBubbleColor(color));
        });
        SEL gradSel = NSSelectorFromString(@"gradientWithColors:startPoint:endPoint:locations:");
        Method grad = class_getClassMethod(bs, gradSel);
        if (grad) {
            id (*origGrad)(id, SEL, NSArray *, CGPoint, CGPoint, id) = (void *)method_getImplementation(grad);
            UReplace(bs, gradSel, YES, ^id(Class cls, NSArray *colors, CGPoint a, CGPoint b, id loc) {
                if ([colors.firstObject isKindOfClass:UIColor.class])
                    return origSolid(cls, solidSel, UMapBubbleColor(colors.firstObject));  // flat, not gradient
                return origGrad(cls, gradSel, colors, a, b, loc);
            });
        }
    } else ULOG(@"missing BubbleBackgroundStyle +solidWith:");

    // Borderless bubbles.
    UReplace(NSClassFromString(@"VIBBubbleShapeHelper"),
             NSSelectorFromString(@"shouldDrawBorderOnBubbleForConversationUIStyle:"), YES,
             ^BOOL(Class c, unsigned long long style) { return NO; });
    // Rounded, capsule-style input field (Viber's own alternate design).
    UReplace(NSClassFromString(@"VIBMessageInputField"), NSSelectorFromString(@"isRoundedDesign"), NO,
             ^BOOL(id s) { return YES; });
    ULOG(@"chat styling hooked");
}

void UInstallTheme(void) {
    if (UPref(@"theme.native")) { applyBars(); hookChatList(); }
    if (UPref(@"theme.chat")) hookChat();
    if (UPref(@"theme.tint")) hookWindowTint();
    ULOG(@"theme installed (native=%d tint=%d)", UPref(@"theme.native"), UPref(@"theme.tint"));
}
