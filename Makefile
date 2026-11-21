SDK      := $(shell xcrun --sdk iphoneos --show-sdk-path)
OUT      := build/Unslop.dylib
MIN_IOS  := 16.4

all: $(OUT)

SRC := $(wildcard Sources/*.m)

$(OUT): $(SRC) Sources/Unslop.h
	@mkdir -p build
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib -fobjc-arc -Wall \
	  -miphoneos-version-min=$(MIN_IOS) -isysroot $(SDK) \
	  -framework Foundation -framework UIKit -framework CoreGraphics -framework UniformTypeIdentifiers -lsqlite3 \
	  -install_name @rpath/Unslop.dylib -o $@ $(SRC)
	@command -v ldid >/dev/null && ldid -S $@ || true

# make ipa IPA=path/to/decrypted.ipa
ipa: $(OUT)
	@test -n "$(IPA)" || (echo "usage: make ipa IPA=<decrypted.ipa>"; exit 1)
	python3 scripts/inject.py "$(IPA)" $(OUT) build/Viber-Unslop.ipa

clean:
	rm -rf build

.PHONY: all ipa clean

# Open the settings screen in the iOS Simulator (needs a booted simulator).
preview:
	@mkdir -p build/Preview.app
	xcrun -sdk iphonesimulator clang -arch arm64 -fobjc-arc -mios-simulator-version-min=16.4 \
	  -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path) -ISources \
	  -framework UIKit -framework Foundation -framework CoreGraphics -framework UniformTypeIdentifiers -o build/Preview.app/Preview \
	  Tools/Preview/main.m Sources/*.m
	@printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Preview</string><key>CFBundleIdentifier</key><string>dev.unslop.preview</string><key>CFBundlePackageType</key><string>APPL</string><key>UILaunchScreen</key><dict/></dict></plist>' > build/Preview.app/Info.plist
	codesign -s - --force build/Preview.app
	xcrun simctl install booted build/Preview.app
	xcrun simctl launch booted dev.unslop.preview

.PHONY: preview

# Round-trip test of chat backup/restore in a booted iOS Simulator; prints the result.
test-backup:
	@mkdir -p build/BackupTest.app
	xcrun -sdk iphonesimulator clang -arch arm64 -fobjc-arc -mios-simulator-version-min=16.4 \
	  -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path) -ISources \
	  -framework UIKit -framework Foundation -framework CoreGraphics -framework UniformTypeIdentifiers \
	  -o build/BackupTest.app/BackupTest Tools/BackupTest/main.m Sources/*.m
	@printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>BackupTest</string><key>CFBundleIdentifier</key><string>dev.unslop.backuptest</string><key>CFBundlePackageType</key><string>APPL</string><key>UILaunchScreen</key><dict/></dict></plist>' > build/BackupTest.app/Info.plist
	codesign -s - --force build/BackupTest.app
	@rm -f /tmp/ubk.txt
	xcrun simctl install booted build/BackupTest.app
	xcrun simctl launch booted dev.unslop.backuptest >/dev/null
	@sleep 6; cat /tmp/ubk.txt

.PHONY: test-backup
