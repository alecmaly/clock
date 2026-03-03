# Mini Clock

A minimal always-on-top clock for Windows. Shows the current time with seconds in 12-hour format (AM/PM). Built as a single PowerShell script with no dependencies.

## Usage

Right-click `clock.ps1` → **Run with PowerShell**

Or from a terminal:

```powershell
powershell -ExecutionPolicy Bypass -File clock.ps1
```

## Pin to Taskbar

1. Run the shortcut setup once:

   ```powershell
   powershell -ExecutionPolicy Bypass -File create-shortcut.ps1
   ```

   This creates a `Mini Clock.lnk` shortcut in the same folder.

2. Double-click `Mini Clock.lnk` to launch the clock.
3. While it's running, right-click its icon in the taskbar → **Pin to taskbar**.
4. The shortcut file is no longer needed after pinning.

## Features

- Always-on-top window
- Resizable — font scales automatically
- 12-hour format with seconds (e.g. `02:35:10 PM`)
- No dependencies — just PowerShell and Windows
