#!/bin/zsh
# Build the release binary, assemble "FCP字幕.app", ad-hoc sign inside-out,
# and produce a distributable DMG.
#
# Per user request this script NEVER launches the app or opens the DMG.
set -euo pipefail

GUI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(dirname "$GUI_DIR")"
APP_NAME="FCP字幕"
BUNDLE_ID="com.xiaohe.fcpsubtitle"
VERSION="1.1.0"
# FCP_SUBTITLE_DIST overrides the output directory (e.g. for a trial build
# that must not overwrite released DMGs).
DIST="${FCP_SUBTITLE_DIST:-$GUI_DIR/dist}"
APP="$DIST/$APP_NAME.app"

# 默认产出发布用的 FCP字幕.dmg(~14MB):只内置 0.6MB 的 VAD 模型,SenseVoice 由
# 用户首次启动后在「模型管理」页下载。GitHub Release 只发这一个。
# --with-models: 额外内置 SenseVoice(~240MB),产出离线安装用的 FCP字幕-含模型.dmg。
WITH_MODELS=0
DMG_NAME="$APP_NAME"
case "${1:-}" in
    --with-models) WITH_MODELS=1; DMG_NAME="$APP_NAME-含模型" ;;
    ""|--no-models) ;;  # --no-models was the old spelling of the default
    *) echo "未知参数: $1(可用: --with-models)" >&2; exit 1 ;;
esac

echo "==> swift build (release)"
cd "$GUI_DIR"
swift build -c release --arch arm64

echo "==> 组装 .app"
rm -rf "$APP" "$DIST/staging" "$DIST/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$GUI_DIR/.build/release/FCPSubtitle" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Media</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audio</string>
                <string>public.movie</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>SubRip Subtitle</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>srt</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> 生成图标 (.icns)"
ICON_PNG="$GUI_DIR/assets/AppIcon.png"
if [[ -f "$ICON_PNG" ]]; then
    ICONSET="$DIST/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" > /dev/null
        d=$((s * 2))
        sips -z $d $d "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" > /dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

# The VAD model is tiny, so it always ships: first launch then needs only the
# SenseVoice download (hf-mirror by default) instead of a second one from GitHub.
echo "==> 内置 VAD 模型 (0.6MB)"
mkdir -p "$APP/Contents/Resources/models"
cp "$PROJECT_DIR/models/silero_vad.onnx" "$APP/Contents/Resources/models/"
if [[ $WITH_MODELS -eq 1 ]]; then
    echo "==> 内置 SenseVoice 模型 (--with-models)"
    mkdir -p "$APP/Contents/Resources/models/sense-voice"
    cp "$PROJECT_DIR/models/sense-voice/model.int8.onnx" "$APP/Contents/Resources/models/sense-voice/"
    cp "$PROJECT_DIR/models/sense-voice/tokens.txt" "$APP/Contents/Resources/models/sense-voice/"
else
    echo "==> SenseVoice 不打包,用户在「模型管理」页下载"
fi

echo "==> 拷贝 dylib(只拷实际链接到的,不再整目录拷贝)"
BIN="$APP/Contents/MacOS/$APP_NAME"
VENDOR_LIB="$GUI_DIR/Vendor/sherpa-onnx/lib"
rpath_deps() {  # rpath_deps <binary> <lines to skip>: @rpath/X dependencies -> X
    otool -L "$1" | awk -v skip="$2" 'NR>skip && $1 ~ /^@rpath\// {print substr($1, 8)}'
}
typeset -U wanted
wanted=($(rpath_deps "$BIN" 1))
for lib in $wanted; do
    wanted+=($(rpath_deps "$VENDOR_LIB/$lib" 2))  # a dylib lists its own id first
done
for lib in $wanted; do
    cp "$VENDOR_LIB/$lib" "$APP/Contents/Frameworks/"
done

for dylib in "$APP/Contents/Frameworks"/*.dylib; do
    base="$(basename "$dylib")"
    install_name_tool -id "@rpath/$base" "$dylib" 2>/dev/null || true
done

# Point the executable's load commands at @rpath if any resolve to plain names.
otool -L "$BIN" | awk 'NR>1 {print $1}' | while read -r dep; do
    case "$dep" in
        /usr/lib/*|/System/*|@rpath/*) ;;
        *libsherpa*|*libonnxruntime*)
            install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$BIN"
            ;;
    esac
done

echo "==> 去掉指向开发机的 rpath"
# Dev builds look up dylibs in Vendor/; the shipped app must only use its own
# Frameworks folder. The toolchain's swift lib dir is only needed by binaries
# that link swift libs via @rpath, which this one doesn't.
links_swift_via_rpath=0
if otool -L "$BIN" | grep -q "@rpath/libswift"; then links_swift_via_rpath=1; fi
rpaths=($(otool -l "$BIN" | awk '$1 == "path" {print $2}'))
for rp in $rpaths; do
    case "$rp" in
        */Vendor/sherpa-onnx/lib|Vendor/sherpa-onnx/lib)
            install_name_tool -delete_rpath "$rp" "$BIN" ;;
        /Library/Developer/*|/Applications/Xcode*)  # CommandLineTools / Xcode toolchain
            if [[ $links_swift_via_rpath -eq 0 ]]; then install_name_tool -delete_rpath "$rp" "$BIN"; fi ;;
    esac
done
otool -l "$BIN" | awk '$1 == "path" {print "    rpath: " $2}'

echo "==> 检查 @rpath 依赖都在包内"
for f in "$BIN" "$APP/Contents/Frameworks"/*.dylib; do
    for dep in $(rpath_deps "$f" 1); do
        if [[ ! -f "$APP/Contents/Frameworks/$dep" ]]; then
            echo "错误: $f 依赖的 $dep 不在 Frameworks 里" >&2
            exit 1
        fi
    done
done

echo "==> inside-out ad-hoc 签名"
for dylib in "$APP/Contents/Frameworks"/*.dylib; do
    codesign --force -s - "$dylib"
done
codesign --force -s - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> 生成 DMG(拖装布局 + 说明背景图)"
if [[ ! -f "$GUI_DIR/assets/dmg_background.png" ]]; then
    (cd "$PROJECT_DIR" && uv run --no-project --with pillow python gui/scripts/make_dmg_background.py)
fi
rm -f "$DIST/$DMG_NAME.dmg"
# --no-project: only dmgbuild is needed, not the Python CLI's dependencies.
(cd "$PROJECT_DIR" && uv run --no-project --with dmgbuild dmgbuild \
    -s "$GUI_DIR/scripts/dmg_settings.py" \
    -D app="$APP" \
    -D background="$GUI_DIR/assets/dmg_background.png" \
    "$APP_NAME" "$DIST/$DMG_NAME.dmg")
hdiutil verify "$DIST/$DMG_NAME.dmg"

echo "==> 完成(未启动应用): $DIST/$DMG_NAME.dmg"
