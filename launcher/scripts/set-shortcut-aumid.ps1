param([string[]]$Shortcuts, [string]$AppId = 'DeskPilot.PrivateDesktopControl.1')
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Aumid {
  [StructLayout(LayoutKind.Sequential)]
  public struct PropertyKey {
    public Guid fmtid; public uint pid;
    public PropertyKey(Guid g, uint p) { fmtid = g; pid = p; }
  }
  [StructLayout(LayoutKind.Explicit)]
  public struct PropVariant {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pwszValue;
  }
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IPropertyStore {
    void GetCount(out uint count);
    void GetAt(uint index, out PropertyKey key);
    void GetValue(ref PropertyKey key, out PropVariant value);
    void SetValue(ref PropertyKey key, ref PropVariant value);
    void Commit();
  }
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  public static extern int SHGetPropertyStoreFromParsingName(string path, IntPtr pbc, int flags, ref Guid iid, out IPropertyStore store);
  public static string Set(string path, string appId) {
    var key = new PropertyKey(new Guid("9F4C416E-2048-4000-C0E0-CA0035BE0C63"), 5);
    var iid = typeof(IPropertyStore).GUID;
    IPropertyStore store;
    int hr = SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 2, ref iid, out store);
    if (hr != 0) return "open failed: " + hr;
    var value = new PropVariant { vt = 31, pwszValue = Marshal.StringToCoTaskMemUni(appId) };
    string result;
    try { store.SetValue(ref key, ref value); store.Commit(); result = "ok"; }
    catch (Exception e) { result = e.Message; }
    finally { Marshal.FreeCoTaskMem(value.pwszValue); Marshal.ReleaseComObject(store); }
    return result;
  }
  public static string Get(string path) {
    var key = new PropertyKey(new Guid("9F4C416E-2048-4000-C0E0-CA0035BE0C63"), 5);
    var iid = typeof(IPropertyStore).GUID;
    IPropertyStore store;
    int hr = SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 0, ref iid, out store);
    if (hr != 0) return "open failed: " + hr;
    try { PropVariant value; store.GetValue(ref key, out value); string s = "vt=" + value.vt; if (value.pwszValue != IntPtr.Zero) s += " " + Marshal.PtrToStringUni(value.pwszValue); return s; }
    catch (Exception e) { return "get failed: " + e.Message; }
    finally { Marshal.ReleaseComObject(store); }
  }
}
'@
foreach ($s in $Shortcuts) {
  $r = [Aumid]::Set($s, $AppId)
  Write-Output "$s => set=$r"
}
