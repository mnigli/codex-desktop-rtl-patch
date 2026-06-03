# Codex Desktop RTL Patch

Unofficial local RTL patch for Codex Desktop on Windows.

This patch improves Hebrew, Arabic, and mixed right-to-left text rendering in
Codex Desktop while keeping code blocks, inline code, terminals, and editor-like
surfaces left-to-right.

## What It Does

- Detects Hebrew/Arabic text and applies `dir="rtl"` where appropriate.
- Uses `unicode-bidi: plaintext` for mixed Hebrew/English paragraphs.
- Keeps `pre`, `code`, terminal, Monaco/CodeMirror-like, and syntax-highlighted
  content left-to-right.
- Switches the Codex composer direction while typing.
- Installs into a local copy of Codex instead of modifying the official app.

## What It Does Not Do

This project intentionally does **not**:

- edit files under `C:\Program Files\WindowsApps`
- replace hashes inside executables
- install certificates
- change Windows Trusted Root stores
- redistribute Codex or any OpenAI app files

The installer copies the locally installed Codex app to:

```powershell
%LOCALAPPDATA%\OpenAI\CodexRtl\app
```

Then it patches only the copied `resources\app.asar` and creates a desktop
shortcut named `Codex RTL`.

## Requirements

- Windows.
- Codex Desktop installed.
- Node.js 22+ with `npx` available.

Check:

```powershell
node --version
npx.cmd --version
```

## Install From GitHub

Close the regular Codex app first.

Run in PowerShell:

```powershell
irm https://raw.githubusercontent.com/mnigli/codex-desktop-rtl-patch/main/install.ps1 | iex
```

Then open Codex from the new desktop shortcut:

```text
Codex RTL
```

If the regular Codex app is still running, Windows/Electron may reuse the
existing instance. Close all Codex windows and launch `Codex RTL` again.

## Install From a Clone

```powershell
git clone https://github.com/mnigli/codex-desktop-rtl-patch.git
cd codex-desktop-rtl-patch
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

## Dry Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
```

## Update After Codex Updates

When Codex updates, rerun the installer:

```powershell
irm https://raw.githubusercontent.com/mnigli/codex-desktop-rtl-patch/main/install.ps1 | iex
```

The installer mirrors the current official Codex app into the local RTL copy
and reapplies the patch.

If Codex RTL is still running, the installer will stop and ask you to end the
Codex task first. On Windows, closing the window with X may leave Electron
processes running in the background. Use:

```text
Task Manager > Codex > End task
```

Then rerun the installer command.

## Automatic Update Monitor

The repository includes an automation-friendly monitor script:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-rtl-update-monitor.ps1
```

Or run the latest monitor directly from GitHub:

```powershell
irm https://raw.githubusercontent.com/mnigli/codex-desktop-rtl-patch/main/scripts/codex-rtl-update-monitor.ps1 | iex
```

The monitor:

- checks Microsoft Store for official Codex updates with `winget`
- installs the official Store update when one is available
- compares the official Codex version with the local Codex RTL copy
- reapplies the RTL patch automatically when Codex RTL is not running
- asks you to use `Task Manager > Codex > End task` when Codex RTL is still open

It uses the Microsoft Store package id for Codex:

```text
9PLM9XGG6VKS
```

For a check-only run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-rtl-update-monitor.ps1 -CheckOnly
```

## Uninstall

From a clone:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Or manually remove:

```powershell
Remove-Item "$env:LOCALAPPDATA\OpenAI\CodexRtl" -Recurse -Force
Remove-Item "$([Environment]::GetFolderPath('Desktop'))\Codex RTL.lnk" -Force
```

Uninstall removes only the local RTL copy and shortcut. It does not remove or
modify the official Codex installation.

## Safety Notice

This is an unofficial patch. Codex UI internals may change, so the patch can
break after app updates. Reinstalling the patch after a Codex update is expected.

Use at your own risk.
