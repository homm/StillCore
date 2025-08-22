# Directory layout (put your swift file next to this Makefile):
#   ./Sources/MenuStats/main.swift   <-- your Swift code from the other canvas
#   ./Makefile                        <-- this file
#   ./Info.plist                      <-- minimal plist (see below)
#
# Usage:
#   make run        # build .app and open it
#   make build      # just build the .app
#   make clean
#
# Notes:
# - Requires Command Line Tools (xcode-select --install) or Xcode.
# - Ad-hoc codesigns the app so it launches under typical Gatekeeper settings.
# - Set BUNDLE_ID, APP_NAME as you like.

APP_NAME := MenuStats
BUNDLE_ID := com.example.menustats
SWIFT_SOURCES := $(shell find Sources -name '*.swift')
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
BIN := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
PLIST := Info.plist

# Detect arch + SDK
ARCH := arm64
SDK := macosx
MACOS_MIN := 13.0  # bump if needed

SWIFTC := swiftc
SWIFT_FLAGS := -O -gnone -target $(ARCH)-apple-macos15.0 -sdk $(shell xcrun --sdk $(SDK) --show-sdk-path) \
	-parse-as-library \
	-framework Cocoa -framework SwiftUI -framework Combine

all: build

$(BIN): $(SWIFT_SOURCES) $(PLIST)
	@mkdir -p $(dir $(BIN)) $(APP_DIR)/Contents/Resources
	@echo "[1/3] swiftc -> binary"
	$(SWIFTC) $(SWIFT_FLAGS) -o $(BIN) $(SWIFT_SOURCES)
	@echo "[2/3] write Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" $(PLIST) >/dev/null 2>&1 || true
	@/usr/libexec/PlistBuddy -c "Set :CFBundleName $(APP_NAME)" $(PLIST) >/dev/null 2>&1 || true
	@cp $(PLIST) $(APP_DIR)/Contents/Info.plist
	@echo "[3/3] codesign (ad-hoc)"
	@codesign --force --deep --sign - --timestamp=none $(APP_DIR)

build: $(BIN)
	@echo "Built: $(APP_DIR)"

run: build
	killall $(APP_NAME) | true
	@open $(APP_DIR)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all build run clean

