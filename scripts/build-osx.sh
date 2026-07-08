#!/bin/bash -xe

# this script builds LibreCAD in OS/X
# The dependency required to be able to build LibreCAD:
# qt, boost, muparser

# Options
# -p=|--qtpath= : Set's a specific path where to startqmake from example : build-osx.sh -p=/opt/Qt5.2.1/5.2.1/clang_64/bin
# default is set to /opt/local/bin/ for backwards compatibility of this script
#
# -q=|-qmake_opts= : Set's additional qmake options exaomple : -qmake_opts="QMAKE_MAC_SDK=macosx10.9"
# default is set to "-spec mkspec/macports" for backwards compatibility reasons of this script
#
# -no-p|--no-qtpath : Removes the default qtpath, this makes the default search path take over to find qmake
#
# -cert=|-codesign-identity= : Run macdeployqt -codesign=<identity> (requires Qt >= 5.4.0)
# Example: ./build-osx.sh -cert=123456789A
# Use 'security find-identity -v -p codesigning' to get a list of signing identities.
# Example: A000000000000000000000000000000000000001 "Developer ID Application: John Smith (123456789A)"

SCRIPTPATH="$(dirname "$0")"

for i in /opt/local/libexec /usr/local/opt /usr/local $(dirname `which qmake6`)
do
    for j in "" 6
    do
        if [ -x "$i/qt$j/bin/qmake$j" ]
        then
            QT_PATH=$i/qt$j/bin/
            QMAKE_CMD=${QT_PATH}qmake${j}
            break
        fi
        if [ -x "$i/qmake${j}" ]; then
        	QT_PATH="$i/"
            QMAKE_CMD=${QT_PATH}qmake${j}
    	break
        fi
    done
    if [ -x "$QMAKE_CMD" ]
    then
	break
    fi
done

#validate QT_PATH
if [ ! -x "$QMAKE_CMD" ]
then
    echo "QT_PATH or qmake could not be determined, exiting" >&2
    exit 1
fi

echo QT_PATH="$QT_PATH"
echo QMAKE_CMD="$QMAKE_CMD"

# Honor a QMAKE_OPTS value inherited from the environment (CI sets
# QMAKE_APPLE_DEVICE_ARCHS here to build a universal binary); default to empty.
# A -q=/-qmake_opts= command-line argument still overrides this in the loop below.
QMAKE_OPTS="${QMAKE_OPTS:-}"
CODESIGN_IDENTITY=""

for i in "$@"
do
case $i in
    -q=*|-qmake_opts=*)
    QMAKE_OPTS="${i#*=}"
    ;;
    -p=*|--qtpath*=)
    QT_PATH="${i#*=}"
    if [[ $QT_PATH ]]
    then
        QT_PATH=${QT_PATH%/}/
    fi
    ;;
    -no-p|--no-qtpath)
    QT_PATH=
    ;;
    -cert=*|-codesign-identity=*)
    CODESIGN_IDENTITY="${i#*=}"
    ;;
    *)
            # unknown option
    ;;
esac
done

# validate QT_VERSION
QT_VERSION=$(${QMAKE_CMD} -query QT_VERSION)
QT_VERSION_ARRAY=( ${QT_VERSION//./ } )
echo "QT_VERSION=${QT_VERSION_ARRAY[0]}.${QT_VERSION_ARRAY[1]}.${QT_VERSION_ARRAY[2]}"

# validate CODESIGN
if [[ $CODESIGN_IDENTITY ]]
then
	if [ "${QT_VERSION_ARRAY[0]}" -lt 5 ]
	then
		echo "macdeployqt -codesign requires QT_VERSION >= 5.4.0"
		exit 1
	else
		if [ "${QT_VERSION_ARRAY[1]}" -lt 4 ]
		then
	                echo "macdeployqt -codesign requires QT_VERSION >= 5.4.0"
			exit 1
		fi
	fi
fi

cd "${SCRIPTPATH}"/..

# have to clean up any existing binary files to avoid crashes of bug#422
rm -rf LibreCAD.app

# Run distclean if a previous version of Makefile exists
if [ -f Makefile ]; then
    $QMAKE_CMD $QMAKE_OPTS -r
    make distclean
fi

rm -rf generated
$QMAKE_CMD $QMAKE_OPTS -r

#undefined symbol x86_64: https://qt-project.org/forums/viewthread/35646
# RVT July 12 2015, this is now controlled with QMAKE_MAC_SDK
#find . -iname makefile -exec sed -i '' \
#	-e 's:mmacosx-version-min=10.[1-9]:mmacosx-version-min=10.8:g' \
#	-e 's:MacOSX10.[1-9].sdk:MacOSX10.8.sdk:g'  \
#	'{}' ';'

#to make it auto, use "make -j"
#hardcoded to 4 jobs, because "make -j" crashes our mac building box
make -j6

APP_FILE=LibreCAD
OUTPUT_DMG=${APP_FILE}.dmg

# Deploy the Qt frameworks into the bundle. macdeployqt rewrites Mach-O load
# commands (install_name_tool), which invalidates any existing signature, so the
# bundle MUST be (re)signed AFTER this step.
${QT_PATH}macdeployqt ${APP_FILE}.app -verbose=2 -always-overwrite

# Code signing.
#
# On Apple Silicon, macOS refuses to launch an arm64 binary whose signature is
# missing or invalid ("app is damaged"), so signing after macdeployqt is
# required. With a real Developer ID (-cert=) we sign using the hardened runtime
# so the result can be notarized; otherwise we fall back to an ad-hoc signature,
# which is enough for the app to launch (issue #2162).
if [[ $CODESIGN_IDENTITY ]]
then
	codesign --force --deep --options runtime --timestamp \
		--sign "$CODESIGN_IDENTITY" "${APP_FILE}.app"
else
	echo "No signing identity supplied; applying an ad-hoc signature."
	codesign --force --deep --sign - "${APP_FILE}.app"
fi

# Build the compressed DMG from the signed bundle.
hdiutil create -volname "$APP_FILE" -srcfolder "${APP_FILE}.app" \
	-ov -format UDZO "$OUTPUT_DMG"

if [[ -f  "${OUTPUT_DMG}" ]]
then
	echo "DMG installer generated:"
	ls -lh "${OUTPUT_DMG}"
fi

# With a real Developer ID, sign the DMG too and - when notarization credentials
# are provided via the environment - notarize and staple it. Notarization is
# skipped by default, so an ordinary build needs no Apple account. Provide either
# a stored notarytool profile (NOTARIZE_KEYCHAIN_PROFILE) or the individual
# credentials (NOTARIZE_APPLE_ID + NOTARIZE_TEAM_ID + NOTARIZE_PASSWORD).
if [[ $CODESIGN_IDENTITY ]]
then
	codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$OUTPUT_DMG"
	if [[ ${NOTARIZE_KEYCHAIN_PROFILE:-} ]]
	then
		xcrun notarytool submit "$OUTPUT_DMG" --keychain-profile "$NOTARIZE_KEYCHAIN_PROFILE" --wait
		xcrun stapler staple "$OUTPUT_DMG"
	elif [[ ${NOTARIZE_APPLE_ID:-} && ${NOTARIZE_TEAM_ID:-} && ${NOTARIZE_PASSWORD:-} ]]
	then
		xcrun notarytool submit "$OUTPUT_DMG" --apple-id "$NOTARIZE_APPLE_ID" --team-id "$NOTARIZE_TEAM_ID" --password "$NOTARIZE_PASSWORD" --wait
		xcrun stapler staple "$OUTPUT_DMG"
	fi
fi
