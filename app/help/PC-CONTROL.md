# PC control (planned)

Status: **design only. Nothing in this release can control a computer.**

Vortex will be able to operate your own computer through a small local agent that you install and switch on yourself.

Rules the agent will follow:
- **Off by default.** It only runs while you have it switched on in the app on that machine.
- **Local consent only.** Requests from the server or other apps are queued on your machine and do nothing until you approve them there. Nothing can turn it on remotely.
- **Every action is confirmed** in a local dialog that shows exactly what will run (app, command, file, keystrokes), with Allow once / Deny.
- **Allowlist**: only the apps, folders and commands you list. Everything else is refused without asking.
- **Kill switch**: a global hotkey and a menu-bar button stop the agent and revoke its session at once. It also stops when the app quits.
- **Audit log** of every request, approval and result, stored locally.
- macOS uses the Accessibility and Screen Recording permissions, which you grant in System Settings and can revoke at any time.

Training: approved action sequences (with your consent) become examples for Vortex, the same way chat feedback does.
