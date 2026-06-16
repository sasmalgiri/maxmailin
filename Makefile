.PHONY: build test app run install clean help

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

help:
	@echo "make build    — debug build via swift build"
	@echo "make test     — run the full unit-test suite"
	@echo "make app      — produce build/maxmailin.app (release + ad-hoc sign)"
	@echo "make run      — launch the SPM debug binary directly (no .app bundle)"
	@echo "make install  — copy build/maxmailin.app into /Applications"
	@echo "make clean    — remove the SPM build directory and the .app bundle"

build:
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun swift build

test:
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun swift test

app:
	./scripts/package.sh

run:
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun swift run maxmail-app

install: app
	rm -rf /Applications/maxmailin.app
	cp -R build/maxmailin.app /Applications/maxmailin.app
	@echo "Installed /Applications/maxmailin.app"

clean:
	rm -rf .build build
