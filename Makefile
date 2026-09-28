NAME := StillCore
LOCAL ?=
WORKSPACE ?=
CONFIGURATION ?= Debug
DESTINATION ?= platform=macOS,arch=arm64
DERIVED_DATA := .build
XCODEBUILD_FLAGS := \
	-quiet -hideShellScriptEnvironment \
	ENABLE_CODE_COVERAGE=NO
DEVELOPMENT_TEAM ?=
ifneq ($(DEVELOPMENT_TEAM),)
    XCODEBUILD_FLAGS += DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM)
endif

ifneq ($(LOCAL),)
    WORKSPACE := $(NAME).local
    MACMON_XCFRAMEWORK_PATH := ../macmon/dist/CMacmon.xcframework
    export MACMON_XCFRAMEWORK_PATH
endif

XCODE_CONTAINER := -project $(NAME).xcodeproj
ifneq ($(WORKSPACE),)
    XCODE_CONTAINER := -workspace $(WORKSPACE).xcworkspace
endif

APP_PATH = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(NAME).app
APP_EXEC_PATH = $(APP_PATH)/Contents/MacOS/$(NAME)

.PHONY: help
help:
	@printf '%s\n' \
		'make app            Build $(NAME).app' \
		'LOCAL=1 make app    Build with local workspace and local macmon xcframework' \
		'make run            Build and run $(NAME) in this terminal' \
		'make open-app       Build and open $(NAME).app' \
		'make helpers-uninstall Build app and uninstall both helpers' \
		'make release        Build Release, create $(NAME).dmg, submit for notarization' \
		'  DEVELOPMENT_TEAM=... Team id for Developer ID signing' \
		'  NOTARY_PROFILE=... Keychain profile for notarytool (default: $(NOTARY_PROFILE))' \
		'make dmg            Build Release, create $(NAME).dmg suitable for local running (ad-hoc)' \
		'make profile        Build $(NAME) and launch xctrace Time Profiler' \
		'make benchmarks     Run charts benchmarks' \
		'make test           Build app and run automated checks without root' \
		'make install-hooks  Use repo-managed git hooks' \
		'make clean          Remove .build'


.PHONY: app
app:
	xcodebuild $(XCODE_CONTAINER) build \
	-scheme $(NAME) -configuration $(CONFIGURATION) \
	-destination '$(DESTINATION)' \
	-derivedDataPath $(DERIVED_DATA) \
	$(XCODEBUILD_FLAGS)

.PHONY: run
run: app
	$(APP_EXEC_PATH)

.PHONY: open-app
open-app: app
	open "$(APP_PATH)"

.PHONY: helpers-uninstall
helpers-uninstall: app
	"$(APP_EXEC_PATH)" --helpers-uninstall

.PHONY: benchmarks
benchmarks:
	swift run -c release --package-path Benchmarks Benchmarks \
		--warmup-iterations 3 --max-iterations 2000 --min-time 1 \
		--time-unit us --columns name,time,throughput,std,iterations

.PHONY: install-hooks
install-hooks:
	git config core.hooksPath .githooks

.PHONY: test
test: app
	xcrun swiftc -swift-version 6 -parse-as-library \
		-module-cache-path $(DERIVED_DATA)/ModuleCache.noindex \
		PowerMetricsShared/PowerMetricsProtocol.swift \
		PowerMetricsHelper/PowerMetricsEngine.swift \
		StillCore/HelperService.swift \
		StillCore/PowerMetricsService.swift \
		BatteryTrackingShared/BatterySession.swift \
		Tests/PowerMetricsChecks.swift \
		-o $(DERIVED_DATA)/PowerMetricsChecks
	$(DERIVED_DATA)/PowerMetricsChecks "$(APP_PATH)"
	/bin/zsh -c 'exec -a Contents/MacOS/PowerMetricsHelper "$$1" "$$2"' \
		-- "$(DERIVED_DATA)/PowerMetricsChecks" "$(APP_PATH)"

.PHONY: profile
PROFILE_TRACE ?= $(DERIVED_DATA)/$(NAME)-Time-Profiler.trace
PROFILE_TEMPLATE ?= Time Profiler
profile: CONFIGURATION=Release
profile: app
	rm -rf "$(PROFILE_TRACE)"
	@set -e; \
	"$(APP_EXEC_PATH)" & \
	app_pid=$$!; \
	echo "Profiling PID $$app_pid"; \
	xcrun xctrace record \
	--template "$(PROFILE_TEMPLATE)" \
	--output "$(PROFILE_TRACE)" \
	--attach "$$app_pid"; \
	open "$(PROFILE_TRACE)"

.PHONY: clean
clean:
	rm -rf "$(DERIVED_DATA)"
	rm -rf "./Benchmarks/.build"

# -------------------------------- dmg -------------------------------------------------
.PHONY: archive
_ARCHIVE_PATH = $(DERIVED_DATA)/$(NAME).xcarchive
_ARCHIVE_TEAM = $(shell plutil -extract ApplicationProperties.Team raw -o - "$(_ARCHIVE_PATH)/Info.plist" 2>/dev/null)
archive:
	rm -rf "$(_ARCHIVE_PATH)"
	xcodebuild $(XCODE_CONTAINER) archive \
		-scheme $(NAME) -configuration Release \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-archivePath "$(_ARCHIVE_PATH)" \
		$(XCODEBUILD_FLAGS)

.PHONY: export-app
EXPORT_DIR ?= .
EXPORT_METHOD ?= $(if $(_ARCHIVE_TEAM),debugging,mac-application)
_EXPORT_PLIST = $(DERIVED_DATA)/exportOptions.plist
export-app: archive
	mkdir -p "$(EXPORT_DIR)"
	rm -f "$(_EXPORT_PLIST)"
	plutil -create xml1 "$(_EXPORT_PLIST)"
	plutil -insert destination -string export "$(_EXPORT_PLIST)"
	plutil -insert method -string "$(EXPORT_METHOD)" "$(_EXPORT_PLIST)"
	plutil -insert stripSwiftSymbols -bool YES "$(_EXPORT_PLIST)"
	plutil -insert manageAppVersionAndBuildNumber -bool NO "$(_EXPORT_PLIST)"
	xcodebuild -exportArchive \
		-archivePath "$(_ARCHIVE_PATH)" \
		-exportPath "$(EXPORT_DIR)" \
		-exportOptionsPlist "$(_EXPORT_PLIST)"

.PHONY: _prepare-dmg-staging-dir
_prepare-dmg-staging-dir:
	rm -rf "$(DMG_STAGING_DIR)"
	mkdir -p "$(DMG_STAGING_DIR)"
	ln -s /Applications "$(DMG_STAGING_DIR)/Applications"

.PHONY: dmg
DMG_PATH = $(NAME).dmg
DMG_EXPORT_DIR = $(DERIVED_DATA)/export
DMG_STAGING_DIR = $(DERIVED_DATA)/dmg
dmg: EXPORT_DIR=$(DMG_EXPORT_DIR)
dmg: _prepare-dmg-staging-dir export-app
	cp -R "$(DMG_EXPORT_DIR)/$(NAME).app" "$(DMG_STAGING_DIR)/"
	rm -f "$(DMG_PATH)"
	hdiutil create -volname "$(NAME)" \
		-srcfolder "$(DMG_STAGING_DIR)" \
		-ov -format UDZO \
		"$(DMG_PATH)"

# -------------------------------- release ---------------------------------------------
.PHONY: _require-development-team
_require-development-team:
	@if [ -z "$(DEVELOPMENT_TEAM)" ]; then \
		echo ""; \
		echo "DEVELOPMENT_TEAM is required for make release."; \
		echo "Example: make release DEVELOPMENT_TEAM=5Q4AEAVS86"; \
		echo ""; \
		exit 1; \
	fi

.PHONY: _require-keychain-profile
_require-keychain-profile:
	@if xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1; then \
		:; \
	else \
		echo ""; \
		echo "Missing or invalid notarytool keychain profile: $(NOTARY_PROFILE)"; \
		echo ""; \
		echo "Create it once with:"; \
		echo "  xcrun notarytool store-credentials \"$(NOTARY_PROFILE)\" --apple-id \"<apple-id>\" --team-id \"$(DEVELOPMENT_TEAM)\""; \
		echo ""; \
		echo "notarytool will then prompt for the app-specific password and save it in Keychain."; \
		exit 1; \
	fi

.PHONY: release
NOTARY_PROFILE ?= $(NAME)-Notarization
NOTARY_FLAGS := \
	CODE_SIGN_IDENTITY="Developer ID Application" \
	CODE_SIGN_STYLE=Manual \
	CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
	RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION=NO \
	OTHER_CODE_SIGN_FLAGS="--timestamp"
release: EXPORT_METHOD=developer-id
release: XCODEBUILD_FLAGS += $(NOTARY_FLAGS)
release: _require-development-team _require-keychain-profile dmg
	xcrun notarytool submit "$(DMG_PATH)" \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait
	xcrun stapler staple "$(DMG_PATH)"
	xcrun stapler validate "$(DMG_PATH)"
	@echo "Release artifact: $(DMG_PATH)"
