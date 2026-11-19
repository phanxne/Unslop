// SPDX-License-Identifier: GPL-3.0-or-later
// Native settings screen: inset-grouped list, system switches, Dynamic Type.
#import "Unslop.h"
#import <objc/runtime.h>

static NSString *const kRepoURL = @"https://github.com/phanxne/Unslop";

@interface USection : NSObject
@property NSString *title, *footer;
@property NSArray<NSDictionary *> *rows;   // @{title, detail, key} or @{title, action}
@end
@implementation USection @end

static USection *sec(NSString *t, NSString *f, NSArray *rows) {
    USection *s = USection.new; s.title = t; s.footer = f; s.rows = rows; return s;
}
static NSDictionary *tog(NSString *t, NSString *d, NSString *k) { return @{@"title": t, @"detail": d ?: @"", @"key": k}; }

@interface USettingsController : UITableViewController
@property NSArray<USection *> *sections;
@end

@implementation USettingsController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"Unslop";
        self.sections = @[
            sec(@"Clean up", nil, @[
                tog(@"Remove ads", @"Chat list, inbox and in-view ads", @"ads"),
                tog(@"Remove promos", @"Banners and upsell nags", @"promos"),
                tog(@"Hide typing indicators", @"Incoming typing and recording", @"typing")]),
            sec(@"Tabs", @"Turn a tab off to remove it from the tab bar.", @[
                tog(@"Explore", nil, @"tab.explore"),
                tog(@"Stories", nil, @"tab.stories"),
                tog(@"Marketplace", nil, @"tab.marketplace"),
                tog(@"ChatGPT", nil, @"tab.chatgpt"),
                tog(@"Dating", nil, @"tab.dating"),
                tog(@"Viber Pay", nil, @"tab.pay")]),
            sec(@"Appearance", @"Uses system colors, fonts and bars so Viber follows Light, Dark and Dynamic Type.", @[
                tog(@"Native look", @"System bars and chat list styling", @"theme.native"),
                tog(@"System accent", @"Replace Viber purple with system blue", @"theme.tint")]),
            sec(nil, @"Changes apply the next time Viber launches.", @[
                @{@"title": @"Quit Viber", @"action": @"quit"}]),
            sec(@"About", nil, @[
                @{@"title": @"Version", @"detail": @"1.0"},
                @{@"title": @"Source code", @"action": @"source"}]),
        ];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(done)];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return self.sections.count; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.sections[s].rows.count; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return self.sections[s].title; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s { return self.sections[s].footer; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *row = self.sections[ip.section].rows[ip.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
    cfg.text = row[@"title"];
    NSString *detail = row[@"detail"];
    if (detail.length) { cfg.secondaryText = detail; cfg.secondaryTextProperties.color = UIColor.secondaryLabelColor; }
    NSString *key = row[@"key"], *action = row[@"action"];
    if (key) {
        UISwitch *sw = UISwitch.new;
        sw.on = UPref(key);
        [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
            UPrefSet(key, sw.isOn);
            [[UISelectionFeedbackGenerator new] selectionChanged];
        }] forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessibilityLabel = row[@"title"];
    } else if ([action isEqual:@"quit"]) {
        cfg.textProperties.color = UIColor.systemRedColor;
        cfg.textProperties.alignment = UIListContentTextAlignmentCenter;
    } else if ([action isEqual:@"source"]) {
        cfg.textProperties.color = self.view.tintColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.contentConfiguration = cfg;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *action = self.sections[ip.section].rows[ip.row][@"action"];
    if ([action isEqual:@"source"]) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:kRepoURL] options:@{} completionHandler:nil];
    } else if ([action isEqual:@"quit"]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Quit Viber?"
            message:@"Viber closes now. Open it again to apply your changes."
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Quit" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *x) { exit(0); }]];
        [self presentViewController:a animated:YES completion:nil];
    }
}
@end

#pragma mark - presentation

static UIViewController *topController(void) {
    UIWindow *w = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive)
            for (UIWindow *x in ((UIWindowScene *)s).windows) if (x.isKeyWindow) w = x;
    UIViewController *v = w.rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

void UPresentSettings(void) {
    UIViewController *top = topController();
    BOOL alreadyOpen = [top isKindOfClass:UINavigationController.class] &&
        [((UINavigationController *)top).viewControllers.firstObject isKindOfClass:USettingsController.class];
    if (!top || alreadyOpen) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:USettingsController.new];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [[UIImpactFeedbackGenerator new] impactOccurred];
    [top presentViewController:nav animated:YES completion:nil];
}

@interface UGestureTarget : NSObject
+ (instancetype)shared;
- (void)handle:(UILongPressGestureRecognizer *)g;
@end
@implementation UGestureTarget
+ (instancetype)shared { static UGestureTarget *t; static dispatch_once_t o; dispatch_once(&o, ^{ t = UGestureTarget.new; }); return t; }
- (void)handle:(UILongPressGestureRecognizer *)g { if (g.state == UIGestureRecognizerStateBegan) UPresentSettings(); }
@end

// Long-press the tab bar to open Unslop.
void UInstallSettingsGesture(UITabBarController *tbc) {
    UITabBar *bar = tbc.tabBar;
    for (UIGestureRecognizer *g in bar.gestureRecognizers) if ([g.name isEqual:@"unslop"]) return;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:UGestureTarget.shared action:@selector(handle:)];
    lp.minimumPressDuration = 1.0;
    lp.name = @"unslop";
    lp.cancelsTouchesInView = NO;
    [bar addGestureRecognizer:lp];
}
