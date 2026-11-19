// SPDX-License-Identifier: GPL-3.0-or-later
#import <UIKit/UIKit.h>

#define ULOG(fmt, ...) NSLog(@"[Unslop] " fmt, ##__VA_ARGS__)

// Preferences (all default ON). Stored in standard defaults under "unslop.<key>".
void UPrefsRegister(void);
BOOL UPref(NSString *key);
void UPrefSet(NSString *key, BOOL value);

// Runtime method replacement helper (instance or class method).
BOOL UReplace(Class c, SEL s, BOOL meta, id block);

// Settings screen.
void UPresentSettings(void);
void UInstallSettingsGesture(UITabBarController *tbc);

// Native look.
void UInstallTheme(void);
