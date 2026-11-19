// SPDX-License-Identifier: GPL-3.0-or-later
// Experimental: make Viber take its iPad / secondary-device path on an iPhone,
// so a duplicate install can link to the main Viber as a companion device.
#import "Unslop.h"
#import <objc/runtime.h>

void UInstallCompanionMode(void) {
    if (!UPref(@"companion")) return;
    UReplace(UIDevice.class, @selector(userInterfaceIdiom), NO, ^UIUserInterfaceIdiom(UIDevice *d) {
        return UIUserInterfaceIdiomPad;
    });
    UReplace(UIDevice.class, @selector(model), NO, ^NSString *(UIDevice *d) { return @"iPad"; });
    ULOG(@"companion mode: reporting iPad");
}

#pragma mark - hardware model (dyld interposing)

#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <string.h>

#define FAKE_MACHINE "iPad13,1"

typedef struct { const void *replacement; const void *replacee; } UInterpose;
#define UINTERPOSE(r, o) \
    __attribute__((used)) static const UInterpose _interpose_##r \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&r, (const void *)(unsigned long)&o }

static BOOL companionOn(void) {
    static int on = -1;
    if (on < 0) on = [NSUserDefaults.standardUserDefaults boolForKey:@"unslop.companion"] ? 1 : 0;
    return on == 1;
}

static int u_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int r = sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (r == 0 && name && companionOn() && oldp && oldlenp &&
        (strcmp(name, "hw.machine") == 0) && *oldlenp >= sizeof(FAKE_MACHINE)) {
        strcpy((char *)oldp, FAKE_MACHINE);
        *oldlenp = sizeof(FAKE_MACHINE);
        static int logged; if (!logged++) ULOG(@"spoofed hw.machine via sysctlbyname");
    }
    return r;
}

static int u_uname(struct utsname *u) {
    int r = uname(u);
    if (r == 0 && companionOn()) {
        strlcpy(u->machine, FAKE_MACHINE, sizeof(u->machine));
        static int logged; if (!logged++) ULOG(@"spoofed uname machine");
    }
    return r;
}

static int u_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int r = sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (r == 0 && companionOn() && namelen == 2 && name[0] == CTL_HW && name[1] == HW_MACHINE &&
        oldp && oldlenp && *oldlenp >= sizeof(FAKE_MACHINE)) {
        strcpy((char *)oldp, FAKE_MACHINE);
        *oldlenp = sizeof(FAKE_MACHINE);
        static int logged; if (!logged++) ULOG(@"spoofed hw.machine via sysctl");
    }
    return r;
}

UINTERPOSE(u_sysctlbyname, sysctlbyname);
UINTERPOSE(u_uname, uname);
UINTERPOSE(u_sysctl, sysctl);
