.PHONY: build test generate app run lint clean

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

lint:
	swiftlint lint --quiet

clean:
	rm -rf .build Somabar.xcodeproj
