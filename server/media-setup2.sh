#!/bin/bash
# Red-XAI media part 2: Piper TTS, AudioLDM sound effects, ModelScope short video (all CPU).
set -x
apt-get install -y -qq ffmpeg >/dev/null 2>&1
mkdir -p /opt/dolphin/tts && cd /opt/dolphin/tts
curl -sfL https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz | tar xz
for f in en_US-lessac-medium.onnx en_US-lessac-medium.onnx.json; do curl -sfL -o $f https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/$f; done
echo hello | ./piper/piper -m en_US-lessac-medium.onnx -f /tmp/t.wav && echo TTS_DONE
/opt/dolphin/audio/venv/bin/python -m pip install -q diffusers imageio imageio-ffmpeg opencv-python-headless
cp "$(dirname "$0")/audio/gen2.py" /opt/dolphin/audio/gen2.py
HF_HOME=/opt/dolphin/audio/hf /opt/dolphin/audio/venv/bin/python -c "
from diffusers import AudioLDMPipeline as A, TextToVideoSDPipeline as V
A.from_pretrained('cvssp/audioldm-s-full-v2'); print('SFX_MODEL_DONE', flush=True)
V.from_pretrained('ali-vilab/text-to-video-ms-1.7b'); print('VIDEO_MODEL_DONE')"
echo ALL_DONE
