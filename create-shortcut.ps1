# Creates a desktop shortcut for the clock that can be pinned to the taskbar
$scriptPath = Join-Path $PSScriptRoot "launch.vbs"
$shortcutPath = Join-Path $PSScriptRoot "Mini Clock.lnk"

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "wscript.exe"
$shortcut.Arguments = "`"$scriptPath`""
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.IconLocation = "imageres.dll,24"
$shortcut.Description = "Always-on-top clock"
$shortcut.Save()

Write-Host "Shortcut created on Desktop: 'Mini Clock'"
Write-Host ""
Write-Host "To pin to taskbar:"
Write-Host "  1. Double-click 'Mini Clock' on your Desktop to make sure it works"
Write-Host "  2. While it's running, right-click its icon in the taskbar"
Write-Host "  3. Click 'Pin to taskbar'"
Write-Host ""
Write-Host "Done! You can also just double-click the shortcut anytime."
