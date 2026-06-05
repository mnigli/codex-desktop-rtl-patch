# Codex App Automation

This project can be monitored from a Codex recurring automation.

Recommended schedule:

```text
Every 24 hours
```

Recommended automation prompt:

```text
Check for Codex Desktop updates and keep Codex RTL current.

Run this PowerShell command:

irm https://raw.githubusercontent.com/mnigli/codex-desktop-rtl-patch/main/scripts/codex-rtl-update-monitor.ps1 | iex

The monitor script checks an optional external release signal for
@CodexReleases on X, checks Microsoft Store through winget, installs the
official Codex Store update when one is available, detects recent Microsoft
Store/AppX update failures for Codex, compares the official Codex version with
the local Codex RTL copy, and reapplies the RTL patch when safe.

Treat the X check as an early signal only. X does not provide a stable public
unauthenticated feed, so Microsoft Store/AppX remains the source of truth.

If the script says Codex RTL is still running, tell the user to use:

Task Manager > Codex > End task

Do not tell the user to close Codex with X, because Electron processes can
remain running in the background and lock app.asar.

If the script reports that Microsoft Store attempted a newer Codex version but
AppX deployment failed, notify the user with the attempted version and tell them
to retry the Store update after ending the Codex task. If it fails again, suggest
repairing/resetting Microsoft Store and App Installer.

If there is no update and Codex RTL is current, do not send a message.
```

The automation should not force-close Codex. It should let the Store update run,
then ask the user to end the Codex task only when the local RTL copy must be
repatched and Codex RTL is still running.
