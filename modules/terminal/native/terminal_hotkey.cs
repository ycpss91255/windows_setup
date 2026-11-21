using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.IO;
public static class WindowsSetupTerminalHotkey {
 [StructLayout(LayoutKind.Sequential)]internal struct POINT{public int x,y;}
 [StructLayout(LayoutKind.Sequential)]internal struct MSG{public IntPtr hwnd;public uint message;public UIntPtr wParam;public IntPtr lParam;public uint time;public POINT pt;public uint lPrivate;}
 [DllImport("user32.dll",SetLastError=true)]static extern bool RegisterHotKey(IntPtr hwnd,int id,uint modifiers,uint key);
 [DllImport("user32.dll")]static extern bool UnregisterHotKey(IntPtr hwnd,int id);
 [DllImport("user32.dll")]static extern int GetMessage(out MSG message,IntPtr hwnd,uint min,uint max);
 internal delegate int MessageCall(out MSG message,IntPtr hwnd,uint min,uint max);
 internal sealed class NativeApi {
  internal Func<IntPtr,int,uint,uint,bool> Register=RegisterHotKey;
  internal Func<IntPtr,int,bool> Unregister=UnregisterHotKey;
  internal MessageCall Next=GetMessage;
  internal Func<int> Error=Marshal.GetLastWin32Error;
  internal Action<string,string> Write=File.WriteAllText;
  internal Action<string,string> Append=File.AppendAllText;
  internal Func<int> PID=delegate{return Process.GetCurrentProcess().Id;};
  internal Func<string> Time=delegate{return DateTime.Now.ToString("o");};
  internal Action<string,string> Launch=delegate(string terminal,string home){Process.Start(CreateStartInfo(terminal,home));};
 }
 internal static ProcessStartInfo CreateStartInfo(string terminal,string home){
  return new ProcessStartInfo(terminal){UseShellExecute=true,WorkingDirectory=home};
 }
 public static void Run(string terminal,string log,string home){Run(terminal,log,home,new NativeApi());}
 internal static void Run(string terminal,string log,string home,NativeApi api){
  if(!api.Register(IntPtr.Zero,1,0x4003,0x54)){
   api.Write(log,"FAILED: "+api.Error());
   return;
  }
  try{
   api.Write(log,"REGISTERED: PID="+api.PID()+" "+api.Time()+Environment.NewLine);
   MSG message;
   int status;
   while((status=api.Next(out message,IntPtr.Zero,0,0))>0){
    if(message.message==0x0312&&message.wParam.ToUInt64()==1){
     try{
      api.Launch(terminal,home);
      api.Append(log,"LAUNCHED: "+api.Time()+Environment.NewLine);
     }catch(Exception error){api.Append(log,"LAUNCH FAILED: "+error.Message+Environment.NewLine);}
    }
   }
   if(status<0)api.Append(log,"MESSAGE LOOP FAILED: "+api.Error()+Environment.NewLine);
  }finally{api.Unregister(IntPtr.Zero,1);}
 }
}