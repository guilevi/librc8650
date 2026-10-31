#!/bin/sh
# Build RC8650.app, with the speech synthesis extension inside it.
#
#   ./build.sh                 build into build/
#   ./build.sh install         build, stop the running app and extension, put
#                              it in /Applications, register the extension and
#                              check that the registered one is the new build
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
	LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
	EXT_ID=com.guilevi.rc8650.voices
	DEST=/Applications/RC8650.app
	DEST_EXT=$DEST/Contents/PlugIns/RC8650Voices.appex

	# Anything still running is the old build: an extension process keeps the
	# binary it was launched from, so replacing the files alone leaves the old
	# code speaking until macOS happens to recycle it.  Stop it before the copy
	# and again after registering, in case something asked for a voice in
	# between and pkd launched the old one.
	stop_running() {
		pkill -x RC8650Voices 2>/dev/null || true
		pkill -x RC8650 2>/dev/null || true
		i=0
		while pgrep -x RC8650Voices >/dev/null || pgrep -x RC8650 >/dev/null; do
			i=$((i + 1))
			if [ $i -gt 50 ]; then
				pkill -9 -x RC8650Voices 2>/dev/null || true
				pkill -9 -x RC8650 2>/dev/null || true
				break
			fi
			sleep 0.1
		done
	}

	echo "stopping the running app and extension"
	stop_running
	echo "installing to /Applications"
	rm -rf "$DEST"
	cp -R "$APP" /Applications/

	# The copy in build/ is registered too, as soon as LaunchServices sees it,
	# with the same identifier and version - so pkd may launch that one
	# instead.  Only the installed copy should be known.
	pluginkit -r "$APP/Contents/PlugIns/RC8650Voices.appex" 2>/dev/null || true
	"$LSREGISTER" -u "$APP" 2>/dev/null || true

	# LaunchServices is what registers the extension inside the app; it does
	# that when it sees the app, which a copy into /Applications is enough for,
	# but asking directly makes it immediate.
	"$LSREGISTER" -f "$DEST"
	pluginkit -a "$DEST_EXT" 2>/dev/null || true
	pluginkit -e use -i "$EXT_ID" 2>/dev/null || true
	stopped_at=$(date +%s)
	stop_running

	# Check, rather than hope: the extension pkd knows about is the installed
	# one, it is the binary just built, and nothing old is still running.
	BIN=Contents/MacOS/RC8650Voices
	registered=$(pluginkit -m -A -D -v -i "$EXT_ID" | awk -F'\t' 'NF > 1 { print $NF }')
	ok=1
	if [ "$registered" != "$DEST_EXT" ]; then
		echo "the registered extension is not just the installed one:" >&2
		echo "$registered" >&2
		ok=0
	fi
	if ! cmp -s "$APP/Contents/PlugIns/RC8650Voices.appex/$BIN" "$DEST_EXT/$BIN"; then
		echo "the installed extension is not the one just built" >&2
		ok=0
	fi
	# One started since the last stop is the new build - something asked for
	# a voice - so only an older one counts against the install.
	for pid in $(pgrep -x RC8650Voices); do
		started=$(ps -o lstart= -p "$pid" | sed 's/ *$//')
		[ -n "$started" ] || continue
		started=$(date -j -f "%a %b %e %T %Y" "$started" +%s 2>/dev/null || echo 0)
		if [ "$started" -lt "$stopped_at" ]; then
			echo "an RC8650Voices process from before the install is still running: $pid" >&2
			ok=0
		fi
	done
	if [ $ok = 0 ]; then
		echo "install NOT verified" >&2
		exit 1
	fi
	echo "verified: $DEST_EXT is the only registered copy, freshly built, nothing older running"
	echo
	echo "open /Applications/RC8650.app once, then look in"
	echo "System Settings > Accessibility > Spoken Content > System Voice"
fi
