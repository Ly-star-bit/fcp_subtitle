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
VERSION="1.0.0"
DIST="$GUI_DIR/dist"
APP="$DIST/$APP_NAME.app"

# --no-models: 不打包模型,用户在应用内「模型管理」页自行下载(DMG 从 ~178MB 缩到 ~50MB)
WITH_MODELS=1
DMG_NAME="$APP_NAME"
if [[ "${1:-}" == "--no-models" ]]; then
    WITH_MODELS=0
    DMG_NAME="$APP_NAME-精简版"
fi

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

if [[ $WITH_MODELS -eq 1 ]]; then
    echo "==> 拷贝模型 (models/)"
    mkdir -p "$APP/Contents/Resources/models/sense-voice"
    cp "$PROJECT_DIR/models/sense-voice/model.int8.onnx" "$APP/Contents/Resources/models/sense-voice/"
    cp "$PROJECT_DIR/models/sense-voice/tokens.txt" "$APP/Contents/Resources/models/sense-voice/"
    cp "$PROJECT_DIR/models/silero_vad.onnx" "$APP/Contents/Resources/models/"
else
    echo "==> 精简版:跳过模型打包"
fi

echo "==> 拷贝 dylib 并归一化 install name"
cp "$GUI_DIR"/Vendor/sherpa-onnx/lib/*.dylib* "$APP/Contents/Frameworks/"

for dylib in "$APP/Contents/Frameworks"/*.dylib; do
    [[ -L "$dylib" ]] && continue
    base="$(basename "$dylib")"
    install_name_tool -id "@rpath/$base" "$dylib" 2>/dev/null || true
done

# Point the executable's load commands at @rpath if any resolve to plain names.
BIN="$APP/Contents/MacOS/$APP_NAME"
otool -L "$BIN" | awk 'NR>1 {print $1}' | while read -r dep; do
    case "$dep" in
        /usr/lib/*|/System/*|@rpath/*) ;;
        *libsherpa*|*libonnxruntime*)
            install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$BIN"
            ;;
    esac
done

echo "==> inside-out ad-hoc 签名"
for dylib in "$APP/Contents/Frameworks"/*.dylib; do
    [[ -L "$dylib" ]] && continue
    codesign --force -s - "$dylib"
done
codesign --force -s - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> 生成 DMG(拖装布局 + 说明背景图)"
if [[ ! -f "$GUI_DIR/assets/dmg_background.png" ]]; then
    (cd "$PROJECT_DIR" && uv run --with pillow python gui/scripts/make_dmg_background.py)
fi
rm -f "$DIST/$DMG_NAME.dmg"
(cd "$PROJECT_DIR" && uv run --with dmgbuild dmgbuild \
    -s "$GUI_DIR/scripts/dmg_settings.py" \
    -D app="$APP" \
    -D background="$GUI_DIR/assets/dmg_background.png" \
    "$APP_NAME" "$DIST/$DMG_NAME.dmg")
hdiutil verify "$DIST/$DMG_NAME.dmg"

echo "==> 完成(未启动应用): $DIST/$DMG_NAME.dmg"
