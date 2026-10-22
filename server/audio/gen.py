import os, sys
os.environ.setdefault("HF_HOME", "/opt/dolphin/audio/hf"); os.environ["HF_HUB_OFFLINE"] = "1"
import torch, scipy.io.wavfile as wf
from transformers import AutoProcessor, MusicgenForConditionalGeneration
torch.set_num_threads(os.cpu_count())
prompt, dur, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
p = AutoProcessor.from_pretrained("facebook/musicgen-small")
m = MusicgenForConditionalGeneration.from_pretrained("facebook/musicgen-small")
x = p(text=[prompt], padding=True, return_tensors="pt")
a = m.generate(**x, max_new_tokens=int(dur * 50), do_sample=True)
wf.write(out, m.config.audio_encoder.sampling_rate, a[0, 0].numpy())
