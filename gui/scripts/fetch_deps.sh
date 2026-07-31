#!/bin/zsh
# Download the prebuilt sherpa-onnx C library (macOS arm64, shared) into Vendor/.
set -euo pipefail

VERSION="1.13.4"
NAME="sherpa-onnx-v${VERSION}-osx-arm64-shared"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${NAME}.tar.bz2"

GUI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$GUI_DIR/Vendor/sherpa-onnx"

if [[ -f "$VENDOR/lib/libsherpa-onnx-c-api.dylib" ]]; then
    echo "sherpa-onnx 库已存在,跳过下载"
    exit 0
fi

mkdir -p "$VENDOR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

PROXY="${FCP_SUBTITLE_PROXY:-http://192.168.20.87:7899}"
echo "下载: $URL (代理: $PROXY)"
curl -fL --retry 3 -x "$PROXY" -o "$tmp/pkg.tar.bz2" "$URL"
tar xjf "$tmp/pkg.tar.bz2" -C "$tmp"

cp -R "$tmp/$NAME/include" "$VENDOR/"
mkdir -p "$VENDOR/lib"
cp -R "$tmp/$NAME"/lib/*.dylib* "$VENDOR/lib/"

echo "--- install names / 重签(上游包 libonnxruntime 签名损坏) ---"
for dylib in "$VENDOR"/lib/*.dylib; do
    [[ -L "$dylib" ]] && continue
    otool -D "$dylib" | tail -1
    codesign --force -s - "$dylib"
    codesign --verify "$dylib"
done

echo "已就绪: $VENDOR"
