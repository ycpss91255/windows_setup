using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace WindowsSetupIcons {
 public class Icon {public int Index;public string Name;public int X;public int Y;}
 public class Layout {public int Width;public int Height;public bool AutoArrange;public Icon[] Icons;}
 [StructLayout(LayoutKind.Sequential)] internal struct Rect {public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Item {public uint mask;public int iItem,iSubItem;public uint state,stateMask;public IntPtr pszText;public int cchTextMax,iImage;public IntPtr lParam;public int iIndent,iGroupId;public uint cColumns;public IntPtr puColumns,piColFmt;public int iGroup;}
 public static class Desktop {
  internal delegate bool EnumProc(IntPtr hwnd,IntPtr lparam);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern IntPtr FindWindow(string cls,string title);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string cls,string title);
  [DllImport("user32.dll")]static extern bool EnumWindows(EnumProc proc,IntPtr data);
  [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint id);
  [DllImport("user32.dll",SetLastError=true)]static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp,uint flags,uint timeout,out IntPtr result);
  [DllImport("user32.dll")]static extern bool GetClientRect(IntPtr hwnd,out Rect r);
  [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]static extern IntPtr GetStyle(IntPtr hwnd,int index);
  [DllImport("user32.dll",EntryPoint="SetWindowLongPtrW")]static extern IntPtr SetStyle(IntPtr hwnd,int index,IntPtr value);
  [DllImport("user32.dll")]static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("kernel32.dll",SetLastError=true)]static extern IntPtr OpenProcess(uint access,bool inherit,uint id);
  [DllImport("kernel32.dll",SetLastError=true)]static extern IntPtr VirtualAllocEx(IntPtr process,IntPtr address,UIntPtr size,uint type,uint protect);
  [DllImport("kernel32.dll")]static extern bool VirtualFreeEx(IntPtr process,IntPtr address,UIntPtr size,uint type);
  [DllImport("kernel32.dll")]static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll",SetLastError=true)]static extern bool ReadProcessMemory(IntPtr process,IntPtr address,byte[] buffer,IntPtr size,out IntPtr read);
  [DllImport("kernel32.dll",SetLastError=true)]static extern bool WriteProcessMemory(IntPtr process,IntPtr address,byte[] buffer,IntPtr size,out IntPtr written);
  internal delegate uint PidCall(IntPtr window,out uint pid);
  internal delegate IntPtr MessageCall(IntPtr window,uint message,IntPtr index,IntPtr data,uint flags,uint timeout,out IntPtr result);
  internal delegate bool RectCall(IntPtr window,out Rect rect);
  internal delegate bool MemoryCall(IntPtr process,IntPtr address,byte[] buffer,IntPtr size,out IntPtr count);
  internal sealed class NativeApi {
   internal Func<string,string,IntPtr> Find=FindWindow;
   internal Func<IntPtr,IntPtr,string,string,IntPtr> FindChild=FindWindowEx;
   internal Func<EnumProc,IntPtr,bool> Windows=EnumWindows;
   internal PidCall Pid=GetWindowThreadProcessId;
   internal MessageCall Message=SendMessageTimeout;
   internal RectCall Rectangle=GetClientRect;
   internal Func<IntPtr,int,IntPtr> Style=GetStyle;
   internal Func<IntPtr,int,IntPtr,IntPtr> ChangeStyle=SetStyle;
   internal Func<IntPtr,IntPtr> Dpi=SetThreadDpiAwarenessContext;
   internal Func<uint,bool,uint,IntPtr> Open=OpenProcess;
   internal Func<IntPtr,IntPtr,UIntPtr,uint,uint,IntPtr> Allocate=VirtualAllocEx;
   internal Func<IntPtr,IntPtr,UIntPtr,uint,bool> Free=VirtualFreeEx;
   internal Func<IntPtr,bool> Close=CloseHandle;
   internal MemoryCall Read=ReadProcessMemory,Write=WriteProcessMemory;
  }
  static IntPtr Msg(IntPtr hwnd,uint msg,int index,IntPtr data,NativeApi api){IntPtr result;if(api.Message(hwnd,msg,new IntPtr(index),data,2,3000,out result)==IntPtr.Zero)throw new Exception("Desktop message timed out.");return result;}
  static IntPtr View(NativeApi api){api.Dpi(new IntPtr(-4));IntPtr v=api.FindChild(api.Find("Progman",null),IntPtr.Zero,"SHELLDLL_DefView",null);if(v==IntPtr.Zero)api.Windows(delegate(IntPtr h,IntPtr p){v=api.FindChild(h,IntPtr.Zero,"SHELLDLL_DefView",null);return v==IntPtr.Zero;},IntPtr.Zero);IntPtr list=api.FindChild(v,IntPtr.Zero,"SysListView32",null);if(list==IntPtr.Zero)throw new Exception("Desktop icon list not found.");return list;}
  static byte[] Read(IntPtr p,IntPtr a,int size,NativeApi api){byte[] b=new byte[size];IntPtr n;if(!api.Read(p,a,b,new IntPtr(size),out n)||n.ToInt64()!=size)throw new Exception("Unable to read desktop icon data.");return b;}
  static void Write(IntPtr p,IntPtr a,byte[] data,NativeApi api){IntPtr n;if(!api.Write(p,a,data,new IntPtr(data.Length),out n)||n.ToInt64()!=data.Length)throw new Exception("Unable to write desktop icon message.");}
  public static Layout Capture(){return Capture(new NativeApi());}
  internal static Layout Capture(NativeApi api){
   if(IntPtr.Size!=8)throw new Exception("64-bit PowerShell is required.");IntPtr view=View(api);uint pid;api.Pid(view,out pid);IntPtr process=api.Open(0x438,false,pid);if(process==IntPtr.Zero)throw new Exception("Unable to access Explorer desktop.");IntPtr memory=api.Allocate(process,IntPtr.Zero,new UIntPtr(4096),0x3000,4);if(memory==IntPtr.Zero){api.Close(process);throw new Exception("Unable to allocate desktop message memory.");}
   try{int count=Msg(view,0x1004,0,IntPtr.Zero,api).ToInt32();if(count<0||count>256)throw new Exception("Unexpected desktop icon count.");List<Icon> icons=new List<Icon>();for(int i=0;i<count;i++){Item item=new Item();item.mask=1;item.iSubItem=0;item.pszText=IntPtr.Add(memory,256);item.cchTextMax=512;int size=Marshal.SizeOf(typeof(Item));IntPtr local=Marshal.AllocHGlobal(size);try{Marshal.StructureToPtr(item,local,false);byte[] data=new byte[size];Marshal.Copy(local,data,0,size);Write(process,memory,data,api);}finally{Marshal.FreeHGlobal(local);}Msg(view,0x1073,i,memory,api);string label=Encoding.Unicode.GetString(Read(process,IntPtr.Add(memory,256),1024,api)).Split('\0')[0];if(label.Length==0)throw new Exception("Desktop icon label is empty.");if(Msg(view,0x1010,i,IntPtr.Add(memory,128),api)==IntPtr.Zero)throw new Exception("Unable to read icon coordinates.");byte[] point=Read(process,IntPtr.Add(memory,128),8,api);icons.Add(new Icon{Index=i,Name=label,X=BitConverter.ToInt32(point,0),Y=BitConverter.ToInt32(point,4)});}Rect rect;api.Rectangle(view,out rect);return new Layout{Width=rect.Right-rect.Left,Height=rect.Bottom-rect.Top,AutoArrange=(api.Style(view,-16).ToInt64()&0x100)!=0,Icons=icons.ToArray()};}
   finally{api.Free(process,memory,UIntPtr.Zero,0x8000);api.Close(process);}
  }
  public static void Position(int index,int x,int y){Position(index,x,y,new NativeApi());}
  internal static void Position(int index,int x,int y,NativeApi api){IntPtr view=View(api);api.ChangeStyle(view,-16,new IntPtr(api.Style(view,-16).ToInt64()&~0x100L));uint pid;api.Pid(view,out pid);IntPtr process=api.Open(0x438,false,pid);if(process==IntPtr.Zero)throw new Exception("Unable to access Explorer desktop.");IntPtr memory=api.Allocate(process,IntPtr.Zero,new UIntPtr(8),0x3000,4);if(memory==IntPtr.Zero){api.Close(process);throw new Exception("Unable to allocate position buffer.");}try{byte[] point=new byte[8];Array.Copy(BitConverter.GetBytes(x),0,point,0,4);Array.Copy(BitConverter.GetBytes(y),0,point,4,4);Write(process,memory,point,api);Msg(view,0x1031,index,memory,api);}finally{api.Free(process,memory,UIntPtr.Zero,0x8000);api.Close(process);}}
 }
}