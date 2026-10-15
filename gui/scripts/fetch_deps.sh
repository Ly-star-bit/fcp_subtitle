#!/bin/zsh
# Download the prebuilt sherpa-onnx C library (macOS arm64, shared) into Vendor/.
#
# onnxruntime comes from Microsoft's official release rather than the copy
# bundled in the sherpa-onnx package: that copy never selects the UDOT/I8MM
# int8 kernels on Apple Silicon, which made recognition ~2.6x slower (10-min
# file: 18.95s -> 7.33s on M4 Max, identical output). Both archives are pinned
# by SHA-256 (the digests GitHub publishes for these release assets).
set -euo pipefail

SHERPA_VERSION="1.13.4"
SHERPA_NAME="sherpa-onnx-v${SHERPA_VERSION}-osx-arm64-shared"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/${SHERPA_NAME}.tar.bz2"
SHERPA_SHA256="809ab5d0c77bd8f358364a244e6ab17f2afecf9779eb9fd436fa469c3ff5375c"

# Must match the libonnxruntime.<version>.dylib that libsherpa-onnx-c-api links.
ORT_VERSION="1.27.0"
ORT_NAME="onnxruntime-osx-arm64-${ORT_VERSION}"
ORT_URL="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/${ORT_NAME}.tgz"
ORT_SHA256="545e81c58152353acb0d1e8bd6ce4b62f830c0961f5b3acfedc790ffd76e477a"

GUI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$GUI_DIR/Vendor/sherpa-onnx"
STAMP="sherpa-onnx $SHERPA_VERSION + onnxruntime $ORT_VERSION (microsoft)"

if [[ -f "$VENDOR/VERSION" && "$(cat "$VENDOR/VERSION")" == "$STAMP" ]]; then
    echo "依赖已是最新($STAMP),跳过下载"
    exit 0
fi
# Older checkouts carry the slower onnxruntime and no stamp: replace wholesale.
rm -rf "$VENDOR"
mkdir -p "$VENDOR/lib"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Unset → default proxy; set to an empty string → direct connection.
PROXY="${FCP_SUBTITLE_PROXY-http://192.168.20.87:7899}"
curl_args=(-fL --retry 3)
[[ -n "$PROXY" ]] && curl_args+=(-x "$PROXY")

fetch() {  # fetch <url> <sha256> <dest>
    echo "下载: $1 (代理: ${PROXY:-直连})"
    curl "${curl_args[@]}" -o "$3" "$1"
    echo "$2  $3" | shasum -a 256 -c -
}

fetch "$SHERPA_URL" "$SHERPA_SHA256" "$tmp/sherpa.tar.bz2"
fetch "$ORT_URL" "$ORT_SHA256" "$tmp/ort.tgz"
tar xjf "$tmp/sherpa.tar.bz2" -C "$tmp"
tar xzf "$tmp/ort.tgz" -C "$tmp"

cp -R "$tmp/$SHERPA_NAME/include" "$VENDOR/"
# Only the C API is used; the C++ wrapper and the bundled onnxruntime are not.
cp "$tmp/$SHERPA_NAME/lib/libsherpa-onnx-c-api.dylib" "$VENDOR/lib/"
cp "$tmp/$ORT_NAME/lib/libonnxruntime.$ORT_VERSION.dylib" "$VENDOR/lib/"

ORT_LIB="libonnxruntime.$ORT_VERSION.dylib"
if ! otool -L "$VENDOR/lib/libsherpa-onnx-c-api.dylib" | grep -q "@rpath/$ORT_LIB"; then
    echo "错误: libsherpa-onnx-c-api 依赖的 onnxruntime 版本不是 $ORT_VERSION:" >&2
    otool -L "$VENDOR/lib/libsherpa-onnx-c-api.dylib" | grep onnxruntime >&2
    exit 1
fi
# Microsoft ships install name @rpath/libonnxruntime.1.dylib; rename it to what
# sherpa-onnx links against so the app and sherpa-onnx resolve one file.
install_name_tool -id "@rpath/$ORT_LIB" "$VENDOR/lib/$ORT_LIB"
# The linker's -lonnxruntime needs this name; a symlink keeps one real copy.
ln -sf "$ORT_LIB" "$VENDOR/lib/libonnxruntime.dylib"

echo "--- 重签(install_name_tool 会破坏原签名) ---"
for dylib in "$VENDOR"/lib/*.dylib; do
    [[ -L "$dylib" ]] && continue
    codesign --force -s - "$dylib"
    codesign --verify "$dylib"
done

echo "$STAMP" > "$VENDOR/VERSION"
echo "已就绪: $VENDOR ($STAMP)"
