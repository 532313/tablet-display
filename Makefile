SHELL := /bin/zsh
APP   := build/TabletDisplay.app

.PHONY: all app apk install-tablet icon test test-core test-android test-ui test-device test-device-video test-permission signing run wireless dmg release notarize release-check install clean distclean

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

test-ui:
	./scripts/test-ui.sh

test-device:
	./scripts/test-device-smoke.sh

test-device-video:
	./scripts/test-device-video.sh

test-permission:
	./scripts/test-permission-failure.sh

signing:
	./scripts/create-signing-identity.sh

run:
	./scripts/run.sh

wireless:
	./scripts/run-wireless.sh

dmg: app
	./scripts/make-dmg.sh --no-build

release: dmg release-check

notarize:
	./scripts/notarize.sh

release-check:
	./scripts/check-release.sh

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
