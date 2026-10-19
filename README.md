# GTA Usage HUD

A small always-on-top overlay for the Codex app's 5-hour and weekly usage limits.

## Requirements and launch

- Windows with Windows PowerShell 5.1 and the Codex desktop app installed and signed in.
- Extract the project folder, then double-click `Start HUD.vbs`. To close the HUD, run `Stop HUD.ps1`.
- If `codex.exe` is not on PATH, the script checks the installed Codex app folders. You can set `CODEX_EXECUTABLE` to its full path to select it explicitly.

Right-click the HUD or its tray icon for controls. Drag the HUD to move it; drag the lower-right grip to resize. The tray menu offers Small, Medium, Large, position reset, refresh, and always-on-top. The layout starts editable; choose Lock layout to make it click-through. Press Ctrl+Alt+H to unlock it. The HUD appears while a Codex or ChatGPT app window is restored and hides when all matching windows are minimized or closed. Position and settings are saved in `hud-settings.json`. It does not register itself to start with Windows.

## What the bars show

Pink is the percentage remaining in the Codex Work account's 5-hour usage window; mint is weekly usage remaining; purple is the time until the 5-hour window resets. These are account rate limits supplied by the installed Codex app-server. They do not measure general ChatGPT messages, tokens, or total subscription usage. Values refresh once a minute and can be refreshed from the tray. The HUD marks values stale after five minutes and hides stale bars; it does not estimate missing values.

`usage.json` contains the latest local snapshot and `hud-settings.json` contains local display settings. Both are generated or updated at runtime and are excluded from Git. Authentication is handled by the signed-in Codex app; this project does not read credential files.

The included preview and icon shapes are an unofficial community reference and are not affiliated with or endorsed by OpenAI.
