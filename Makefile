SDK      := $(shell xcrun --sdk iphoneos --show-sdk-path)
OUT      := build/Unslop.dylib
MIN_IOS  := 16.4

all: $(OUT)

$(OUT): Sources/Unslop.m
	@mkdir -p build
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib -fobjc-arc -Wall \
	  -miphoneos-version-min=$(MIN_IOS) -isysroot $(SDK) \
	  -framework Foundation -framework UIKit -framework CoreGraphics \
	  -install_name @rpath/Unslop.dylib -o $@ $<
	@command -v ldid >/dev/null && ldid -S $@ || true

# make ipa IPA=path/to/decrypted.ipa
ipa: $(OUT)
	@test -n "$(IPA)" || (echo "usage: make ipa IPA=<decrypted.ipa>"; exit 1)
	python3 scripts/inject.py "$(IPA)" $(OUT) build/Viber-Unslop.ipa

clean:
	rm -rf build

.PHONY: all ipa clean
