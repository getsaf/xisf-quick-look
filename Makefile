XCODEBUILD = DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild
XCODEGEN   = xcodegen
LIBXISF    = vendor/libxisf/build/libXISF.a

.PHONY: all deps project build install clean reset-ql

all: build

# ── Build libxisf static library ──────────────────────────────
$(LIBXISF):
	mkdir -p vendor/libxisf/build
	cd vendor/libxisf/build && cmake .. \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_SHARED_LIBS=OFF \
		-DUSE_BUNDLED_ZLIB=OFF \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=13.3
	cd vendor/libxisf/build && make -j$$(sysctl -n hw.logicalcpu) XISF

deps: $(LIBXISF)

# ── Generate Xcode project ─────────────────────────────────────
project: $(LIBXISF)
	$(XCODEGEN) generate

# ── Build the app ──────────────────────────────────────────────
build: project
	$(XCODEBUILD) \
		-project XISFQuickLook.xcodeproj \
		-scheme XISFQuickLook \
		-configuration Release \
		-derivedDataPath build/DerivedData \
		build

# ── Install to /Applications ───────────────────────────────────
install: build
	@echo "Copying to /Applications..."
	cp -Rf build/DerivedData/Build/Products/Release/XISFQuickLook.app /Applications/
	@$(MAKE) reset-ql

# ── Restart Quick Look subsystem ──────────────────────────────
reset-ql:
	@echo "Resetting Quick Look..."
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f /Applications/XISFQuickLook.app 2>/dev/null || true
	qlmanage -r 2>/dev/null || true
	killall -HUP Finder 2>/dev/null || true

# ── Cleanup ────────────────────────────────────────────────────
clean:
	rm -rf build XISFQuickLook.xcodeproj

distclean: clean
	rm -rf vendor/libxisf/build
