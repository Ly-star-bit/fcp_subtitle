#ifndef FCP_SUBTITLE_SHERPA_ONNX_SHIM_H
#define FCP_SUBTITLE_SHERPA_ONNX_SHIM_H

// Included relative to this file rather than through an "-I" flag: SwiftPM
// drops the path of an unsafeFlags "-I" when it generates the test runner
// module, leaving a dangling "-I" that breaks `swift test`.
#include "../../Vendor/sherpa-onnx/include/sherpa-onnx/c-api/c-api.h"

#endif
