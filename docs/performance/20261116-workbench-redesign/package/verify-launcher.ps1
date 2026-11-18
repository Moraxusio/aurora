param([Parameter(Mandatory)][string]$Package)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-accessibility.ps1')
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class LauncherWindow {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    public static IntPtr Find(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h,l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var text = new StringBuilder(256); GetClassName(h,text,256);
            if (text.ToString() == "AURORA3_RUNNER_WIN32_WINDOW") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
function WaitFor([scriptblock]$Check, [int]$Seconds = 30) {
    $end = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $end) {
        if (& $Check) { return }
        Start-Sleep -Milliseconds 200
    }
    throw 'Timed out waiting for launcher state'
}
$exe = Join-Path $Package 'aurora.exe'
$launcher = Join-Path $Package '启动验收版.cmd'
$review = Join-Path $Package 'review-data'
if (Test-Path -LiteralPath $review) { throw 'Expected pristine extracted review directory' }
if (@(Get-Process aurora -ErrorAction SilentlyContinue | Where-Object Path -eq $exe).Count) { throw 'This extracted copy is already running' }
# A real copy of this candidate may already be open. Change only the instance
# scope in this disposable extracted launcher to avoid activating that copy.
$launcherText = [IO.File]::ReadAllText($launcher)
$originalScope = 'set "AURORA3_INSTANCE_SCOPE=Aurora-3.24.0-workbench-preview1"'
if (-not $launcherText.Contains($originalScope)) { throw 'Unexpected launcher scope' }
$scope = 'launcher-smoke-' + [guid]::NewGuid().ToString('N')
[IO.File]::WriteAllText($launcher, $launcherText.Replace($originalScope, "set `"AURORA3_INSTANCE_SCOPE=$scope`""), [Text.Encoding]::ASCII)
Write-Output "Fixture-only instance scope: $scope"
$first = $null
try {
    & $env:ComSpec /d /c "call `"$launcher`""
    WaitFor {
        $script:first = Get-Process aurora -ErrorAction SilentlyContinue | Where-Object Path -eq $exe | Select-Object -First 1
        if (-not $script:first) { return $false }
        $script:window = [LauncherWindow]::Find([uint32]$script:first.Id)
        return $script:window -ne [IntPtr]::Zero -and [LauncherWindow]::IsWindowVisible($script:window)
    }
    $first = $script:first
    Write-Output "PASS actual CMD launcher opens Release window PID $($first.Id)"
    foreach ($path in @('Local','Roaming','Home')) {
        if (-not (Test-Path -LiteralPath (Join-Path $review $path))) { throw "Isolation folder missing: $path" }
    }
    WaitFor { Test-Path -LiteralPath "$review\Local\Aurora3\profile.bin" }
    $profile = [IO.File]::ReadAllBytes("$review\Local\Aurora3\profile.bin")
    if ([Text.Encoding]::ASCII.GetString($profile,0,8) -ne 'AURORA3P') { throw 'Isolated profile has wrong format' }
    WaitFor {
        $script:labels = [NativeAccessible]::Names($script:window)
        return @($script:labels | Where-Object { $_ -like '*打开本机文件夹*' }).Count -gt 0
    }
    $script:labels | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'release-startup-ui.txt') -Encoding utf8
    Write-Output 'PASS local-workspace semantics and isolated encrypted profile'
    [void][LauncherWindow]::PostMessage($script:window,0x10,[IntPtr]::Zero,[IntPtr]::Zero)
    WaitFor { -not [LauncherWindow]::IsWindowVisible($script:window) }
    & $env:ComSpec /d /c "call `"$launcher`""
    WaitFor { [LauncherWindow]::IsWindowVisible($script:window) }
    WaitFor { @(Get-Process aurora -ErrorAction SilentlyContinue | Where-Object Path -eq $exe).Count -eq 1 }
    Write-Output 'PASS repeated CMD launch restores the same isolated process'
    [void][LauncherWindow]::PostMessage($script:window,0x111,[IntPtr]31002,[IntPtr]::Zero)
    WaitFor {
        return [NativeAccessible]::Names($script:window) -contains '结束本地任务并退出'
    }
    WaitFor { [NativeAccessible]::Invoke($script:window,'结束本地任务并退出') }
    Write-Output 'PASS actual local-task exit confirmation'
    if (-not $first.WaitForExit(15000)) { throw 'Launcher process did not exit' }
    $remaining = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like "$Package\local-agent\*" })
    if ($remaining.Count) { throw 'Packaged agent remained alive' }
    Write-Output 'PASS launcher exit and local-agent cleanup'
    Write-Output 'RELEASE_CMD_LAUNCHER_ISOLATION_RESTORE_EXIT_OK'
} catch {
    if ($script:window -ne [IntPtr]::Zero) {
        [NativeAccessible]::Names($script:window) |
            Set-Content -LiteralPath (Join-Path $PSScriptRoot 'release-failure-ui.txt') -Encoding utf8
    }
    throw
} finally {
    if ($first -and -not $first.HasExited) { $first.Kill() }
}
