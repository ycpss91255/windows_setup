using System;
using System.Runtime.InteropServices;
[assembly:System.Runtime.CompilerServices.InternalsVisibleTo("windows_setup_managed_tests")]
public static class WindowsSetupExplorerOptions {
 [DllImport("shell32.dll")] static extern void SHGetSetSettings(IntPtr p,uint mask,bool set);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr w,uint m,IntPtr a,string b,uint f,uint t,out IntPtr r);
 internal delegate IntPtr BroadcastCall(IntPtr w,uint m,IntPtr a,string b,uint f,uint t,out IntPtr r);
 internal sealed class NativeApi {
  internal Func<int,IntPtr> Allocate=Marshal.AllocHGlobal;
  internal Action<IntPtr> Free=Marshal.FreeHGlobal;
  internal Action<IntPtr,uint,bool> Settings=SHGetSetSettings;
  internal BroadcastCall Broadcast=SendMessageTimeout;
 }
 public static uint Options(bool set){return Options(set,new NativeApi());}
 internal static uint Options(bool set,NativeApi api){
  IntPtr p=api.Allocate(256);
  try{
   for(int i=0;i<256;i++)Marshal.WriteByte(p,i,0);
   api.Settings(p,3,false);
   if(set){
    Marshal.WriteInt32(p,Marshal.ReadInt32(p)|3);
    api.Settings(p,3,true);
    IntPtr result;
    api.Broadcast((IntPtr)65535,26,IntPtr.Zero,"ShellState",2,2000,out result);
   }
   api.Settings(p,3,false);
   return ((uint)Marshal.ReadInt32(p))&3;
  }finally{api.Free(p);}
 }
}