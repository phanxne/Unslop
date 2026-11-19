# Unslop

Cleans up Viber on iOS: no ads, no bloat tabs, no promo nags.

Unslop is a small runtime tweak (a plain dylib, no Substrate or jailbreak needed) that you inject into a decrypted Viber IPA and sign with your own certificate.

> Unaffiliated with Viber or Rakuten. Contains no Viber code. For personal use on your own device. Use at your own risk; modified apps may break at any update, and Viber's terms may restrict modification.

## What it does

| Area | Effect |
|---|---|
| Ads | Disables chat-list, business-inbox and in-view ads, and the ad-placement feature flags |
| Tabs | Hides Explore, Stories, Marketplace, ChatGPT, Dating and Viber Pay tabs. Chats, Calls and More stay |
| Promos | Blocks remote promo banners and the ChatGPT login footer |
| Typing | Hides incoming typing / recording indicators (display only) |

Not included on purpose: hiding *your* typing or seen status. Viber ships that as a Viber Plus feature, and Unslop does not bypass paid features.

Tested target: Viber 29.6.0 (iOS 16.4+). Other versions may work, but class names can change.

## Build

Requires macOS with Xcode. `ldid` is optional.

```bash
make            # builds build/Unslop.dylib
```

## Install

You need a decrypted Viber IPA (obtain it from your own app install) and a way to sign for your device.

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python scripts/inject.py Viber.ipa build/Unslop.dylib build/Viber-Unslop.ipa
```

Sign `build/Viber-Unslop.ipa` with your own certificate and install it (Sideloadly, your own tooling, etc.).

## Debug

Unslop logs with the prefix `[Unslop]` in the device console. A line like `missing <Class> -<selector>` means a hook target was not found in your Viber version.

## How it works

On load, Unslop replaces methods through the Objective-C runtime:

- ad manager getters (`isFeatureEnabled`, `currentAdUpdates`, ...) return empty/off
- `FeatureSwitcherImpl.isEnabled` is forced off for ad-placement flags
- `UITabBarController setViewControllers:animated:` drops blocked tabs, matched by tab provider class name
- the remote-banner presenter and typing-manager handlers become no-ops

All targets live in `Sources/Unslop.m`; edit the lists at the top to change behavior.

## Contributing

Viber updates rename things. If a hook breaks, open an issue with your Viber version and the `[Unslop]` log lines, or send a PR updating the class names. Do not attach Viber binaries or class dumps.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
