BIN_DIR := $(shell swift build -c release --show-bin-path)
BINARY := $(BIN_DIR)/OpenCodeLimits
APP_DIR := build/OpenCodeLimits.app

.PHONY: build test smoke run app install clean

build:
	swift build -c release

test:
	swift run -c release OpenCodeLimitsTests

smoke:
	OPENCODE_LIVE_SMOKE=1 swift run -c release OpenCodeLimitsTests

run:
	swift run OpenCodeLimits

app: build
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp "$(BINARY)" "$(APP_DIR)/Contents/MacOS/OpenCodeLimits"
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	printf 'APPL????' > "$(APP_DIR)/Contents/PkgInfo"
	codesign --force --sign - "$(APP_DIR)"

install: app
	rm -rf /Applications/OpenCodeLimits.app
	cp -R "$(APP_DIR)" /Applications/OpenCodeLimits.app

clean:
	swift package clean
