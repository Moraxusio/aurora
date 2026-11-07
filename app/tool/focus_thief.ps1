# A window of another program that takes the foreground for a few seconds, as
# a window the user clicks on would. Used to check that the typing test notices
# it (app/tool/watchinput.ps1) and does not count the lines typed meanwhile as
# the program's fault. It is a real Windows Forms window with its own handle.
#   focus_thief.ps1 [-Seconds 3]
param([int]$Seconds = 3)
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.Form
$f.Text = 'focus-thief'
$f.Width = 320; $f.Height = 120
$f.StartPosition = 'CenterScreen'
$f.TopMost = $true
$f.Add_Shown({ $f.Activate() })
$t = New-Object System.Windows.Forms.Timer
$t.Interval = $Seconds * 1000
$t.Add_Tick({ $f.Close() })
$t.Start()
[void]$f.ShowDialog()
