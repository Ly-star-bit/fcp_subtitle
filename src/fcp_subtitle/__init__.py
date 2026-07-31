from ._dylib_fix import ensure_onnxruntime_dylib_path

ensure_onnxruntime_dylib_path()


def main() -> None:
    from .cli import main as _main

    _main()
