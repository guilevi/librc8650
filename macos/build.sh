#!/bin/sh
# Build RC8650.app, with the speech synthesis extension inside it.
#
#   ./build.sh                 build into build/
#   ./build.sh install         build, then put it in /Applications and register
#                              the extension
#
# Signing is ad-hoc by default, which needs no developer account and is enough
# for macOS to load the extension locally.  To sign it properly:
#
#   CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=XXXXXXXXXX ./build.sh
set -eu

cd "$(dirname "$0")"
ACTION=${1:-}
CONFIG=${CONFIG:-Release}
IDENTITY=${CODE_SIGN_IDENTITY:-}
TEAM=${DEVELOPMENT_TEAM:-}
GROUP=${RC8650_APP_GROUP:-$(sed -n 's/^ *RC8650_APP_GROUP: *//p' project.yml | head -1)}

./build-lib.sh

if ! command -v xcodegen >/dev/null; then
	echo "xcodegen is needed to generate RC8650.xcodeproj (brew install xcodegen)" >&2
	exit 1
fi
xcodegen generate

# The generic destination matters: without it xcodebuild pins the build to the
# architecture of the Mac doing the building, and the universal ARCHS in
# project.yml quietly has no effect.
set -- -project RC8650.xcodeproj -scheme RC8650 -configuration "$CONFIG" \
       -derivedDataPath build/dd -destination generic/platform=macOS
[ -n "$IDENTITY" ] && set -- "$@" CODE_SIGN_IDENTITY="$IDENTITY"
[ -n "$TEAM" ] && set -- "$@" DEVELOPMENT_TEAM="$TEAM"

xcodebuild "$@" build

APP=build/dd/Build/Products/$CONFIG/RC8650.app
echo
echo "built $APP"

# The firmware is RC Systems' copyrighted code and is not part of this tree.
# If a copy is sitting in the repo, put it in the group container the app and
# the extension share rather than making the user find it through the file
# picker.
SUPPORT="$HOME/Library/Group Containers/$GROUP"
if [ ! -f "$SUPPORT/firmware.srec" ]; then
	for candidate in ../../rc8650_m4_valid.srec ../../rc8650_m4_fw.srec ../../rc8650_m4.srec; do
		if [ -f "$candidate" ]; then
			mkdir -p "$SUPPORT"
			cp "$candidate" "$SUPPORT/firmware.srec"
			echo "installed firmware from $candidate"
			break
		fi
	done
fi

if [ "$ACTION" = install ] || [ "${INSTALL:-}" = 1 ]; then
	echo "installing to /Applications"
	rm -rf /Applications/RC8650.app
	cp -R "$APP" /Applications/
	# LaunchServices is what registers the extension inside the app; it does
	# that when it sees the app, which a copy into /Applications is enough for,
	# but asking directly makes it immediate.
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f /Applications/RC8650.app
	pluginkit -a /Applications/RC8650.app/Contents/PlugIns/RC8650Voices.appex 2>/dev/null || true
	echo
	echo "open /Applications/RC8650.app once, then look in"
	echo "System Settings > Accessibility > Spoken Content > System Voice"
fi
