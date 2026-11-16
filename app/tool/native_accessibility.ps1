# Query Flutter's native MSAA tree, scoped to one test window. Flutter's
# FLUTTERVIEW does not expose the semantic descendants through UIA here.
Add-Type -AssemblyName Accessibility
Add-Type -ReferencedAssemblies Accessibility @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Accessibility;
public static class NativeAccessible {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
    [DllImport("oleacc.dll")]
    static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint id, ref Guid iid,
        [MarshalAs(UnmanagedType.Interface)] out object accessible);
    [DllImport("oleacc.dll")]
    static extern int AccessibleChildren(IAccessible root, int start, int count,
        [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex=2)] object[] children, out int obtained);
    static IAccessible Root(IntPtr hwnd) {
        var child = FindWindowEx(hwnd, IntPtr.Zero, "FLUTTERVIEW", null);
        if (child == IntPtr.Zero) return null;
        var iid = new Guid("618736e0-3c3d-11cf-810c-00aa00389b71");
        object value;
        return AccessibleObjectFromWindow(child, 0xFFFFFFFC, ref iid, out value) >= 0 ? value as IAccessible : null;
    }
    static bool Visit(IAccessible node, object id, int depth, List<string> names, string invoke) {
        if (depth > 60 || names.Count > 5000) return false;
        string name = "";
        try { name = node.get_accName(id) ?? ""; } catch {}
        if (name.Length > 0) names.Add(name);
        if (invoke != null && name == invoke) { node.accDoDefaultAction(id); return true; }
        if (!(id is int) || (int)id != 0) return false;
        int count;
        try { count = Math.Min(node.accChildCount, 5000); } catch { return false; }
        if (count == 0) return false;
        var children = new object[count];
        int obtained;
        if (AccessibleChildren(node,0,count,children,out obtained) < 0) return false;
        for (int i = 0; i < obtained; i++) {
            var accessible = children[i] as IAccessible;
            if (accessible != null) {
                if (Visit(accessible,0,depth+1,names,invoke)) return true;
            } else if (children[i] is int) {
                if (Visit(node,children[i],depth+1,names,invoke)) return true;
            }
        }
        return false;
    }
    public static string[] Names(IntPtr hwnd) {
        var names = new List<string>();
        var root = Root(hwnd);
        if (root != null) Visit(root,0,0,names,null);
        return names.ToArray();
    }
    public static bool Invoke(IntPtr hwnd, string name) {
        var root = Root(hwnd);
        return root != null && Visit(root,0,0,new List<string>(),name);
    }
}
'@
