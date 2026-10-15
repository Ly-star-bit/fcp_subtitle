#!/bin/zsh
# Download the prebuilt sherpa-onnx C library (macOS arm64, shared) into Vendor/.
#
# Uses the no-TTS build (the app only does ASR + VAD) with the onnxruntime it
# bundles. sherpa-onnx 1.13.8 ships onnxruntime 1.28.2, which picks the fast
# int8 dot-product kernels on Apple Silicon. Avoid onnxruntime 1.27.x: it makes
# zipformer-family models output nothing (SenseVoice was unaffected).
# The archive is pinned by the SHA-256 GitHub publishes for it.
set -euo pipefail

SHERPA_VERSION="1.13.8"
SHERPA_NAME="sherpa-onnx-v${SHERPA_VERSION}-osx-arm64-shared-no-tts"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/${SHERPA_NAME}.tar.bz2"
SHERPA_SHA256="91b96512c4fa1960f8a9ed5360a6c8dda53a4b5015d0590244f14086a234557a"

GUI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$GUI_DIR/Vendor/sherpa-onnx"
STAMP="sherpa-onnx $SHERPA_VERSION (no-tts, bundled onnxruntime)"

if [[ -f "$VENDOR/VERSION" && "$(cat "$VENDOR/VERSION")" == "$STAMP" ]]; then
    echo "依赖已是最新($STAMP),跳过下载"
    exit 0
fi
# Older checkouts carry other versions and no matching stamp: replace wholesale.
rm -rf "$VENDOR"
mkdir -p "$VENDOR/lib"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Unset → default proxy; set to an empty string → direct connection.
PROXY="${FCP_SUBTITLE_PROXY-http://192.168.20.87:7899}"
curl_args=(-fL --retry 3)
[[ -n "$PROXY" ]] && curl_args+=(-x "$PROXY")

echo "下载: $SHERPA_URL (代理: ${PROXY:-直连})"
curl "${curl_args[@]}" -o "$tmp/sherpa.tar.bz2" "$SHERPA_URL"
echo "$SHERPA_SHA256  $tmp/sherpa.tar.bz2" | shasum -a 256 -c -
tar xjf "$tmp/sherpa.tar.bz2" -C "$tmp"

cp -R "$tmp/$SHERPA_NAME/include" "$VENDOR/"
# Only the C API and its onnxruntime are used; the C++ wrapper is not.
cp "$tmp/$SHERPA_NAME/lib/libsherpa-onnx-c-api.dylib" "$tmp/$SHERPA_NAME/lib/libonnxruntime.dylib" "$VENDOR/lib/"

ort_version=$(strings -a "$VENDOR/lib/libonnxruntime.dylib" | grep -m1 -E '^1\.[0-9]+\.[0-9]+$' || true)
echo "onnxruntime: ${ort_version:-未知版本}"
if [[ "$ort_version" == 1.27.* ]]; then
    echo "错误: onnxruntime 1.27.x 会让 zipformer 类模型输出为空,请换用其他版本" >&2
    exit 1
fi

echo "--- 重签 ---"
for dylib in "$VENDOR"/lib/*.dylib; do
    codesign --force -s - "$dylib"
    codesign --verify "$dylib"
done

echo "$STAMP" > "$VENDOR/VERSION"
# SwiftPM doesn't track these dylibs as link inputs, so binaries built against
# the previous version would keep pointing at it.
if [[ -d "$GUI_DIR/.build" ]]; then
    echo "依赖已更换,清理旧的构建产物 (.build)"
    rm -rf "$GUI_DIR/.build"
fi
echo "已就绪: $VENDOR ($STAMP)"
