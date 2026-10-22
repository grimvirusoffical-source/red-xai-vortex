# FAQ

**Is this my own AI?** The models are free, open models running on your server. **Vortex** is your own layer on top: your persona, your memory, your training data, and your own versions once you train adapters.

**Does anything get sent to other companies?** No, unless you add an outside provider and use its models. Local and server models never leave your machines.

**Do I need a GPU?** No for chat, memory, merges, images and audio (they're slower on a CPU). **Yes, in practice, to train Vortex versions**: rent one for an hour or two.

**Why is a merge slower than one model?** Its steps run one after another to fit in RAM. Router is as fast as one model.

**What's the biggest model I can run?** On 32 GB RAM, up to about a 24B model at good quality or Mixtral 8x7B (IQ4). Pooling with nodes can fit bigger ones, but slower.

**Can friends use it?** Yes. Give each person or app its own key, limited to certain models with a rate limit, and revoke it any time. They can't download models to your server.

**How do I connect ChatGPT-style apps / Cursor / Open WebUI?** Base URL `https://YOUR_DOMAIN/v1` plus your key. See CONNECT.md.

**Will Vortex learn from my private chats?** Only if you turn on Training mode **and** consent. Personal details are scrubbed and the data is encrypted. Turn it off and nothing is collected.

**How do I make Vortex forget something?** Delete a source: `DELETE /admin/redxai/kb?source=<source or prefix*>`.

**What happens when the disk fills up?** At 80%, training data moves (encrypted) to your S3/WebDAV storage, if you've set one up. Models are never moved automatically; uninstall the ones you don't use.

**Why not TeraBox?** Its official API needs an approved developer app. S3-compatible and WebDAV storage work today.

**Can Vortex control my computer?** Not yet. It's designed as an opt-in, ask-every-time local helper.

**Where is my chat history?** On your Mac in `~/Library/Application Support/Red-XAI Vortex/`, and never on the server unless you use training mode.

**Is it open source?** Yes, MIT. The production build uses a private crypto library; the public build uses Go's standard crypto (`-tags stdcrypto`).
