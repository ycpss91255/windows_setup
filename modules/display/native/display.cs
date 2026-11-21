using System;
using System.Runtime.InteropServices;
namespace WindowsSetupDisplay {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
 public struct Mode {
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dmDeviceName;
  public ushort dmSpecVersion,dmDriverVersion,dmSize,dmDriverExtra;
  public uint dmFields;
  public int dmPositionX,dmPositionY;
  public uint dmDisplayOrientation,dmDisplayFixedOutput;
  public short dmColor,dmDuplex,dmYResolution,dmTTOption,dmCollate;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dmFormName;
  public ushort dmLogPixels;
  public uint dmBitsPerPel,dmPelsWidth,dmPelsHeight,dmDisplayFlags,dmDisplayFrequency;
  public uint dmICMMethod,dmICMIntent,dmMediaType,dmDitherType,dmReserved1,dmReserved2,dmPanningWidth,dmPanningHeight;
 }
 public static class Display {
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool EnumDisplaySettings(string name,int number,ref Mode mode);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettings(ref Mode mode,uint flags);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
  [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags,out uint paths,out uint modes);
  [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags,ref uint paths,IntPtr pathData,ref uint modes,IntPtr modeData,IntPtr topology);
  [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(IntPtr packet);
  [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(IntPtr packet);
  internal delegate bool EnumerateCall(string name,int index,ref Mode mode);
  internal delegate int ChangeCall(ref Mode mode,uint flags);
  internal delegate int BufferCall(uint flags,out uint paths,out uint modes);
  internal delegate int QueryCall(uint flags,ref uint paths,IntPtr pathData,ref uint modes,IntPtr modeData,IntPtr topology);
  internal sealed class NativeApi {
   internal EnumerateCall Enumerate=EnumDisplaySettings;
   internal ChangeCall Change=ChangeDisplaySettings;
   internal Func<bool> Aware=SetProcessDPIAware;
   internal Func<uint> Dpi=GetDpiForSystem;
   internal BufferCall Buffer=GetDisplayConfigBufferSizes;
   internal QueryCall Query=QueryDisplayConfig;
   internal Func<IntPtr,int> Get=DisplayConfigGetDeviceInfo,Set=DisplayConfigSetDeviceInfo;
   internal Func<int,IntPtr> Allocate=Marshal.AllocHGlobal;
   internal Action<IntPtr> Free=Marshal.FreeHGlobal;
  }
  // Per-monitor preset scaling packets, based on lihas/windows-DPI-scaling-sample.
  // Packet types -3/-4 are undocumented; failures are reported instead of falling back to custom scaling.
  static void FillHeader(IntPtr packet,int type,int size,IntPtr path){Marshal.WriteInt32(packet,0,type);Marshal.WriteInt32(packet,4,size);Marshal.WriteInt32(packet,8,Marshal.ReadInt32(path,0));Marshal.WriteInt32(packet,12,Marshal.ReadInt32(path,4));Marshal.WriteInt32(packet,16,Marshal.ReadInt32(path,8));}
  public static uint[] NativeScales(bool apply){return NativeScales(apply,new NativeApi());}
  internal static uint[] NativeScales(bool apply,NativeApi api){
   uint pc,mc;int error=api.Buffer(2,out pc,out mc);if(error!=0)throw new Exception("Display buffer query failed: "+error);
   IntPtr paths=IntPtr.Zero,modes=IntPtr.Zero;
   System.Collections.Generic.List<uint> values=new System.Collections.Generic.List<uint>();
   System.Collections.Generic.HashSet<string> seen=new System.Collections.Generic.HashSet<string>();
   uint[] percentages=new uint[]{100,125,150,175,200,225,250,300,350,400,450,500};
   try{
    paths=api.Allocate(checked((int)pc*72));modes=api.Allocate(checked((int)mc*64));
    error=api.Query(2,ref pc,paths,ref mc,modes,IntPtr.Zero);if(error!=0)throw new Exception("Display path query failed: "+error);
    for(int i=0;i<pc;i++){
     IntPtr path=IntPtr.Add(paths,i*72);string id=Marshal.ReadInt32(path,0)+":"+Marshal.ReadInt32(path,4)+":"+Marshal.ReadInt32(path,8);if(!seen.Add(id))continue;
     IntPtr get=IntPtr.Zero,set=IntPtr.Zero;
     try{
      get=api.Allocate(32);set=api.Allocate(24);
      FillHeader(get,-3,32,path);error=api.Get(get);if(error!=0)throw new Exception("Native DPI query failed: "+error);
      int min=Marshal.ReadInt32(get,20),current=Marshal.ReadInt32(get,24);
      if(apply){FillHeader(set,-4,24,path);Marshal.WriteInt32(set,20,min);error=api.Set(set);if(error!=0)throw new Exception("Native DPI change failed: "+error);error=api.Get(get);if(error!=0)throw new Exception("Native DPI verification failed: "+error);current=Marshal.ReadInt32(get,24);}
      int index=Math.Abs(min)+current;if(index<0||index>=percentages.Length)throw new Exception("Unexpected native DPI range.");values.Add(percentages[index]);
     }finally{if(get!=IntPtr.Zero)api.Free(get);if(set!=IntPtr.Zero)api.Free(set);}
    }
   }finally{if(paths!=IntPtr.Zero)api.Free(paths);if(modes!=IntPtr.Zero)api.Free(modes);}
   if(values.Count==0)throw new Exception("No active display source.");return values.ToArray();
  }
  static Mode NewMode(){Mode m=new Mode();m.dmSize=(ushort)Marshal.SizeOf(typeof(Mode));return m;}
  public static uint[] Read(){return Read(new NativeApi());}
  internal static uint[] Read(NativeApi api){uint[] snapshot=ReadSnapshot(api);return new uint[]{snapshot[0],snapshot[1],snapshot[2]*96/100};}
  // Width and height refer to the primary display; subsequent values are active source percentages in native order.
  public static uint[] ReadSnapshot(){return ReadSnapshot(new NativeApi());}
  internal static uint[] ReadSnapshot(NativeApi api){api.Aware();Mode m=NewMode();if(!api.Enumerate(null,-1,ref m))throw new Exception("Unable to read active primary display mode.");uint[] scales=NativeScales(false,api);uint[] snapshot=new uint[scales.Length+2];snapshot[0]=m.dmPelsWidth;snapshot[1]=m.dmPelsHeight;Array.Copy(scales,0,snapshot,2,scales.Length);return snapshot;}
  public static uint[] Apply(){return Apply(new NativeApi());}
  internal static uint[] Apply(NativeApi api){
   api.Aware();Mode current=NewMode();
   if(!api.Enumerate(null,-1,ref current))throw new Exception("Unable to read active primary display mode.");
   uint oldW=current.dmPelsWidth,oldH=current.dmPelsHeight;
   bool supported=false;
   for(int i=0;i<4096;i++){Mode candidate=NewMode();if(!api.Enumerate(null,i,ref candidate))break;if(candidate.dmPelsWidth==1920 && candidate.dmPelsHeight==1080){supported=true;break;}}
   if(!supported)throw new Exception("The connected primary display does not advertise 1920x1080.");
   current.dmPelsWidth=1920;current.dmPelsHeight=1080;current.dmFields=0x180000;
   int test=api.Change(ref current,2);if(test!=0)throw new Exception("Display mode test failed: "+test);
   int status=api.Change(ref current,1);if(status==1)throw new Exception("Display mode change requires a manual restart; the active mode is not confirmed.");if(status!=0)throw new Exception("Display mode change failed: "+status);
   Mode after=NewMode();if(!api.Enumerate(null,-1,ref after))throw new Exception("Unable to read active primary display mode after change.");
   if(after.dmPelsWidth!=1920 || after.dmPelsHeight!=1080)throw new Exception("Active primary display mode does not match 1920x1080 after change.");
   return new uint[]{oldW,oldH,after.dmPelsWidth,after.dmPelsHeight,(uint)status,api.Dpi()};
  }
 }
}
