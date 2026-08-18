.PHONY: build test dump app run

build:
	swift build

test:
	swift test

dump:
	swift run Backgrounds --dump

app:
	./scripts/package.sh

run: app
	open dist/Backgrounds.app
