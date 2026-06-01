# 针对非美国用户Codex不显示Computer Use 和 Chrome插件的修复 Codex Computer Use and Browser Plugin Repair

如有问题 For any further questions - K1riko@outlook.com

A small Windows GUI repair tool for Codex Desktop users whose **Computer Use** or browser-control plugin disappeared, became unavailable, or stopped connecting after local cache/native-host issues.

The tool is based on a real troubleshooting case where:

- `Computer Use` was visible but unavailable.
- The browser-control plugin cache was partially rebuilt.
- The bundled plugin marketplace cache and installed plugin cache became inconsistent.
- The Chrome native messaging host had to be checked without manually rewriting OpenAI's host files.

## What It Checks

- Codex bundled plugin cache exists.
- Bundled marketplace cache exists.
- `marketplace/chrome` has `plugin.json` and required browser-control scripts.
- `marketplace/computer-use` has `plugin.json` and required Computer Use scripts.
- Installed browser-control plugin package has `plugin.json` and `browser-client.mjs`.
- Installed Computer Use plugin package has `plugin.json` and `computer-use-client.mjs`.
- Browser native host registry entry exists.
- Native host manifest is valid and points to an existing `extension-host.exe`.
- Codex browser extension is installed in the local browser profile used by the native host chain.
- Codex appears to be installed on the C drive.

## What Repair Does

Repair does **not** edit OpenAI plugin manifests by hand and does **not** delete private files.

It:

1. Requires Codex and the browser to be fully closed.
2. Stops stale `extension-host.exe` processes that are still locking Codex plugin cache paths.
3. Moves the following cache folders to `%USERPROFILE%\.codex\backups`:
   - `%USERPROFILE%\.codex\plugins\cache\openai-bundled`
   - `%USERPROFILE%\.codex\.tmp\bundled-marketplaces\openai-bundled`
4. Lets Codex regenerate the bundled plugin cache on the next launch.

## Usage

Download the repository, then double-click:

```text
Launch-CodexPluginRepair.vbs
```

The launcher hides the PowerShell terminal and opens only the GUI.

You can also run the PowerShell script directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CodexPluginRepair.ps1
```

## Read-Only Self Test

To verify detection without opening the GUI or running repair:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CodexPluginRepair.ps1 -SelfTest
```

This returns JSON and does not move cache folders.

## When To Use

Use this tool when Codex Desktop on Windows shows symptoms such as:

- Computer Use says the plugin is unavailable.
- The browser-control plugin disappears from the Codex plugin UI.
- The browser-control plugin can partially launch a browser but Codex cannot reliably connect.
- Rebooting did not restore the plugin entries.
- The bundled plugin cache appears incomplete or inconsistent.

## What This Tool Does Not Fix

- Codex account-side feature flags.
- Network or VPN issues preventing Codex from downloading bundled plugins.
- General browser login/session problems.
- GitHub, Slack, or other unrelated Codex plugins.
- Codex Desktop UI bugs unrelated to Computer Use or browser-control connectivity.

## Safety Notes

- The repair action moves cache folders to a timestamped backup path.
- It does not delete `.codex` data.
- It does not inspect cookies, browser session stores, passwords, or website data.
- It uses environment variables such as `%USERPROFILE%` and `%LOCALAPPDATA%`; it does not contain user-specific local paths.

## Files

- `CodexPluginRepair.ps1`: GUI tool and detection/repair logic.
- `Launch-CodexPluginRepair.vbs`: no-console launcher for Windows.

## License

MIT
