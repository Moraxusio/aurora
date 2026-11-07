# Types text into a process's window the way a keyboard does (SendInput):
# ASCII as virtual keys with Shift where needed, everything else as Unicode
# key packets (what an IME delivers), "`n" as Enter. Used by the UI tests to
# check the real Windows input path, which flutter_test's key events skip.
#   sendkeys.ps1 -ProcessId N -Base64 <UTF-8 text, base64>
param([Parameter(Mandatory)][int]$ProcessId, [Parameter(Mandatory)][string]$Base64)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class Keys {
  [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx; public int dy; public uint data; public uint flags; public uint time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }
  [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] static extern short VkKeyScan(char c);
  [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  const uint UP = 2, UNICODE = 4;
  static void Send(ushort vk, ushort scan, uint flags) {
    var i = new INPUT[1];
    i[0].type = 1;
    i[0].u.ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags };
    if (SendInput(1, i, Marshal.SizeOf(typeof(INPUT))) != 1) throw new Exception("SendInput failed: " + Marshal.GetLastWin32Error());
    Thread.Sleep(15);
  }
  static void Vk(ushort vk, bool up) { Send(vk, (ushort)MapVirtualKey(vk, 0), up ? UP : 0); }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  static string Describe(IntPtr h) {
    if (h == IntPtr.Zero) return "no window";
    var sb = new System.Text.StringBuilder(256);
    GetWindowText(h, sb, 256);
    uint pid; GetWindowThreadProcessId(h, out pid);
    string proc = "?";
    try { proc = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
    return "'" + sb + "' (" + proc + ", pid " + pid + ")";
  }
  public static void Focus(IntPtr h) {
    // A background process may only move the focus after a key press.
    keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, UP, UIntPtr.Zero);
    SetForegroundWindow(h);
    Thread.Sleep(300);
  }
  public static void Type(IntPtr h, string s) {
    foreach (char c in s) {
      // Never type into another window, should the focus move meanwhile: try
      // to take it back a few times, and stop with the culprit's name if not.
      for (int tries = 0; GetForegroundWindow() != h; tries++) {
        if (tries == 3) throw new Exception("the window lost the focus to " + Describe(GetForegroundWindow()) + "; stopped typing");
        Focus(h);
      }
      if (c == '\n') { Vk(0x0D, false); Vk(0x0D, true); continue; }
      short k = c < 128 ? VkKeyScan(c) : (short)-1;
      if (k == -1) { Send(0, c, UNICODE); Send(0, c, UNICODE | UP); continue; }
      ushort vk = (ushort)(k & 0xff); bool shift = (k & 0x100) != 0;
      if (shift) Vk(0x10, false);
      Vk(vk, false); Vk(vk, true);
      if (shift) Vk(0x10, true);
    }
  }
}
'@
$p = Get-Process -Id $ProcessId
$h = $p.MainWindowHandle
if ($h -eq [IntPtr]::Zero) { throw "process $ProcessId has no window" }
[Keys]::Focus($h)
if ([Keys]::GetForegroundWindow() -ne $h) { throw 'could not bring the window to the front' }
[Keys]::Type($h, [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64)))
