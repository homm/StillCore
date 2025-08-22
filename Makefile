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

APP_NAME  := MenuStats
BT_NAME   := battery_tracker
BUILD_DIR := build
APP_DIR   := $(BUILD_DIR)/$(APP_NAME).app
APP_BIN   := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
BT_BIN    := $(APP_DIR)/Contents/MacOS/$(BT_NAME)

all: build


BIN_ARM   := $(BUILD_DIR)/$(APP_NAME).arm64
BIN_X86   := $(BUILD_DIR)/$(APP_NAME).x86_64
MACOS_MIN := 13.0
SWIFT_FLAGS := -O -gnone -parse-as-library
SWIFT_SOURCES := $(shell find Sources/MenuStats -name '*.swift')
PLIST := Info.plist
$(APP_BIN): $(SWIFT_SOURCES)
	@mkdir -p $(dir $@) $(APP_DIR)/Contents/Resources
	@echo "[1/3] $(APP_NAME) (arm64)"
	swiftc $(SWIFT_FLAGS) -target arm64-apple-macos$(MACOS_MIN) -o $(BIN_ARM) $(SWIFT_SOURCES)
	@echo "[2/3] $(APP_NAME) (x86_64)"
	swiftc $(SWIFT_FLAGS) -target x86_64-apple-macos$(MACOS_MIN) -o $(BIN_X86) $(SWIFT_SOURCES)
	@echo "[3/3] lipo -> universal2"
	@lipo -create -output $@ $(BIN_ARM) $(BIN_X86)
	

CFLAGS := -O2 -Wall -Wextra -std=c11 -framework IOKit -framework CoreFoundation
$(BT_BIN): Sources/$(BT_NAME).c
	@echo "[1/3] $(BT_NAME) (arm64)"
	clang $(CFLAGS) -arch arm64 $< -o $(BUILD_DIR)/$(BT_NAME).arm64
	@echo "[2/3] $(BT_NAME) (x86_64)"
	clang $(CFLAGS) -arch x86_64 $< -o $(BUILD_DIR)/$(BT_NAME).x86_64
	@echo "[3/3] lipo -> universal2"
	@lipo -create -output $@ $(BUILD_DIR)/$(BT_NAME).arm64 $(BUILD_DIR)/$(BT_NAME).x86_64


$(APP_DIR): $(APP_BIN) $(BT_BIN) $(PLIST)
	@echo "[4/4] codesign"
	@cp $(PLIST) $(APP_DIR)/Contents/Info.plist
	@codesign --force --deep --sign - --timestamp=none $(APP_DIR)

build: $(APP_DIR)
	@echo "Built: $(APP_DIR)"

run: build
	killall $(APP_NAME) | true
	@open $(APP_DIR)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all build run clean

