# Checks watchinput.ps1 on its own, with no person involved:
#  1. keys sent with SendInput (what the typing test does) are NOT reported as a person;
#  2. a key that is not injected IS reported (a key sent through a driver-level
#     path is not available here, so this part uses the one non-injected path
#     Windows offers a script: none. It is checked by hand, see below);
#  3. a change of the foreground window away from the watched process is reported.
# Part 2 cannot be automated without a keyboard driver, so this test covers 1 and
# 3 and prints how to check 2 once by pressing a key during the 5 s window.
#   powershell -File app\tool\watchinput_selftest.ps1 [-PressAKey]
param([switch]$PressAKey)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
# the process to watch: a console window of our own (the Windows 11 notepad is a launcher with no window of its own)
$np = Start-Process powershell -ArgumentList '-NoProfile','-NoExit','-Command','$host.UI.RawUI.WindowTitle=''watchinput-target''' -PassThru
Start-Sleep -Seconds 3
if (-not $np.MainWindowHandle -or $np.MainWindowHandle -eq [IntPtr]::Zero) { $np.Refresh() }
try {
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell'
    $psi.Arguments = "-NoProfile -File `"$here\watchinput.ps1`" -ProcessId $($np.Id)"
    $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $w = [Diagnostics.Process]::Start($psi)
    $lines = New-Object Collections.Generic.List[string]
    $null = Register-ObjectEvent $w OutputDataReceived -Action { $Event.MessageData.Add($EventArgs.Data) } -MessageData $lines
    $w.BeginOutputReadLine()
    $t0 = Get-Date
    while (-not ($lines -contains 'READY') -and ((Get-Date) - $t0).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 100 }
    if (-not ($lines -contains 'READY')) { throw 'the watcher did not report READY' }
    "READY after {0:N1} s" -f ((Get-Date) - $t0).TotalSeconds

    # 1. injected keys: bring the target to the front, type with SendInput, expect no HUMAN line
    Add-Type -Namespace W -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);'
    $np.Refresh(); [W.U]::SetForegroundWindow($np.MainWindowHandle) | Out-Null; Start-Sleep -Milliseconds 500
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('injected keys only'))
    & powershell -NoProfile -File "$here\sendkeys.ps1" -ProcessId $np.Id -Base64 $b64 | Out-Null
    Start-Sleep -Milliseconds 400
    $human = @($lines | Where-Object { $_ -like 'HUMAN*' })
    "1. injected keys reported as a person: $($human.Count)  (must be 0)"

    # 3. move the foreground to another window: the watcher must say FOCUS out
    $other = Start-Process cmd -ArgumentList '/k title watchinput-selftest' -PassThru
    Start-Sleep -Seconds 2; $other.Refresh(); [W.U]::SetForegroundWindow($other.MainWindowHandle) | Out-Null; Start-Sleep -Milliseconds 800
    $out = @($lines | Where-Object { $_ -like 'FOCUS*out' })
    "3. focus taken by another window reported: $($out.Count)  (must be >= 1)"
    $other | Stop-Process -Force -ErrorAction SilentlyContinue

    if ($PressAKey) {
        "2. press any key now (you have 6 s)..."; Start-Sleep -Seconds 6
        "   keys reported as a person: $(@($lines | Where-Object { $_ -like 'HUMAN*' }).Count - $human.Count)  (must be >= 1 if you pressed one)"
    }
    $ok = ($human.Count -eq 0) -and ($out.Count -ge 1)
    if ($ok) { 'self-test: PASS' } else { 'self-test: FAIL'; $lines | ForEach-Object { "  $_" } }
    $w.Kill()
    exit ([int](-not $ok))
} finally {
    $np | Stop-Process -Force -ErrorAction SilentlyContinue
}
