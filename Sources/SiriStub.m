// SPDX-License-Identifier: GPL-3.0-or-later
// A development-signed build has no com.apple.developer.siri entitlement, but
// Viber checks Siri Shortcuts authorization anyway (after the push
// notification prompt). +[INPreferences siriAuthorizationStatus] and
// +[INPreferences requestSiriAuthorization:] raise
// NSInternalInconsistencyException without that entitlement, which crashes
// the whole app. Stub both to behave as if Siri is simply not authorized.
#import "Unslop.h"

void UInstallSiriStub(void) {
    Class c = NSClassFromString(@"INPreferences");
    if (!c) return;
    UReplace(c, NSSelectorFromString(@"siriAuthorizationStatus"), YES, ^NSInteger(id s) { return 0; });
    UReplace(c, NSSelectorFromString(@"requestSiriAuthorization:"), YES, ^(id s, void (^handler)(NSInteger)) {
        if (handler) handler(0);
    });
    ULOG(@"Siri entitlement stub installed");
}
