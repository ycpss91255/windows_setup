using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WindowsSetupTheme {
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")]static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
 [DllImport("user32.dll")]static extern IntPtr GetDC(IntPtr hwnd);
 [DllImport("user32.dll")]static extern int ReleaseDC(IntPtr hwnd,IntPtr dc);
 [DllImport("gdi32.dll")]static extern uint GetPixel(IntPtr dc,int x,int y);
 [DllImport("gdi32.dll")]static extern int GetClipBox(IntPtr dc,out Rect rect);
 [StructLayout(LayoutKind.Sequential)]struct AppBarData{public uint Size;public IntPtr Window;public uint Callback,Edge;public Rect Bounds;public IntPtr Parameter;}
 [DllImport("shell32.dll")]static extern UIntPtr SHAppBarMessage(uint message,ref AppBarData data);
 static uint ReadTaskbarState(){var data=new AppBarData();data.Size=(uint)Marshal.SizeOf(typeof(AppBarData));return (uint)SHAppBarMessage(4,ref data).ToUInt64();}
 [DllImport("user32.dll")]static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 internal delegate bool RectangleCall(IntPtr window,out Rect rect);
 internal delegate int ClipCall(IntPtr dc,out Rect rect);
 public sealed class TaskbarSample{public int[] RGB;public bool AutoHidden;}
 internal sealed class NativeApi {
  internal Func<IntPtr,IntPtr> Dpi=SetThreadDpiAwarenessContext;
  internal Func<string,string,IntPtr> Find=FindWindow;
  internal RectangleCall Rectangle=GetWindowRect;
  internal Func<IntPtr,IntPtr> DC=GetDC;
  internal Func<IntPtr,IntPtr,int> Release=ReleaseDC;
  internal Func<IntPtr,int,int,uint> Pixel=GetPixel;
  internal ClipCall Clip=GetClipBox;
  internal Func<uint> State=ReadTaskbarState;
 }
 public static int[] TaskbarColor(){return TaskbarColor(new NativeApi());}
 internal static int[] TaskbarColor(NativeApi api){
  TaskbarSample sample=ObserveTaskbar(api);
  if(sample.AutoHidden)throw new Exception("Taskbar color is not visible while auto-hidden.");
  return sample.RGB;
 }
 public static TaskbarSample ObserveTaskbar(){return ObserveTaskbar(new NativeApi());}
 internal static TaskbarSample ObserveTaskbar(NativeApi api){
  api.Dpi(new IntPtr(-4));
  IntPtr bar=api.Find("Shell_TrayWnd",null);
  Rect r;
  if(bar==IntPtr.Zero||!api.Rectangle(bar,out r)||r.Bottom<=r.Top||r.Right<=r.Left)throw new Exception("Taskbar is not ready.");
  IntPtr dc=api.DC(IntPtr.Zero);
  if(dc==IntPtr.Zero)throw new Exception("Unable to acquire screen context.");
  try{
   Rect clip;int region=api.Clip(dc,out clip);
   if((region!=2&&region!=3)||clip.Right<=clip.Left||clip.Bottom<=clip.Top)throw new Exception("Unable to inspect screen clipping region.");
   int x=r.Left+Math.Min(8,(r.Right-r.Left)/2),y=r.Top+(r.Bottom-r.Top)/2;
   if(x<clip.Left||x>=clip.Right||y<clip.Top||y>=clip.Bottom){
    uint state=api.State();if(state>3)throw new Exception("Unknown taskbar state.");
    if((state&1)!=0)return new TaskbarSample{RGB=new int[0],AutoHidden=true};
    throw new Exception("Taskbar sample is outside the visible region without confirmed autohide.");
   }
   uint color=api.Pixel(dc,x,y);
   if(color==0xffffffff)throw new Exception("Unable to read taskbar color.");
   return new TaskbarSample{RGB=new int[]{(int)(color&255),(int)((color>>8)&255),(int)((color>>16)&255)},AutoHidden=false};
  }finally{api.Release(IntPtr.Zero,dc);}
 }
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]public static extern bool SystemParametersInfo(uint action,uint param,string value,uint flags);
 [DllImport("user32.dll",EntryPoint="SystemParametersInfoW",CharSet=CharSet.Unicode,SetLastError=true)]public static extern bool ReadWallpaper(uint action,uint param,StringBuilder value,uint flags);
 [DllImport("user32.dll")]public static extern bool SetSysColors(int count,int[] elements,uint[] colors);
 [DllImport("user32.dll")]public static extern uint GetSysColor(int index);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]public static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint msg,IntPtr wp,string lp,uint flags,uint timeout,out IntPtr result);
}
