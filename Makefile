APP_NAME := Tiles
APP_DIR  := /Users/sagar/Applications/Mac Apps/Tiles/$(APP_NAME).app

.PHONY: all build stop start restart test logs

all: build

build:
	@"/Users/sagar/Applications/Mac Apps/Tiles/build_app.sh"

stop:
	@osascript -e 'tell application "$(APP_NAME)" to quit' 2>/dev/null || true
	@killall "$(APP_NAME)" 2>/dev/null || true
	@sleep 0.5

start:
	@open "$(APP_DIR)" || ("$(APP_DIR)/Contents/MacOS/$(APP_NAME)" >/dev/null 2>&1 &)

restart: build stop start
	@echo "✅ $(APP_NAME).app rebuilt and restarted."

test:
	@swiftc -module-cache-path /tmp/swift-module-cache -target arm64-apple-macosx14.0 \
		Sources/Tiles/Models.swift \
		Sources/Tiles/SpaceBridge.swift \
		Sources/Tiles/DisplayHelper.swift \
		Sources/Tiles/WindowEngine.swift \
		Sources/Tiles/SnapshotStore.swift \
		"/Users/sagar/.gemini/antigravity/brain/d7b74e99-81e0-476e-bea7-709c0516f74f/scratch/verify_tiles.swift" \
		-o /tmp/verify_tiles && /tmp/verify_tiles

logs:
	@cat "/Users/sagar/Applications/Mac Apps/Tiles/TilesData/tiles.log" 2>/dev/null || echo "No logs yet."

restore:
	@swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.sagar.Tiles.TriggerRestore"), object: nil, userInfo: nil, deliverImmediately: true)'
	@sleep 1
	@tail -n 10 "/Users/sagar/Applications/Mac Apps/Tiles/TilesData/tiles.log"
