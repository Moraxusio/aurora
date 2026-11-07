# Watches what can spoil a typing test on a desktop that a person also uses:
#  - the person typing: key events that SendInput did not make (the injected
#    flag of a low-level keyboard hook is clear);
#  - another window taking the foreground from the app under test.
# Prints "READY", then one line per event:
#   HUMAN <unix ms> <virtual key>
#   FOCUS <unix ms> out|in
# and runs until killed or until the app under test is gone. It only watches;
# it does not block or change any input.
#   watchinput.ps1 -ProcessId N
param([Parameter(Mandatory)][int]$ProcessId)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public static class Watch {
  delegate IntPtr Proc(int code, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }
  [StructLayout(LayoutKind.Sequential)] struct KBD { public uint vk; public uint scan; public uint flags; public uint time; public IntPtr extra; }
  [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, Proc p, IntPtr mod, uint tid);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint min, uint max);
  [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
  static Proc keep;
  static long Now() { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }
  public static void Run(int pid) {
    var q = new ConcurrentQueue<string>();
    var hooked = new ManualResetEvent(false);
    var th = new Thread(() => {
      keep = (code, w, l) => {
        long m = w.ToInt64();
        if (code >= 0 && (m == 0x100 || m == 0x104)) {
          var k = (KBD)Marshal.PtrToStructure(l, typeof(KBD));
          // LLKHF_INJECTED (0x10) is set for keys that SendInput or keybd_event made
          if ((k.flags & 0x10) == 0) q.Enqueue("HUMAN " + Now() + " " + k.vk);
        }
        return CallNextHookEx(IntPtr.Zero, code, w, l);
      };
      var h = SetWindowsHookEx(13, keep, GetModuleHandle(null), 0);
      if (h == IntPtr.Zero) q.Enqueue("ERROR hook " + Marshal.GetLastWin32Error());
      hooked.Set();
      if (h == IntPtr.Zero) return;
      MSG msg;
      while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
    });
    th.IsBackground = true;
    th.Start();
    hooked.WaitOne(5000);
    var o = Console.Out;
    o.WriteLine("READY");
    o.Flush();
    bool? inApp = null;
    int n = 0;
    while (true) {
      uint fp;
      GetWindowThreadProcessId(GetForegroundWindow(), out fp);
      bool now = fp == (uint)pid;
      if (inApp == null || inApp.Value != now) {
        if (inApp != null) q.Enqueue("FOCUS " + Now() + (now ? " in" : " out"));
        inApp = now;
      }
      string s;
      while (q.TryDequeue(out s)) o.WriteLine(s);
      o.Flush();
      if (++n % 50 == 0) { try { Process.GetProcessById(pid); } catch { return; } }
      Thread.Sleep(20);
    }
  }
}
'@
[Watch]::Run($ProcessId)
