APP_NAME    := Tiles
APP_DIR     := build/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications/$(APP_NAME).app
DATA_DIR    ?= $(HOME)/Library/Application Support/$(APP_NAME)
LOG_FILE    := $(DATA_DIR)/tiles.log
ID          ?=

.PHONY: all build install stop start restart test logs restore save diagnose

all: build

build:
	@./build_app.sh

install:
	@./build_app.sh --install

stop:
	@osascript -e 'tell application "$(APP_NAME)" to quit' 2>/dev/null || true
	@killall "$(APP_NAME)" 2>/dev/null || true
	@sleep 0.5

start:
	@open "$(INSTALL_DIR)" || open "$(APP_DIR)" || ("$(APP_DIR)/Contents/MacOS/$(APP_NAME)" >/dev/null 2>&1 &)

restart: install stop start
	@echo "✅ $(APP_NAME).app rebuilt, installed, and restarted."

test:
	@CLANG_MODULE_CACHE_PATH=/tmp/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-cache swift test --disable-sandbox

logs:
	@cat "$(LOG_FILE)" 2>/dev/null || echo "No logs yet."

restore:
	@if [ -n "$(ID)" ]; then \
		swift -module-cache-path /tmp/swift-module-cache -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.sagar.Tiles.TriggerRestore"), object: nil, userInfo: ["snapshot": "$(ID)"], deliverImmediately: true)'; \
	else \
		swift -module-cache-path /tmp/swift-module-cache -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.sagar.Tiles.TriggerRestore"), object: nil, userInfo: nil, deliverImmediately: true)'; \
	fi
	@sleep 1
	@tail -n 15 "$(LOG_FILE)" 2>/dev/null || true

save:
	@swift -module-cache-path /tmp/swift-module-cache -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.sagar.Tiles.TriggerSave"), object: nil, userInfo: nil, deliverImmediately: true)'
	@sleep 1
	@tail -n 10 "$(LOG_FILE)" 2>/dev/null || true

diagnose:
	@swift -module-cache-path /tmp/swift-module-cache -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.sagar.Tiles.Diagnose"), object: nil, userInfo: nil, deliverImmediately: true)'
	@sleep 2
	@tail -n 30 "$(LOG_FILE)" 2>/dev/null || true
