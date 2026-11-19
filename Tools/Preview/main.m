// SPDX-License-Identifier: GPL-3.0-or-later
// Simulator host that opens the Unslop settings screen (see `make preview`).
#import <UIKit/UIKit.h>
#import "Unslop.h"
@interface AD : UIResponder <UIApplicationDelegate> @property UIWindow *window; @end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    UPrefsRegister();
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = UIColor.systemBackgroundColor;
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ UPresentSettings(); });
    return YES;
}
@end
int main(int c, char **v) { @autoreleasepool { return UIApplicationMain(c, v, nil, @"AD"); } }
