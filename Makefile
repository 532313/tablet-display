SHELL := /bin/zsh
APP   := build/TabletDisplay.app

.PHONY: all app apk install-tablet icon test test-core test-android signing run wireless dmg release install clean distclean

all: app

app:
	./scripts/build-app.sh

apk:
	./scripts/build-android.sh

install-tablet: apk
	./scripts/install-tablet.sh

icon:
	./scripts/build-icon.sh

test: test-core test-android

test-core:
	./scripts/test-core.sh

test-android:
	./scripts/test-android.sh

signing:
	./scripts/create-signing-identity.sh

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
	rm -f build/android/unsigned.apk build/android/aligned.apk build/android/res.zip
	rm -rf build/TabletDisplay.app build/TabletDisplay.apk build/core-tests
	rm -f build/TabletDisplay.apk.idsig

distclean: clean
	rm -rf dist
