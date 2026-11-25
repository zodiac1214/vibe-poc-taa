ARCHS   ?= -arch arm64 -arch x86_64
CFLAGS  ?= -O2 -g -Wall -Wextra -Wno-unused-parameter
CFLAGS  += -fobjc-arc -mmacosx-version-min=13.0 $(ARCHS)
BUILD   := build

DYLIB   := $(BUILD)/libtaa_inject.dylib
TESTAPP := $(BUILD)/taa_testapp

all: $(DYLIB) $(TESTAPP)

$(BUILD):
	mkdir -p $@

$(BUILD)/taa_shaders.inc: src/taa.metal | $(BUILD)
	cd src && xxd -i taa.metal > ../$@

$(DYLIB): src/taa_inject.m $(BUILD)/taa_shaders.inc
	clang $(CFLAGS) -I$(BUILD) -dynamiclib -install_name @rpath/libtaa_inject.dylib \
	  -framework Foundation -framework Metal -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -weak_framework MetalFX -o $@ $<
	codesign -f -s - $@

$(TESTAPP): test/testapp.m | $(BUILD)
	clang $(CFLAGS) -framework Cocoa -framework Metal -framework QuartzCore -o $@ $<
	codesign -f -s - $@

# Optional: offline-compile the shaders to catch errors (needs Xcode's Metal toolchain).
check-shaders: | $(BUILD)
	xcrun -sdk macosx metal -c src/taa.metal -o $(BUILD)/taa.air

# Quick end-to-end run: test app renders 960x540, injector upscales to native and dumps PNGs.
demo: all
	TAA_LOG=1 TAA_DUMP_FRAME=90 TAA_DUMP_PREFIX=$(BUILD)/demo \
	  DYLD_INSERT_LIBRARIES=$(abspath $(DYLIB)) $(TESTAPP) --frames 120

clean:
	rm -rf $(BUILD)

.PHONY: all clean check-shaders demo
