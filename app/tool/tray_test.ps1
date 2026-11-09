# Isolated Windows tray / single-instance acceptance for Aurora 3.
# Uses a unique AURORA3_INSTANCE_SCOPE and a temporary LOCALAPPDATA, so it never
# touches a running client or the real profile. The window may briefly appear
# and steal focus while it runs.
param(
  [string]$Exe = (Join-Path $PSScriptRoot '..\build\windows\x64\runner\Debug\aurora.exe')
)
$ErrorActionPreference = 'Stop'
$Exe = (Resolve-Path $Exe).Path

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class Win {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static IntPtr Find(uint pid, string cls) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid) return true;
      var sb = new StringBuilder(256); GetClassName(h, sb, 256);
      if (sb.ToString() == cls) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
'@

$cls = 'AURORA3_RUNNER_WIN32_WINDOW'
$scope = 'tray-test-' + [guid]::NewGuid().ToString('N')
$tmp = Join-Path ([IO.Path]::GetTempPath()) $scope
New-Item -ItemType Directory -Path $tmp | Out-Null
$env:AURORA3_INSTANCE_SCOPE = $scope
$env:LOCALAPPDATA = $tmp
$env:APPDATA = $tmp

$script:fail = 0
function Check([string]$name, [bool]$ok) {
  if ($ok) { Write-Host "PASS  $name" } else { Write-Host "FAIL  $name"; $script:fail++ }
}
function WaitFor([scriptblock]$cond, [int]$ms = 20000) {
  $end = [DateTime]::UtcNow.AddMilliseconds($ms)
  while ([DateTime]::UtcNow -lt $end) {
    if (& $cond) { return $true }
    Start-Sleep -Milliseconds 150
  }
  return $false
}

$first = $null
try {
  $first = Start-Process -FilePath $Exe -PassThru
  $hwnd = [IntPtr]::Zero
  $up = WaitFor { $script:hwnd = [Win]::Find([uint32]$first.Id, $cls); $script:hwnd -ne [IntPtr]::Zero -and [Win]::IsWindowVisible($script:hwnd) } 30000
  Check 'first instance shows its window' $up
  if (-not $up) { throw 'window never appeared' }
  $hwnd = $script:hwnd

  [void][Win]::PostMessage($hwnd, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
  $hidden = WaitFor { -not [Win]::IsWindowVisible($hwnd) } 8000
  Check 'WM_CLOSE hides the window' $hidden
  Start-Sleep -Milliseconds 800
  $first.Refresh()
  Check 'process stays alive after close' (-not $first.HasExited)

  $second = Start-Process -FilePath $Exe -PassThru
  $restored = WaitFor { [Win]::IsWindowVisible($hwnd) } 10000
  Check 'second launch restores the original window' $restored
  $exited = $second.WaitForExit(10000)
  Check 'second launch exits by itself' $exited
  if ($exited) { Check 'second launch exit code is 0' ($second.ExitCode -eq 0) }
  elseif (-not $second.HasExited) { $second.Kill() }
  $first.Refresh()
  Check 'primary still alive after second launch' (-not $first.HasExited)

  [void][Win]::PostMessage($hwnd, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
  Check 'hide again' (WaitFor { -not [Win]::IsWindowVisible($hwnd) } 8000)

  # Tray menu 'exit' command id.
  [void][Win]::PostMessage($hwnd, 0x111, [IntPtr]31002, [IntPtr]::Zero)
  Check 'tray exit command ends the process' ($first.WaitForExit(15000))
}
catch {
  Write-Host "ERROR $($_.Exception.Message)"
  $script:fail++
}
finally {
  if ($first -and -not $first.HasExited) { $first.Kill() }
  Get-Process aurora -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $Exe -and $_.StartTime -gt (Get-Date).AddMinutes(-3) -and $_.Id -eq $first.Id } |
    ForEach-Object { $_.Kill() }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($script:fail -gt 0) { Write-Host "FAILED: $script:fail"; exit 1 }
Write-Host 'ALL PASS'
