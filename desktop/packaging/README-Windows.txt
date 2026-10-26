Red-XAI Vortex 2.10

Keep the application, frontend folder, redx-link, vortex-base, and complete rsx-runtime folder together.

Windows: double-click vortex.exe. Linux: run install.sh, then vortex-app; the installer supports PREFIX and preserves its existing desktop entry and frontend locations.

Use Workspace to organize Projects, XAI Bases, personalities, scoped memory, roleplay worlds, and coding context. Automatic memory and world-state updates start off; enable Review or Save per conversation. Patch application requires Allow in Activity.

Managed Base hosting defaults to this computer only, requires access tokens, and stops when the app exits. Sharing to another computer needs an explicitly configured HTTPS endpoint or TLS tunnel. Create individual expiring invites and revoke them in the hosting controls.

API and connected-document credentials in this Go desktop client use private local files in ~/.config/red-xai-vortex/secrets. This fallback is not an encrypted OS keychain. Chat, workspace and quota controls use the same local configuration directory.

Text and HTML ingestion are included. PDF, image OCR, audio transcription and video extraction detect optional local pdftotext, tesseract, ffmpeg and whisper-cli tools; audio transcription also needs a local Whisper model. The app reports which tools and extraction methods are available. Adding a Base does not train the underlying model.

Release authenticity uses the signed manifest and pinned public keys. Existing 2.8 users need a one-time manual update to 2.10 after the owner-approved signing-key transition. Future 2.10 updates retain signature verification; unsigned updates are refused.
