APP_NAME = WakeMeUp
BUILD_DIR = .build/release
APP_BUNDLE = build/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources

.PHONY: all build release bundle run test clean

all: build

build:
	swift build

release:
	swift build -c release

test:
	swift test

run: build
	swift run WakeMeUp

bundle: release
	@echo "Creating $(APP_BUNDLE)..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS) $(RESOURCES)
	@cp $(BUILD_DIR)/$(APP_NAME) $(MACOS)/$(APP_NAME)
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n    <key>CFBundleExecutable</key>\n    <string>WakeMeUp</string>\n    <key>CFBundleIdentifier</key>\n    <string>com.wakemeup.mac</string>\n    <key>CFBundleName</key>\n    <string>WakeMeUp</string>\n    <key>CFBundlePackageType</key>\n    <string>APPL</string>\n    <key>CFBundleShortVersionString</key>\n    <string>1.0.0</string>\n    <key>LSMinimumSystemVersion</key>\n    <string>13.0</string>\n    <key>LSUIElement</key>\n    <true/>\n    <key>NSHighResolutionCapable</key>\n    <true/>\n</dict>\n</plist>\n' > $(CONTENTS)/Info.plist
	@codesign --force --deep --sign - --identifier "com.wakemeup.mac" $(APP_BUNDLE)
	@echo "Successfully packaged and signed $(APP_BUNDLE)!"
	@echo "You can launch it with: open $(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf build
