# PC control (build 20)

The **vortex** and **red-xai** models can act on your Mac through tools. Other models never get these tools.

## Turning it on
1. Open **Hub → PC Control**. Every switch is **off** until you turn it on.
2. Turn on only what you need:

| Switch | Tools | Asks first? |
|---|---|---|
| Read files & folders | `pc_list_dir`, `pc_read_file` | no |
| Write, move & delete files | `pc_write_file`, `pc_move_file`, `pc_delete_file` (to the Trash) | **always** |
| Run shell commands | `pc_shell` (zsh, 60 s limit) | **always** |
| Open & quit apps | `pc_open_app`, `pc_list_apps`, `pc_quit_app` | quitting: **always** |
| Keyboard & mouse | `pc_type_text`, `pc_key`, `pc_click` | **always** |
| Screenshots | `pc_screenshot` (returns the text on screen) | no |
| Browser | `pc_open_url`, `pc_browser_tab` | no |
| Clipboard | `pc_clipboard_read`, `pc_clipboard_write` | replacing: **always** |

3. In the chat, pick `vortex` or `red-xai` and make sure the 🔧 button is on.

## Safety
- **Confirmation:** destructive actions show **Allow once / Deny** with the exact arguments. Nothing approves them automatically.
- **Indicator:** a floating "Vortex is controlling this Mac" bar with a **Stop** button appears while actions run.
- **Kill switch:** **Stop** on the bar, or **Stop everything** in Hub → PC Control, ends the current reply and blocks all PC tools until you click **Allow PC control again**.
- **Action log:** every action, denial and setting change is written to `~/Library/Application Support/Red-XAI Vortex/pc-actions.log`. You can view it in Hub → PC Control.
- **Permissions:**
  - Keyboard & mouse need **Accessibility**.
  - Screenshots need **Screen Recording**.
  - Use the **Request** and **Open Settings** buttons to grant them. You can revoke them in System Settings at any time.
- Everything runs locally in the app. A server or another app cannot turn PC control on.
