Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "Clock"
$form.TopMost = $true
$form.Size = New-Object System.Drawing.Size(450, 150)
$form.MinimumSize = New-Object System.Drawing.Size(150, 70)
$form.BackColor = [System.Drawing.Color]::Black
$form.StartPosition = "CenterScreen"

$label = New-Object System.Windows.Forms.Label
$label.Dock = "Fill"
$label.ForeColor = [System.Drawing.Color]::White
$label.TextAlign = "MiddleCenter"
$label.Text = (Get-Date -Format "hh:mm:ss tt")

# Auto-scale font to fill the window
$resizeFont = {
    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height
    $size = [Math]::Max(8, [Math]::Min($w / 10, $h / 1.8))
    $label.Font = New-Object System.Drawing.Font("Consolas", $size, [System.Drawing.FontStyle]::Bold)
}

$form.Add_Resize($resizeFont)
$form.Add_Shown($resizeFont)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({ $label.Text = Get-Date -Format "hh:mm:ss tt" })
$timer.Start()

$form.Controls.Add($label)
[void]$form.ShowDialog()
