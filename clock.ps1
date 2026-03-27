Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class IconHelper {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr ExtractIcon(IntPtr hInst, string lpszExeFileName, int nIconIndex);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
}
"@

$iconHandle = [IconHelper]::ExtractIcon([IntPtr]::Zero, "imageres.dll", 24)
$clockIcon = if ($iconHandle -ne [IntPtr]::Zero) {
    [System.Drawing.Icon]::FromHandle($iconHandle)
} else {
    [System.Drawing.SystemIcons]::Application
}

[IconHelper]::SetCurrentProcessExplicitAppUserModelID("MiniClock.App") | Out-Null

# --- State ---
$script:lastClickTime = $null
$script:startTime = [DateTime]::Now
$script:rightClickTimer = $null  # elapsed timer started by right-click
$script:alarmSeconds = 180        # default alarm threshold (3 minutes)
$script:alarmFired = $false       # has alarm fired for current break?
$script:alarmFlashOn = $false     # flash toggle state

# --- Alarm sound: synthesized ascending chime ---
function PlayAlarmSound {
    $sampleRate = 22050
    # Ascending major arpeggio: C5 E5 G5 C6, with a richer final note
    $notes = @(
        @{Freq=523.25; Dur=0.13},
        @{Freq=659.25; Dur=0.13},
        @{Freq=783.99; Dur=0.13},
        @{Freq=1046.50; Dur=0.30}
    )

    $pcmMs = New-Object System.IO.MemoryStream
    $pcmBw = New-Object System.IO.BinaryWriter($pcmMs)

    foreach ($note in $notes) {
        $numSamples = [int]($sampleRate * $note.Dur)
        for ($i = 0; $i -lt $numSamples; $i++) {
            $t = $i / $sampleRate
            $env = [Math]::Sin($i / $numSamples * [Math]::PI)
            # Fundamental + soft 2nd harmonic + touch of 3rd for warmth
            $v  = [Math]::Sin(2 * [Math]::PI * $note.Freq * $t) * 0.65
            $v += [Math]::Sin(2 * [Math]::PI * $note.Freq * 2 * $t) * 0.20
            $v += [Math]::Sin(2 * [Math]::PI * $note.Freq * 3 * $t) * 0.08
            $pcmBw.Write([int16]($v * $env * 14000))
        }
        # Tiny gap between notes
        for ($i = 0; $i -lt [int]($sampleRate * 0.03); $i++) { $pcmBw.Write([int16]0) }
    }
    $pcmBw.Flush()
    $pcmData = $pcmMs.ToArray()

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $dataSize = $pcmData.Length
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("RIFF"))
    $bw.Write([int32]($dataSize + 36))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("WAVE"))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("fmt "))
    $bw.Write([int32]16)
    $bw.Write([int16]1)
    $bw.Write([int16]1)
    $bw.Write([int32]$sampleRate)
    $bw.Write([int32]($sampleRate * 2))
    $bw.Write([int16]2)
    $bw.Write([int16]16)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("data"))
    $bw.Write([int32]$dataSize)
    $bw.Write($pcmData)
    $bw.Flush()
    $ms.Position = 0

    $player = New-Object System.Media.SoundPlayer($ms)
    $player.Play()
}

# HSL-to-RGB for color cycling (saturation=1, lightness=0.6 for vivid pastels)
function HslToColor([double]$h, [double]$s, [double]$l) {
    $c = (1 - [Math]::Abs(2 * $l - 1)) * $s
    $x = $c * (1 - [Math]::Abs(($h / 60) % 2 - 1))
    $m = $l - $c / 2
    if     ($h -lt 60)  { $r=$c; $g=$x; $b=0 }
    elseif ($h -lt 120) { $r=$x; $g=$c; $b=0 }
    elseif ($h -lt 180) { $r=0;  $g=$c; $b=$x }
    elseif ($h -lt 240) { $r=0;  $g=$x; $b=$c }
    elseif ($h -lt 300) { $r=$x; $g=0;  $b=$c }
    else                { $r=$c; $g=0;  $b=$x }
    [System.Drawing.Color]::FromArgb(
        [int](($r + $m) * 255),
        [int](($g + $m) * 255),
        [int](($b + $m) * 255))
}

# --- Form setup ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Mini Clock"
$form.TopMost = $true
$form.Icon = $clockIcon
$form.Size = New-Object System.Drawing.Size(450, 210)
$form.MinimumSize = New-Object System.Drawing.Size(200, 100)
$form.BackColor = [System.Drawing.Color]::Black
$form.StartPosition = "CenterScreen"

# Main time label
$label = New-Object System.Windows.Forms.Label
$label.ForeColor = [System.Drawing.Color]::White
$label.TextAlign = "MiddleCenter"
$label.Text = (Get-Date -Format "hh:mm:ss tt")
$label.Cursor = [System.Windows.Forms.Cursors]::Hand

# Lap/stopwatch label (smaller, below the clock)
$lapLabel = New-Object System.Windows.Forms.Label
$lapLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
$lapLabel.TextAlign = "MiddleCenter"
$lapLabel.Text = "click to start lap timer"
$lapLabel.Cursor = [System.Windows.Forms.Cursors]::Hand

# Elapsed timer label (right-click triggered, separate from lap)
$elapsedLabel = New-Object System.Windows.Forms.Label
$elapsedLabel.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$elapsedLabel.TextAlign = "MiddleCenter"
$elapsedLabel.Text = "right-click to start timer"
$elapsedLabel.Cursor = [System.Windows.Forms.Cursors]::Hand

# Alarm controls panel
$alarmPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$alarmPanel.Dock = "Fill"
$alarmPanel.BackColor = [System.Drawing.Color]::Black
$alarmPanel.Anchor = "None"
$alarmPanel.AutoSize = $false
$alarmPanel.WrapContents = $false
$alarmPanel.FlowDirection = "LeftToRight"
$alarmPanel.Padding = New-Object System.Windows.Forms.Padding(0)

$alarmLabel = New-Object System.Windows.Forms.Label
$alarmLabel.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 140)
$alarmLabel.Text = "alarm: 3:00"
$alarmLabel.TextAlign = "MiddleCenter"
$alarmLabel.AutoSize = $true
$alarmLabel.Margin = New-Object System.Windows.Forms.Padding(4, 2, 2, 0)

$btnMinus = New-Object System.Windows.Forms.Button
$btnMinus.Text = "-"
$btnMinus.FlatStyle = "Flat"
$btnMinus.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
$btnMinus.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
$btnMinus.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$btnMinus.Size = New-Object System.Drawing.Size(28, 22)
$btnMinus.Margin = New-Object System.Windows.Forms.Padding(2, 2, 0, 0)
$btnMinus.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnMinus.Add_Click({
    if ($script:alarmSeconds -gt 30) {
        $script:alarmSeconds -= 30
        $script:alarmFired = $false
        $m = [Math]::Floor($script:alarmSeconds / 60)
        $s = $script:alarmSeconds % 60
        $alarmLabel.Text = "alarm: {0}:{1:D2}" -f $m, $s
    }
})

$btnPlus = New-Object System.Windows.Forms.Button
$btnPlus.Text = "+"
$btnPlus.FlatStyle = "Flat"
$btnPlus.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
$btnPlus.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
$btnPlus.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$btnPlus.Size = New-Object System.Drawing.Size(28, 22)
$btnPlus.Margin = New-Object System.Windows.Forms.Padding(2, 2, 0, 0)
$btnPlus.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnPlus.Add_Click({
    $script:alarmSeconds += 30
    $script:alarmFired = $false
    $m = [Math]::Floor($script:alarmSeconds / 60)
    $s = $script:alarmSeconds % 60
    $alarmLabel.Text = "alarm: {0}:{1:D2}" -f $m, $s
})

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = "Test"
$btnTest.FlatStyle = "Flat"
$btnTest.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 100)
$btnTest.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
$btnTest.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(100, 80, 40)
$btnTest.Size = New-Object System.Drawing.Size(44, 22)
$btnTest.Margin = New-Object System.Windows.Forms.Padding(8, 2, 0, 0)
$btnTest.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnTest.Add_Click({ PlayAlarmSound })

$alarmPanel.Controls.Add($alarmLabel)
$alarmPanel.Controls.Add($btnMinus)
$alarmPanel.Controls.Add($btnPlus)
$alarmPanel.Controls.Add($btnTest)

# Layout: use a TableLayoutPanel — clock gets most space, lap, elapsed, and alarm get the rest
$table = New-Object System.Windows.Forms.TableLayoutPanel
$table.Dock = "Fill"
$table.RowCount = 4
$table.ColumnCount = 1
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 50)))
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 18)))
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 18)))
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 14)))
$label.Dock = "Fill"
$lapLabel.Dock = "Fill"
$elapsedLabel.Dock = "Fill"
$alarmPanel.Dock = "Fill"
$table.Controls.Add($label, 0, 0)
$table.Controls.Add($lapLabel, 0, 1)
$table.Controls.Add($elapsedLabel, 0, 2)
$table.Controls.Add($alarmPanel, 0, 3)
$form.Controls.Add($table)

# Auto-scale fonts to fill the window
$resizeFont = {
    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height
    $mainSize = [Math]::Max(8, [Math]::Min($w / 10, $h / 2.5))
    $lapSize  = [Math]::Max(7, $mainSize * 0.5)
    $alarmSize = [Math]::Max(7, $mainSize * 0.35)
    $label.Font        = New-Object System.Drawing.Font("Consolas", $mainSize, [System.Drawing.FontStyle]::Bold)
    $lapLabel.Font     = New-Object System.Drawing.Font("Consolas", $lapSize)
    $elapsedLabel.Font = New-Object System.Drawing.Font("Consolas", $lapSize)
    $alarmLabel.Font   = New-Object System.Drawing.Font("Consolas", $alarmSize)
    $btnMinus.Font     = New-Object System.Drawing.Font("Consolas", $alarmSize, [System.Drawing.FontStyle]::Bold)
    $btnPlus.Font      = New-Object System.Drawing.Font("Consolas", $alarmSize, [System.Drawing.FontStyle]::Bold)
    $btnTest.Font      = New-Object System.Drawing.Font("Consolas", [Math]::Max(7, $alarmSize * 0.9))
}

$form.Add_Resize($resizeFont)
$form.Add_Shown($resizeFont)

# --- Click handlers (lap timer) ---
$onClick = {
    if ($null -eq $script:lastClickTime) {
        $script:lastClickTime = [DateTime]::Now
        $script:alarmFired = $false
        $lapLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 200, 120)
        $lapLabel.Text = "+00:00:00  (timing...)"
    } else {
        # Freeze the elapsed time display and reset
        $elapsed = [DateTime]::Now - $script:lastClickTime
        $lapLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 60)
        $lapLabel.Text = "lap: " + $elapsed.ToString("hh\:mm\:ss") + "  (click for new)"
        $script:lastClickTime = [DateTime]::Now
        $script:alarmFired = $false
    }
}

$onRightClick = {
    if ($null -eq $script:rightClickTimer) {
        $script:rightClickTimer = [DateTime]::Now
        $elapsedLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 180, 255)
        $elapsedLabel.Text = "00:00  elapsed"
    } else {
        $script:rightClickTimer = $null
        $elapsedLabel.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
        $elapsedLabel.Text = "right-click to start timer"
    }
}

$label.Add_MouseUp({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $onClick }
    elseif ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) { & $onRightClick }
})
$lapLabel.Add_MouseUp({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $onClick }
    elseif ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) { & $onRightClick }
})
$elapsedLabel.Add_MouseUp({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) { & $onRightClick }
})

# --- Main tick timer (100ms for smooth animations) ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({
    $now = Get-Date

    # Color cycling: continuous time-based hue (~8 second full rainbow)
    $elapsed = ($now - $script:startTime).TotalSeconds
    $hue = ($elapsed * 45) % 360  # 45 degrees/sec = full cycle in 8s
    $color = HslToColor $hue 1.0 0.62

    # Gentle pulse: smooth sine-wave brightness boost peaking at second boundary
    $ms = $now.Millisecond
    $pulseWindow = 400
    if ($ms -lt $pulseWindow) {
        # Sine ease-out: brightest at ms=0, fades to 0 at $pulseWindow
        $t = $ms / $pulseWindow
        $blend = 0.25 * [Math]::Cos($t * [Math]::PI / 2)
        $r = [Math]::Min(255, [int]($color.R + (255 - $color.R) * $blend))
        $g = [Math]::Min(255, [int]($color.G + (255 - $color.G) * $blend))
        $b = [Math]::Min(255, [int]($color.B + (255 - $color.B) * $blend))
        $color = [System.Drawing.Color]::FromArgb($r, $g, $b)
    }

    $label.ForeColor = $color

    # Smooth colon fade: colons transition from full color to dim using a sine curve
    $colonPhase = ($ms / 1000.0) * 2 * [Math]::PI  # full cycle per second
    $colonAlpha = 0.5 + 0.5 * [Math]::Cos($colonPhase)  # 1.0 at 0ms, 0.0 at 500ms
    $dimR = [int]($color.R * $colonAlpha)
    $dimG = [int]($color.G * $colonAlpha)
    $dimB = [int]($color.B * $colonAlpha)
    $timeStr = $now.ToString("hh mm ss tt")
    $colonColor = [System.Drawing.Color]::FromArgb($dimR, $dimG, $dimB)

    # WinForms Label can't do per-char color, so we swap colons with spaces
    # when they fade below a threshold for a softer blink effect
    $timeStr = $now.ToString("hh:mm:ss tt")
    if ($colonAlpha -lt 0.35) {
        $timeStr = $timeStr.Replace(":", " ")
    }
    $label.Text = $timeStr

    # Update right-click total exercise timer (no alarm)
    if ($null -ne $script:rightClickTimer) {
        $totalElapsed = [DateTime]::Now - $script:rightClickTimer
        $mins = [Math]::Floor($totalElapsed.TotalMinutes)
        $secs = [Math]::Floor($totalElapsed.TotalSeconds) % 60
        $elapsedLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 180, 255)
        $elapsedLabel.Text = ("{0:D2}:{1:D2}  elapsed" -f [int]$mins, [int]$secs)
    }
    # Update running lap/break timer + alarm check
    if ($null -ne $script:lastClickTime) {
        $breakElapsed = [DateTime]::Now - $script:lastClickTime
        $wholeSeconds = [TimeSpan]::FromSeconds([Math]::Floor($breakElapsed.TotalSeconds))
        $overAlarm = $breakElapsed.TotalSeconds -ge $script:alarmSeconds

        if ($overAlarm -and -not $script:alarmFired) {
            $script:alarmFired = $true
            PlayAlarmSound
        }

        if ($overAlarm) {
            $script:alarmFlashOn = -not $script:alarmFlashOn
            if ($script:alarmFlashOn) {
                $lapLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 60, 60)
            } else {
                $lapLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 40)
            }
            $lapLabel.Text = "+" + $wholeSeconds.ToString("hh\:mm\:ss") + "  BREAK OVER!"
        } else {
            $lapLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 200, 120)
            $lapLabel.Text = "+" + $wholeSeconds.ToString("hh\:mm\:ss") + "  elapsed"
        }
    }
})
$timer.Start()

[void]$form.ShowDialog()
