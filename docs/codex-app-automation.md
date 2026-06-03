# Codex App Automation

This project can be monitored from a Codex recurring automation.

Recommended schedule:

```text
Every 6 hours
```

Recommended automation prompt:

```text
Check for Codex Desktop updates and keep Codex RTL current.

Run this PowerShell command:

irm https://raw.githubusercontent.com/mnigli/codex-desktop-rtl-patch/main/scripts/codex-rtl-update-monitor.ps1 | iex

The monitor script checks Microsoft Store through winget, installs the official
Codex Store update when one is available, compares the official Codex version
with the local Codex RTL copy, and reapplies the RTL patch when safe.

If the script says Codex RTL is still running, tell the user to use:

Task Manager > Codex > End task

Do not tell the user to close Codex with X, because Electron processes can
remain running in the background and lock app.asar.

If there is no update and Codex RTL is current, do not send a message.
```

The automation should not force-close Codex. It should let the Store update run,
then ask the user to end the Codex task only when the local RTL copy must be
repatched and Codex RTL is still running.
