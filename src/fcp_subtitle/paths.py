from pathlib import Path

# src/fcp_subtitle/paths.py -> parents[0]=src/fcp_subtitle, [1]=src, [2]=project root
PROJECT_ROOT = Path(__file__).resolve().parents[2]
MODELS_DIR = PROJECT_ROOT / "models"

SENSE_VOICE_MODEL = MODELS_DIR / "sense-voice" / "model.int8.onnx"
SENSE_VOICE_TOKENS = MODELS_DIR / "sense-voice" / "tokens.txt"
SILERO_VAD_MODEL = MODELS_DIR / "silero_vad.onnx"
