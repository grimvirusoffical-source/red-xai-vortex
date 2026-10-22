# Chat features: files, plugins, skills, MCP, voice and group chat

These arrived in app builds 14 to 19 (version 2.2).

| Build | Feature | Where |
|---|---|---|
| 14 | File upload | **+** button or drag files onto the chat |
| 15 | Plugins and the Plugin Store (with a plugin maker) | Hub → Plugins, or the Plugin Store tab in the model browser |
| 16 | Skills | Skill picker in the chat toolbar, or type `/skill-id` |
| 17 | MCP servers | Hub → MCP |
| 18 | Voice calls | Phone button in the chat toolbar |
| 19 | Group chat | People button in the chat toolbar |
| 20 | PC control | Hub → PC Control (see [PC-CONTROL.md](PC-CONTROL.md)) |

## File upload (build 14)
- Click **+** next to the message box, or drop files onto the chat. Chips above the box show what is attached; click × to remove one.
- Text and code files, PDFs (text is extracted) and images are supported. Images are scaled down and sent as image parts, so pick a vision model such as `gemma3-12b-vision`.
- Attachments count toward the context budget, so very large files are trimmed.

## Plugins and the Plugin Store (build 15)
- Plugins give models **tools** to call. The 🔧 button in the chat toolbar switches tool use on or off for the chat.
- Starters: Web Search, File Reader, Calculator, Weather, Date & Time and Wikipedia. Install, enable or remove them in **Hub → Plugins** or in the **Plugin Store** tab of the model browser.
- **Plugin maker:** in Hub → Plugins click **New plugin**. Each tool is one of:
  - **HTTP**: a URL template whose `{arguments}` are filled in.
  - **JavaScript**: runs in a sandbox with no network or file access and a time limit.
- Models with native tool calling (for example `qwen2.5-14b`) use it. Others, including `vortex` and `red-xai`, use a text protocol that the app understands. Each tool call is listed under the reply.

## Skills (build 16)
- A skill is saved instructions plus a set of tools, and optionally a preferred model.
- Starters: Researcher, Code Reviewer, Summarize a file, Math Tutor and Trip Weather.
- Pick one in the chat toolbar, or type `/researcher` (any skill id) at the start of a message. Type `/off` or pick **No skill** to stop.
- Create and edit skills in **Hub → Skills**.

## MCP servers (build 17)
- **Hub → MCP** connects Model Context Protocol servers. Their tools appear next to plugin tools.
- Two kinds are supported:
  - **stdio**: a command such as `npx -y @modelcontextprotocol/server-filesystem ~/Documents`.
  - **Streamable HTTP**: a URL, with optional headers.
- **Import from Claude Desktop** copies the servers from Claude Desktop's config file.
- **Test** lists the server's tools.

## Voice calls (build 18)
- Click the phone button. The first time, macOS asks for microphone access: click **Allow**.
- **Hold to talk**, or switch on **hands-free**, which starts and stops listening when you speak.
- Everything runs on your Mac. whisper.cpp turns your speech into text, the reply is sent like a normal message, and Piper reads it aloud. If Piper is missing, the built-in macOS voice is used.
- Voice files are stored in `~/Library/Application Support/Red-XAI Vortex/voice`. **Install voice tools** sets them up if they are missing.

## Group chat (build 19)
- Click the people button, add two or more models and set their turn order. Each reply is labelled and coloured by its model.
- Turn order:
  - **Everyone replies, in order**: each model sees the earlier replies and adds something new.
  - **One per message, taking turns**: models answer one at a time, round-robin.
- **@mentions:** `@qwen` (any part of a model id) asks only that model; `@all` asks everyone.
- **Turn off group chat** in the same sheet returns the chat to the single model chosen in the toolbar.
