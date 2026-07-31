"""Work around a packaging bug in sherpa-onnx's macOS wheels (>=1.10).

The precompiled `_sherpa_onnx.*.so` links against `@rpath/libonnxruntime.*.dylib`
but the wheel does not bundle that dylib. Installing the `onnxruntime` pip
package provides it, but dyld only finds it via `DYLD_LIBRARY_PATH`, which must
be set before the process starts. We re-exec ourselves once with that env var
set, which is transparent to any caller (uv run, Automator, a plain shell).
"""

from __future__ import annotations

import os
import sys

_REEXEC_MARKER = "_FCP_SUBTITLE_DYLD_FIXED"


def ensure_onnxruntime_dylib_path() -> None:
    if sys.platform != "darwin" or os.environ.get(_REEXEC_MARKER):
        return

    import onnxruntime

    dylib_dir = os.path.join(os.path.dirname(onnxruntime.__file__), "capi")
    existing = os.environ.get("DYLD_LIBRARY_PATH", "")
    if dylib_dir in existing.split(":"):
        return

    env = os.environ.copy()
    env["DYLD_LIBRARY_PATH"] = f"{dylib_dir}:{existing}" if existing else dylib_dir
    env[_REEXEC_MARKER] = "1"
    os.execve(sys.executable, [sys.executable, *sys.argv], env)
