SHELL := /bin/zsh
APP   := build/TabletDisplay.app

.PHONY: all app icon test run wireless dmg release install clean distclean

all: app

app:
	./scripts/build-app.sh

icon:
	./scripts/build-icon.sh

test:
	./scripts/test-core.sh

run:
	./scripts/run.sh

wireless:
	./scripts/run-wireless.sh

dmg: app
	./scripts/make-dmg.sh --no-build

release: dmg

install:
	./scripts/install-app.sh

clean:
	rm -rf .build
	rm -rf build/android/classes build/android/dex
	rm -f build/android/unsigned.apk build/android/aligned.apk
	rm -rf build/TabletDisplay.app build/TabletDisplay.apk build/core-tests
	rm -f build/TabletDisplay.apk.idsig

distclean: clean
	rm -rf dist
