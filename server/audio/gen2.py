# Red-XAI media worker: sfx (AudioLDM-s) and video (ModelScope text-to-video) on CPU.
# Usage: gen2.py sfx|video "<prompt>" <seconds|frames> <out>   Prints "PROGRESS n" lines (0-100).
import os, sys
os.environ.setdefault("HF_HOME", "/opt/dolphin/audio/hf"); os.environ["HF_HUB_OFFLINE"] = "1"
import torch
torch.set_num_threads(os.cpu_count())
mode, prompt, amt, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
def cb(steps):
    def f(pipe, i, t, kw):
        print("PROGRESS %d" % int((i + 1) * 100 / steps), flush=True); return kw
    return f
def lcb(steps):
    def f(i, t, lat):
        print("PROGRESS %d" % int((i + 1) * 100 / steps), flush=True)
    return f
if mode == "sfx":
    from diffusers import AudioLDMPipeline
    import scipy.io.wavfile as wf
    p = AudioLDMPipeline.from_pretrained("cvssp/audioldm-s-full-v2", torch_dtype=torch.float32)
    n = 20
    a = p(prompt, num_inference_steps=n, audio_length_in_s=amt, callback=lcb(n), callback_steps=1).audios[0]
    wf.write(out, 16000, a)
elif mode == "video":
    from diffusers import TextToVideoSDPipeline
    from diffusers.utils import export_to_video
    p = TextToVideoSDPipeline.from_pretrained("ali-vilab/text-to-video-ms-1.7b", torch_dtype=torch.float32)
    n = 12
    fr = p(prompt, num_inference_steps=n, num_frames=int(amt), height=256, width=256, callback=lcb(n), callback_steps=1).frames[0]
    export_to_video(fr, out, fps=8)
