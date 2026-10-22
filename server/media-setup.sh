#!/bin/bash
# Red-XAI media capabilities on CPU: stable-diffusion.cpp + SD-Turbo, MusicGen-small.
set -x
mkdir -p /opt/dolphin/media-models/image /opt/dolphin/audio
( cd /opt/dolphin && rm -rf sdsrc && git clone -q --depth 1 --recursive https://github.com/leejet/stable-diffusion.cpp sdsrc && cd sdsrc && cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON >/dev/null && cmake --build build -j16 --target sd >/dev/null 2>&1 || cmake --build build -j16 >/dev/null; f=$(find build -type f -name sd -perm -u+x | head -1); [ -z "$f" ] && f=$(find build -type f -name 'sd-cli' -perm -u+x | head -1); cp "$f" /opt/dolphin/bin/sd.new && find build -name '*.so*' -exec cp -P {} /opt/dolphin/bin/ \; ; echo SD_BUILD_DONE ) > /opt/dolphin/cache/sd-build.log 2>&1 &
curl -sfL -o /opt/dolphin/media-models/image/sd_turbo.safetensors.part https://huggingface.co/stabilityai/sd-turbo/resolve/main/sd_turbo.safetensors && mv /opt/dolphin/media-models/image/sd_turbo.safetensors.part /opt/dolphin/media-models/image/sd_turbo.safetensors
wait
[ -f /opt/dolphin/bin/sd.new ] && mv /opt/dolphin/bin/sd.new /opt/dolphin/bin/sd
echo IMAGE_DONE
apt-get install -y -qq python3-venv >/dev/null 2>&1
python3 -m venv /opt/dolphin/audio/venv.new && /opt/dolphin/audio/venv.new/bin/pip install -q --index-url https://download.pytorch.org/whl/cpu torch && /opt/dolphin/audio/venv.new/bin/pip install -q transformers scipy accelerate && \
HF_HOME=/opt/dolphin/audio/hf /opt/dolphin/audio/venv.new/bin/python -c "from transformers import AutoProcessor, MusicgenForConditionalGeneration as M; AutoProcessor.from_pretrained('facebook/musicgen-small'); M.from_pretrained('facebook/musicgen-small')" && mv /opt/dolphin/audio/venv.new /opt/dolphin/audio/venv
echo AUDIO_DONE
