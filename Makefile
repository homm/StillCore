NAME := StillCore
LOCAL ?=
WORKSPACE ?=
CONFIGURATION ?= Debug
DERIVED_DATA := .build
XCODEBUILD_FLAGS := \
	-quiet -hideShellScriptEnvironment \
	ENABLE_CODE_COVERAGE=NO

ifneq ($(LOCAL),)
    WORKSPACE := $(NAME).local
    MACMON_XCFRAMEWORK_PATH := ../macmon/dist/CMacmon.xcframework
    export MACMON_XCFRAMEWORK_PATH
endif

XCODE_CONTAINER := -project $(NAME).xcodeproj
ifneq ($(WORKSPACE),)
    XCODE_CONTAINER := -workspace $(WORKSPACE).xcworkspace
endif

PRODUCTS_DIR = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)
APP_PATH = $(PRODUCTS_DIR)/$(NAME).app
APP_EXEC_PATH = $(APP_PATH)/Contents/MacOS/$(NAME)
HELPER_LABEL = com.github.homm.StillCore.BatteryTracker
HELPER_STATE_PATH = $(HOME)/Library/Application Support/com.github.homm.StillCore/battery-tracker-state.json
PROFILE_TRACE ?= $(DERIVED_DATA)/$(NAME)-Time-Profiler.trace
PROFILE_TEMPLATE ?= Time Profiler

.PHONY: help app run open-app helper-restart benchmarks profile clean

help:
	@printf '%s\n' \
		'make app            Build $(NAME).app' \
		'LOCAL=1 make app    Build with local workspace and local macmon xcframework' \
		'WORKSPACE=StillCore.local make app Build with local workspace override' \
		'make run            Build and run $(NAME) in this terminal' \
		'make open-app       Build and open $(NAME).app' \
		'make helper-restart Build app and restart battery helper' \
		'make profile        Build $(NAME) and launch xctrace Time Profiler' \
		'make benchmarks     Run charts benchmarks' \
		'make clean          Remove .build'

app:
	xcodebuild $(XCODE_CONTAINER) build \
	-scheme $(NAME) -configuration $(CONFIGURATION) \
	-derivedDataPath $(DERIVED_DATA) \
	$(XCODEBUILD_FLAGS)

run: app
	$(APP_EXEC_PATH)

open-app: app
	open "$(APP_PATH)"

helper-restart: app
	rm -f "$(HELPER_STATE_PATH)"
	@echo "Restarting helper..."
	@if launchctl print "gui/$$(id -u)/$(HELPER_LABEL)" >/dev/null 2>&1; then \
		launchctl kickstart -k "gui/$$(id -u)/$(HELPER_LABEL)"; \
		echo "Helper restarted."; \
	else \
		echo "Helper is not registered in launchd. Start it from the StillCore UI."; \
		exit 1; \
	fi

benchmarks:
	swift run -c release --package-path Benchmarks Benchmarks \
		--time-unit us --columns name,time,throughput,std,iterations

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

clean:
	rm -rf "$(DERIVED_DATA)"
	rm -rf "./Benchmarks/.build"
