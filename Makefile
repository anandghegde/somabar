.PHONY: build test generate app run lint clean release sparkle-keys

DERIVED := .build/xcode
APP := $(DERIVED)/Build/Products/Debug/Somabar.app

## Build the Swift package (Core, BarEngine, NotchKit).
build:
	swift build

## Run the unit tests.
test:
	swift test

## Generate Somabar.xcodeproj from project.yml.
generate:
	xcodegen generate

## Build the menu bar app into .build/xcode.
app: generate
	xcodebuild -project Somabar.xcodeproj -scheme Somabar -configuration Debug -derivedDataPath $(DERIVED) build

## Build and launch the app.
run: app
	open $(APP)

## Release build, signing, notarization, zip/dmg and appcast into dist/ (see README, Releasing).
release:
	Scripts/release.sh

## One-time: create the Sparkle signing key in the login keychain and print its public key.
sparkle-keys:
	Scripts/sparkle-keys.sh

lint:
	swiftlint lint --quiet

clean:
	rm -rf .build Somabar.xcodeproj
