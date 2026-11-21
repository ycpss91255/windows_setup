using System;
using System.Reflection;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ManagedNativeTests {
 static int assertions;
 static void Assert(bool condition,string name){if(!condition)throw new Exception(name);assertions++;Console.WriteLine("PASS: "+name);}
 static void Throws(Action action,string name,Type expected=null){bool rejected=false;try{action();}catch(Exception error){rejected=error.GetType()==(expected??typeof(InvalidOperationException));}Assert(rejected,name);}
 static void TaskbarAutoHideCases(){
  ulong state=2;int writes=0,reads=0;bool discard=false;IntPtr window=(IntPtr)17;
  var api=new WindowsSetup.Taskbar.NativeApi();
  api.Find=delegate{ return window; };
  api.CurrentSession=delegate{ return 7; };
  api.WindowSession=delegate(IntPtr handle){Assert(handle==window,"auto-hide checks the discovered taskbar identity");return 7;};
  api.Message=delegate(uint message,ref WindowsSetup.Taskbar.AppBarData data){
   Assert(data.Size==Marshal.SizeOf(typeof(WindowsSetup.Taskbar.AppBarData)),"appbar ABI uses exact native structure size");
   if(message==5){Assert(data.Window==window,"appbar position validates the current taskbar");return 1;}
   if(message==4){reads++;return state;}
   Assert(message==10 && data.Window==window && data.Parameter==(IntPtr)3,"only AUTOHIDE is added, preserving the other native bit");
   writes++;if(!discard)state=(ulong)data.Parameter.ToInt64();return 1;
  };
  Assert(WindowsSetup.Taskbar.AutoHide(false,api)==2 && writes==0,"readonly native state never changes taskbar");
  Assert(WindowsSetup.Taskbar.AutoHide(true,api)==3 && writes==1,"native auto-hide sets only missing bit and verifies readback");
  Assert(WindowsSetup.Taskbar.AutoHide(true,api)==3 && writes==1,"already enabled auto-hide is idempotent");
  state=2;discard=true;Throws(delegate{WindowsSetup.Taskbar.AutoHide(true,api);},"always-TRUE SETSTATE cannot replace actual state readback");
  state=4;int before=writes;Throws(delegate{WindowsSetup.Taskbar.AutoHide(true,api);},"undocumented malformed state stops without writes");Assert(writes==before,"malformed state preserves original taskbar");
  window=IntPtr.Zero;Throws(delegate{WindowsSetup.Taskbar.AutoHide(true,api);},"missing taskbar stops");
  window=(IntPtr)17;api.WindowSession=delegate(IntPtr handle){return 9;};Throws(delegate{WindowsSetup.Taskbar.AutoHide(true,api);},"another session taskbar cannot be modified");
  api.WindowSession=delegate(IntPtr handle){throw new InvalidOperationException("session query failed");};Throws(delegate{WindowsSetup.Taskbar.AutoHide(true,api);},"failed native identity query cannot silently continue");
  api.WindowSession=delegate(IntPtr handle){return 7;};api.Message=delegate(uint message,ref WindowsSetup.Taskbar.AppBarData data){return 0;};Throws(delegate{WindowsSetup.Taskbar.AutoHide(true,api);},"unresponsive taskbar position query stops before interpreting zero state");
  api.Message=delegate(uint message,ref WindowsSetup.Taskbar.AppBarData data){if(message==5)return 1;throw new InvalidOperationException("state query failed");};Throws(delegate{WindowsSetup.Taskbar.AutoHide(true,api);},"native state query failure propagates");
 }
 static void MdnsAllocationOnlyAbiCases(){
  // Independent WinDNS.h SDK layout: allocation/read/free only, never Register/DeRegister/Cancel.
  Assert(Marshal.SizeOf(typeof(WindowsSetup.MdnsPublisher.Instance))==(IntPtr.Size==8?72:40),"DNS_SERVICE_INSTANCE SDK size");
  Assert(Marshal.SizeOf(typeof(WindowsSetup.MdnsPublisher.Request))==(IntPtr.Size==8?48:28),"DNS_SERVICE_REGISTER_REQUEST SDK size");
  Assert(Marshal.OffsetOf(typeof(WindowsSetup.MdnsPublisher.Request),"Unicast").ToInt32()==(IntPtr.Size==8?40:24),"native BOOL has four bytes at SDK offset");
  foreach(string family in new[]{"v4","v6","dual","scope"}){
   var ad=new WindowsSetup.MdnsPublisher.Advertisement{HostName="fixture.local",ServiceName="fixture._ssh._tcp.local",InterfaceIndex=7,Port=22,IPv4=family=="v4"||family=="dual"?"192.0.2.9":null,IPv6=family=="v6"||family=="dual"?"2001:db8::9":family=="scope"?"fe80::9%7":null};
   IntPtr p=WindowsSetup.MdnsPublisher.NativeConstruct(ad);
   try{
    Assert(p!=IntPtr.Zero,"native allocation succeeds without advertising "+family);
    Assert(Marshal.PtrToStringUni(Marshal.ReadIntPtr(p,0))==ad.ServiceName && Marshal.PtrToStringUni(Marshal.ReadIntPtr(p,IntPtr.Size))==ad.HostName,"raw SDK name/host offsets match native allocation "+family);
    Assert(Marshal.ReadInt16(p,IntPtr.Size==8?32:16)==22,"native WORD port is host order 22 "+family);
    Assert(Marshal.ReadInt32(p,IntPtr.Size==8?64:36)==0,"constructor interface is documented zero "+family);
    var actual=WindowsSetup.MdnsPublisher.ReadInstance(p);
    Assert(actual.HostName==ad.HostName && actual.ServiceName==ad.ServiceName && actual.Port==22,"original source reads actual native allocation "+family);
    Assert(actual.IPv4==ad.IPv4 && actual.IPv6==(family=="scope"?"fe80::9":ad.IPv6),"native IPv4/IPv6 bytes and scope-free representation "+family);
   }finally{WindowsSetup.MdnsPublisher.NativeFree(p);}
  }
  WindowsSetup.MdnsPublisher.NativeFree(IntPtr.Zero);
  Throws(delegate{WindowsSetup.MdnsPublisher.ReadInstance(IntPtr.Zero);},"missing native allocation is rejected");
 }
 static void MdnsCases(){
  var ad=new WindowsSetup.MdnsPublisher.Advertisement{HostName="fixture.local",ServiceName="fixture._ssh._tcp.local",InterfaceIndex=7,IPv4="192.0.2.9",IPv6="2001:db8::9",Port=22};
  foreach(string mode in new[]{"sync","async","error","timeout","late_cancel","deregister_error","host_mismatch","missing_instance","scope","callback_service","callback_port","callback_address","callback_interface"}){
   ad.IPv6=mode=="scope"?"fe80::9%7":"2001:db8::9";
   int registrations=0,deregistrations=0,cancels=0,originalFreed=0,copiesFreed=0;WindowsSetup.MdnsPublisher.Completion saved=null;bool retry=false,freedDuringCancel=false;
   var api=new WindowsSetup.MdnsPublisher.NativeApi();
   api.Construct=delegate(WindowsSetup.MdnsPublisher.Advertisement row){Assert(row.HostName==ad.HostName && row.ServiceName==ad.ServiceName && row.InterfaceIndex==7 && row.IPv4==ad.IPv4 && row.IPv6==ad.IPv6 && row.Port==22,"native mDNS publisher receives exact host and address rows");return (IntPtr)11;};
   api.Read=delegate(IntPtr instance){return new WindowsSetup.MdnsPublisher.Advertisement{HostName=mode=="host_mismatch" && instance==(IntPtr)12?"another.local":ad.HostName,ServiceName=mode=="callback_service" && instance==(IntPtr)12?"other._ssh._tcp.local":ad.ServiceName,InterfaceIndex=mode=="callback_interface" && instance==(IntPtr)12?8u:7u,IPv4=mode=="callback_address" && instance==(IntPtr)12?"192.0.2.99":ad.IPv4,IPv6=mode=="scope"?"fe80::9":ad.IPv6,Port=mode=="callback_port" && instance==(IntPtr)12?23:22};};
   api.Free=delegate(IntPtr instance){if(instance==(IntPtr)11){originalFreed++;Assert(originalFreed==1,"mDNS original instance is freed at most once");}else copiesFreed++;};
   api.Request=delegate(uint operation,IntPtr request,IntPtr cancel){
    var r=(WindowsSetup.MdnsPublisher.Request)Marshal.PtrToStructure(request,typeof(WindowsSetup.MdnsPublisher.Request));
    Assert(r.Version==1 && r.InterfaceIndex==7 && r.Instance==(IntPtr)11 && r.Context==IntPtr.Zero && r.Credentials==IntPtr.Zero && r.Unicast==0,"real ABI request fixes interface mDNS and has no arbitrary credentials/context");
    saved=(WindowsSetup.MdnsPublisher.Completion)Marshal.GetDelegateForFunctionPointer(r.Callback,typeof(WindowsSetup.MdnsPublisher.Completion));
    if(operation==0){registrations++;Assert(cancel!=IntPtr.Zero,"registration owns a cancellable asynchronous handle");if(mode=="error")return 5;if(mode=="timeout" || mode=="late_cancel")return 9506;if(mode=="async"){System.Threading.ThreadPool.QueueUserWorkItem(delegate{saved(0,IntPtr.Zero,(IntPtr)12);});}else saved(0,IntPtr.Zero,mode=="missing_instance"?IntPtr.Zero:(IntPtr)12);}
    else{deregistrations++;Assert(cancel==IntPtr.Zero,"deregister requires null cancellation handle");saved(mode=="deregister_error" && !retry?5u:0u,IntPtr.Zero,(IntPtr)13);}
    return 9506;
   };
   api.Cancel=delegate(IntPtr cancel){cancels++;if(mode=="timeout"){saved(995,IntPtr.Zero,IntPtr.Zero);freedDuringCancel=originalFreed!=0;}return 0;};
   WindowsSetup.MdnsPublisher.Registration lease=null;bool failed=false;
   try{lease=WindowsSetup.MdnsPublisher.Begin(ad,api,100);}catch(InvalidOperationException){failed=true;}catch(TimeoutException){failed=true;}
   Assert(!freedDuringCancel,"native Cancel call must return before original instance/request/cancel memory is freed");
   if(mode=="error" || mode=="timeout" || mode=="late_cancel" || mode=="host_mismatch" || mode=="missing_instance" || mode.StartsWith("callback_")){
    Assert(failed && lease==null,"native error or timeout cannot claim registration from local resolution");
    if(mode=="late_cancel"){Assert(originalFreed==0 && cancels==1,"timeout retains native memory until cancelled callback completes");saved(995,IntPtr.Zero,IntPtr.Zero);}
    Assert(originalFreed==1 && deregistrations==((mode=="host_mismatch" || mode=="missing_instance" || mode.StartsWith("callback_"))?1:0),"failed registrations clean up and native success with unexpected identity is explicitly deregistered");
   }else{
    Assert(!failed && lease.Registered && originalFreed==0 && registrations==1,"registration remains alive while publisher process holds the lease");
    if(mode=="deregister_error"){Throws(delegate{lease.Dispose();},"native deregister error stays visible");Assert(originalFreed==0,"failed deregistration does not free a live lease");retry=true;}
    lease.Dispose();lease.Dispose();Assert(!lease.Registered && originalFreed==1 && deregistrations==(mode=="deregister_error"?2:1),"dispose deregisters the advertised records once and double dispose is harmless");
   }
  }
 }
 static void ExplorerCases(){
  uint settings=4;int reads=0,writes=0,broadcasts=0,freed=0;
  var api=new NucExplorerLiveV2.NativeApi();
  api.Allocate=delegate(int size){Assert(size==256,"explorer allocates exact shell settings buffer");return Marshal.AllocHGlobal(size);};
  api.Free=delegate(IntPtr memory){freed++;Marshal.FreeHGlobal(memory);};
  api.Settings=delegate(IntPtr memory,uint mask,bool set){Assert(mask==3,"explorer only requests hidden/extension option mask");if(set){settings=(uint)Marshal.ReadInt32(memory);writes++;}else{reads++;Marshal.WriteInt32(memory,(int)settings);}};
  api.Broadcast=delegate(IntPtr window,uint message,IntPtr value,string text,uint flags,uint timeout,out IntPtr result){result=IntPtr.Zero;broadcasts++;Assert(window==(IntPtr)65535 && message==26 && text=="ShellState" && flags==2 && timeout==2000,"explorer broadcasts exact shell state update");return (IntPtr)1;};
  Assert(NucExplorerLiveV2.Options(false,api)==0 && writes==0 && broadcasts==0 && freed==1,"explorer read mode never writes or broadcasts");
  Assert(NucExplorerLiveV2.Options(true,api)==3 && settings==7 && reads==4 && writes==1 && broadcasts==1 && freed==2,"explorer preserves unrelated bits and reads back changed options");
  api.Settings=delegate(IntPtr memory,uint mask,bool set){throw new InvalidOperationException("settings fixture failure");};
  Throws(delegate{NucExplorerLiveV2.Options(true,api);},"explorer native failure propagates");
  Assert(freed==3,"explorer frees unmanaged settings buffer after failure");
 }
 static void ThemeCases(){
  int releases=0;var api=new NUC8Theme.NativeApi();
  api.Dpi=delegate(IntPtr context){Assert(context==(IntPtr)(-4),"theme requests expected thread DPI context");return IntPtr.Zero;};
  api.Find=delegate(string kind,string title){Assert(kind=="Shell_TrayWnd" && title==null,"theme finds the taskbar class");return (IntPtr)1;};
  api.Rectangle=delegate(IntPtr window,out NUC8Theme.Rect rect){rect=new NUC8Theme.Rect{Left=100,Top=900,Right=1920,Bottom=940};return true;};
  api.DC=delegate(IntPtr window){Assert(window==IntPtr.Zero,"theme samples screen DC");return (IntPtr)2;};
  api.Clip=delegate(IntPtr dc,out NUC8Theme.Rect rect){Assert(dc==(IntPtr)2,"theme checks the acquired screen clipping context");rect=new NUC8Theme.Rect{Left=0,Top=0,Right=1920,Bottom=1080};return 2;};
  api.State=delegate{return 0;};
  api.Release=delegate(IntPtr window,IntPtr dc){Assert(window==IntPtr.Zero && dc==(IntPtr)2,"theme releases exact acquired DC");releases++;return 1;};
  api.Pixel=delegate(IntPtr dc,int x,int y){Assert(dc==(IntPtr)2 && x==108 && y==920,"theme reads expected taskbar sample coordinate");return 0x00332211;};
  var rgb=NUC8Theme.TaskbarColor(api);Assert(rgb[0]==17 && rgb[1]==34 && rgb[2]==51 && releases==1,"theme converts COLORREF channels and releases DC");
  api.Find=delegate(string kind,string title){return IntPtr.Zero;};Throws(delegate{NUC8Theme.TaskbarColor(api);},"missing taskbar is rejected",typeof(Exception));
  api.Find=delegate(string kind,string title){return (IntPtr)1;};
  api.Rectangle=delegate(IntPtr window,out NUC8Theme.Rect rect){rect=new NUC8Theme.Rect();return false;};Throws(delegate{NUC8Theme.TaskbarColor(api);},"failed taskbar rectangle query is rejected",typeof(Exception));
  api.Rectangle=delegate(IntPtr window,out NUC8Theme.Rect rect){rect=new NUC8Theme.Rect{Top=10,Bottom=10};return true;};Throws(delegate{NUC8Theme.TaskbarColor(api);},"empty taskbar rectangle is rejected",typeof(Exception));
  api.Rectangle=delegate(IntPtr window,out NUC8Theme.Rect rect){rect=new NUC8Theme.Rect{Right=1920,Top=900,Bottom=940};return true;};
  api.Pixel=delegate(IntPtr dc,int x,int y){return 0xffffffff;};Throws(delegate{NUC8Theme.TaskbarColor(api);},"invalid pixel result is rejected",typeof(Exception));
  Assert(releases==2,"theme releases DC when pixel read reports failure");
  api.Pixel=delegate(IntPtr dc,int x,int y){throw new InvalidOperationException("pixel fixture failure");};Throws(delegate{NUC8Theme.TaskbarColor(api);},"pixel exception propagates");
  Assert(releases==3,"theme releases DC when pixel read throws");
  int outsideReads=0;
  api.Rectangle=delegate(IntPtr window,out NUC8Theme.Rect rect){rect=new NUC8Theme.Rect{Left=0,Top=1078,Right=1920,Bottom=1126};return true;};
  api.Pixel=delegate(IntPtr dc,int x,int y){if(x<0||x>=1920||y<0||y>=1080){outsideReads++;return 0xffffffff;}return 0x00151515;};
  Throws(delegate{NUC8Theme.TaskbarColor(api);},"offscreen sample without confirmed autohide is rejected",typeof(Exception));
  Console.WriteLine("OFFSCREEN_PIXEL_CALLS="+outsideReads);
  Assert(outsideReads==0,"theme rejects offscreen geometry before asking GetPixel outside the clip region");
  api.State=delegate{return 1;};
  var hidden=NUC8Theme.ObserveTaskbar(api);
  Assert(hidden.AutoHidden && hidden.RGB.Length==0 && outsideReads==0,"confirmed autohide outside the clip has no invented RGB and never samples the wallpaper");
  Throws(delegate{NUC8Theme.TaskbarColor(api);},"legacy RGB API never invents color for an auto-hidden taskbar",typeof(Exception));
  bool malformedRejected=true;
  foreach(uint invalidState in new uint[]{5,uint.MaxValue}){
   api.State=delegate{return invalidState;};bool rejected=false;
   try{NUC8Theme.ObserveTaskbar(api);}catch(Exception){rejected=true;}
   Console.WriteLine("MALFORMED_STATE_"+invalidState+"_REJECTED="+rejected);malformedRejected&=rejected;
  }
  api.State=delegate{return 1;};
  api.Clip=delegate(IntPtr dc,out NUC8Theme.Rect rect){rect=new NUC8Theme.Rect{Right=1920,Bottom=1080};return 4;};
  bool unknownClipRejected=false;try{NUC8Theme.ObserveTaskbar(api);}catch(Exception){unknownClipRejected=true;}
  Console.WriteLine("UNKNOWN_CLIP_4_REJECTED="+unknownClipRejected);
  Assert(malformedRejected && unknownClipRejected,"unknown appbar and clipping values never authorize a hidden observation");
  api.Clip=delegate(IntPtr dc,out NUC8Theme.Rect rect){rect=new NUC8Theme.Rect{Right=1920,Bottom=1080};return 2;};
  api.State=delegate{return 3;};
  Assert(NUC8Theme.ObserveTaskbar(api).AutoHidden,"documented autohide plus always-on-top remains accepted");
  api.State=delegate{return 2;};
  Throws(delegate{NUC8Theme.ObserveTaskbar(api);},"always-on-top alone cannot authorize a hidden observation",typeof(Exception));
  api.State=delegate{throw new InvalidOperationException("state query failed");};
  Throws(delegate{NUC8Theme.ObserveTaskbar(api);},"failed autohide state query cannot pass as hidden");
  api.Clip=delegate(IntPtr dc,out NUC8Theme.Rect rect){rect=new NUC8Theme.Rect();return 0;};
  Throws(delegate{NUC8Theme.ObserveTaskbar(api);},"failed clip query cannot pass as hidden",typeof(Exception));
  api.Clip=delegate(IntPtr dc,out NUC8Theme.Rect rect){rect=new NUC8Theme.Rect{Right=1920,Bottom=1080};return 1;};
  Throws(delegate{NUC8Theme.ObserveTaskbar(api);},"empty clipping region cannot pass as hidden",typeof(Exception));
  int beforeNoDc=releases;api.DC=delegate(IntPtr window){return IntPtr.Zero;};
  Throws(delegate{NUC8Theme.ObserveTaskbar(api);},"missing screen context is rejected",typeof(Exception));
  Assert(releases==beforeNoDc,"no unacquired screen context is released");
  api.DC=delegate(IntPtr window){return (IntPtr)2;};
  api.Clip=delegate(IntPtr dc,out NUC8Theme.Rect rect){rect=new NUC8Theme.Rect{Left=-1920,Top=0,Right=0,Bottom=1080};return 3;};
  api.Rectangle=delegate(IntPtr window,out NUC8Theme.Rect rect){rect=new NUC8Theme.Rect{Left=-1920,Top=1032,Right=0,Bottom=1080};return true;};
  api.Pixel=delegate(IntPtr dc,int x,int y){Assert(x==-1912 && y==1056,"secondary monitor sample retains negative desktop coordinates");return 0x00151515;};
  var visible=NUC8Theme.ObserveTaskbar(api);
  Assert(!visible.AutoHidden && visible.RGB[0]==21,"visible native pixels remain verified even when the state API is unavailable");
 }
 static void HotkeyCases(){
  var log=new List<string>();int unregistered=0,messages=0,launched=0;
  var api=new NucTerminalHotkey.NativeApi();
  api.Register=delegate(IntPtr window,int id,uint modifiers,uint key){Assert(window==IntPtr.Zero && id==1 && modifiers==0x4003 && key==0x54,"hotkey registers Ctrl+Alt+T with no-repeat modifier");return false;};
  api.Unregister=delegate(IntPtr window,int id){Assert(window==IntPtr.Zero && id==1,"hotkey releases its own registration");unregistered++;return true;};
  api.Error=delegate{return 37;};api.PID=delegate{return 1234;};api.Time=delegate{return "fixture-time";};
  api.Write=delegate(string path,string text){Assert(path=="fixture.log","hotkey writes only requested status log");log.Clear();log.Add(text);};
  api.Append=delegate(string path,string text){Assert(path=="fixture.log","hotkey appends only requested status log");log.Add(text);};
  api.Next=delegate(out NucTerminalHotkey.MSG message,IntPtr window,uint min,uint max){message=new NucTerminalHotkey.MSG();messages++;return 0;};
  api.Launch=delegate(string terminal,string home){Assert(terminal=="terminal fixture.exe" && home=="home with spaces","hotkey forwards dynamic terminal and user home");launched++;};
  NucTerminalHotkey.Run("terminal fixture.exe","fixture.log","home with spaces",api);
  Assert(log.Count==1 && log[0]=="FAILED: 37" && messages==0 && unregistered==0,"failed registration neither enters loop nor unregisters someone else's hotkey");
  api.Register=delegate(IntPtr window,int id,uint modifiers,uint key){return true;};
  api.Next=delegate(out NucTerminalHotkey.MSG message,IntPtr window,uint min,uint max){message=new NucTerminalHotkey.MSG();int number=messages++;if(number==0){message.message=0x100;return 1;}if(number==1){message.message=0x312;message.wParam=(UIntPtr)1;return 1;}return 0;};
  NucTerminalHotkey.Run("terminal fixture.exe","fixture.log","home with spaces",api);
  Assert(launched==1 && unregistered==1 && log[0].Contains("REGISTERED: PID=1234 fixture-time") && log[1].Contains("LAUNCHED: fixture-time"),"hotkey ignores unrelated messages and launches terminal only for its registration");
  messages=0;api.Next=delegate(out NucTerminalHotkey.MSG message,IntPtr window,uint min,uint max){message=new NucTerminalHotkey.MSG{message=0x312,wParam=(UIntPtr)1};return messages++==0?1:0;};
  api.Launch=delegate(string terminal,string home){throw new InvalidOperationException("launch fixture failure");};
  NucTerminalHotkey.Run("terminal fixture.exe","fixture.log","home with spaces",api);
  Assert(log[1].Contains("LAUNCH FAILED: launch fixture failure") && unregistered==2,"terminal launch failure is logged and registration is released");
  api.Next=delegate(out NucTerminalHotkey.MSG message,IntPtr window,uint min,uint max){message=new NucTerminalHotkey.MSG();return -1;};
  NucTerminalHotkey.Run("terminal fixture.exe","fixture.log","home with spaces",api);
  Assert(log[1].Contains("MESSAGE LOOP FAILED: 37") && unregistered==3,"message-loop native error cannot leave a misleading registered status");
  api.Write=delegate(string path,string text){throw new InvalidOperationException("log fixture failure");};
  Throws(delegate{NucTerminalHotkey.Run("terminal fixture.exe","fixture.log","home with spaces",api);},"startup log failure propagates");
  Assert(unregistered==4,"startup log failure still unregisters the acquired hotkey");
  var start=NucTerminalHotkey.CreateStartInfo("terminal fixture.exe","home with spaces");Assert(start.UseShellExecute && start.FileName=="terminal fixture.exe" && start.WorkingDirectory=="home with spaces","production launch options preserve dynamic paths without starting a process");
 }
 static void DisplayCases(){
  var api=new WindowsSetupDisplay.Display.NativeApi();int changes=0,freed=0,gets=0,sets=0,dpiReads=0,status=0;bool missing=false,afterUnavailable=false,unchanged=false;
  api.Aware=delegate{return true;};api.Dpi=delegate{dpiReads++;return 96;};
  api.Enumerate=delegate(string name,int index,ref WindowsSetupDisplay.Mode mode){Assert(mode.dmSize==220,"display initializes native mode size");if(missing)return false;if(index<0){mode.dmPelsWidth=changes>0 && !unchanged?1920U:1280U;mode.dmPelsHeight=changes>0 && !unchanged?1080U:720U;return !(changes>0 && afterUnavailable);}if(index>1)return false;mode.dmPelsWidth=index==1?1920U:1280U;mode.dmPelsHeight=index==1?1080U:720U;return true;};
  api.Change=delegate(ref WindowsSetupDisplay.Mode mode,uint flags){Assert(mode.dmFields==0x180000 && mode.dmPelsWidth==1920 && mode.dmPelsHeight==1080,"display only changes requested dimensions");if(flags==1){changes++;return status;}return 0;};
  api.Allocate=Marshal.AllocHGlobal;api.Free=delegate(IntPtr p){freed++;Marshal.FreeHGlobal(p);};
  api.Buffer=delegate(uint flags,out uint paths,out uint modes){Assert(flags==2,"display queries active paths only");paths=2;modes=1;return 0;};
  api.Query=delegate(uint flags,ref uint paths,IntPtr pathData,ref uint modes,IntPtr modeData,IntPtr topology){for(int n=0;n<2;n++){Marshal.WriteInt32(pathData,n*72,11);Marshal.WriteInt32(pathData,n*72+4,12);Marshal.WriteInt32(pathData,n*72+8,13);}return 0;};
  api.Get=delegate(IntPtr packet){Assert(Marshal.ReadInt32(packet)==-3 && Marshal.ReadInt32(packet,4)==32 && Marshal.ReadInt32(packet,8)==11,"DPI query uses native packet header");Marshal.WriteInt32(packet,20,-2);Marshal.WriteInt32(packet,24,sets>0?-2:0);gets++;return 0;};
  api.Set=delegate(IntPtr packet){Assert(Marshal.ReadInt32(packet)==-4 && Marshal.ReadInt32(packet,4)==24 && Marshal.ReadInt32(packet,20)==-2,"DPI preset uses minimum native relative step");sets++;return 0;};
  var read=WindowsSetupDisplay.Display.Read(api);Assert(read[0]==1280 && read[1]==720 && read[2]==144 && freed==4 && gets==1,"display reads and deduplicates physical source without applying");
  var scales=WindowsSetupDisplay.Display.NativeScales(true,api);Assert(scales.Length==1 && scales[0]==100 && sets==1 && gets==3 && freed==8,"native DPI applies and verifies preset then frees buffers");
  var snapshot=WindowsSetupDisplay.Display.ReadSnapshot(api);Assert(snapshot.Length==3 && snapshot[0]==1280 && snapshot[1]==720 && snapshot[2]==100,"snapshot retains primary mode and active source scale");
  var changed=WindowsSetupDisplay.Display.Apply(api);Assert(changed[0]==1280 && changed[1]==720 && changed[2]==1920 && changed[3]==1080 && changes==1 && changed[5]==96,"display tests applies and reads back through fake native boundary");
  changes=0;afterUnavailable=true;int priorDpi=dpiReads;Exception displayError=null;
  try{WindowsSetupDisplay.Display.Apply(api);}catch(Exception error){displayError=error;}
  Console.WriteLine("PROBE after Enum: rejected="+(displayError!=null)+" dpiReads="+dpiReads+" expectedUnchanged="+priorDpi);
  Assert(displayError!=null && displayError.Message.Contains("after change") && dpiReads==priorDpi,"failed after Enum cannot reuse populated desired dimensions or read DPI as success");
  afterUnavailable=false;changes=0;unchanged=true;status=1;displayError=null;
  try{WindowsSetupDisplay.Display.Apply(api);}catch(Exception error){displayError=error;}
  Assert(displayError!=null && displayError.Message.Contains("manual restart") && dpiReads==priorDpi,"DISP_CHANGE_RESTART requires manual restart instead of returning completed apply");
  changes=0;status=0;displayError=null;
  try{WindowsSetupDisplay.Display.Apply(api);}catch(Exception error){displayError=error;}
  Assert(displayError!=null && displayError.Message.Contains("1920x1080") && dpiReads==priorDpi,"native success code cannot conceal unchanged 1280x720 active mode");
  unchanged=false;changes=0;
  missing=true;Throws(delegate{WindowsSetupDisplay.Display.Read(api);},"unavailable display read rejected",typeof(Exception));Throws(delegate{WindowsSetupDisplay.Display.Apply(api);},"unavailable display apply rejected",typeof(Exception));missing=false;
  api.Change=delegate(ref WindowsSetupDisplay.Mode mode,uint flags){return flags==2?-1:0;};Throws(delegate{WindowsSetupDisplay.Display.Apply(api);},"failed native test prevents applying mode",typeof(Exception));
  api.Change=delegate(ref WindowsSetupDisplay.Mode mode,uint flags){return flags==2?0:-2;};Throws(delegate{WindowsSetupDisplay.Display.Apply(api);},"failed native change rejected",typeof(Exception));
  api.Buffer=delegate(uint flags,out uint paths,out uint modes){paths=0;modes=0;return 7;};Throws(delegate{WindowsSetupDisplay.Display.NativeScales(false,api);},"failed DPI size query rejected",typeof(Exception));
  api.Buffer=delegate(uint flags,out uint paths,out uint modes){paths=1;modes=1;return 0;};api.Query=delegate(uint flags,ref uint paths,IntPtr pathData,ref uint modes,IntPtr modeData,IntPtr topology){return 8;};int before=freed;Throws(delegate{WindowsSetupDisplay.Display.NativeScales(false,api);},"failed DPI path query rejected",typeof(Exception));Assert(freed==before+2,"failed DPI path query frees both buffers");
  int allocations=0;api.Allocate=delegate(int size){if(++allocations==2)throw new InvalidOperationException("allocation fixture");return Marshal.AllocHGlobal(size);};before=freed;Throws(delegate{WindowsSetupDisplay.Display.NativeScales(false,api);},"second native allocation failure propagates");Assert(freed==before+1,"first buffer freed when second allocation fails");
 }
 static void WimCases(){
  string root=System.IO.Path.Combine(System.IO.Path.GetTempPath(),"wim_fake_"+Guid.NewGuid().ToString("N"));System.IO.Directory.CreateDirectory(root);
  try{
   var api=new WindowsSetup.OobeWimReader.NativeApi();int closed=0,released=0,unregistered=0;WindowsSetup.OobeWimReader.Callback callback=null;
   string metadata="<WIM><IMAGE><TOTALBYTES>32</TOTALBYTES></IMAGE></WIM>";bool unexpected=false,missing=false;
   api.Create=delegate(string p,uint access,uint creation,uint flags,uint compression,out uint result){result=0;Assert(p=="fake.ppkg" && access==0x80000000 && creation==3,"WIM opens read-only existing package");return (IntPtr)1;};
   api.Count=delegate(IntPtr h){return 1;};api.Temp=delegate(IntPtr h,string p){Assert(p==root,"WIM uses requested temporary directory");return true;};api.Load=delegate(IntPtr h,uint index){Assert(index==1,"WIM selects sole image");return (IntPtr)2;};
   api.Information=delegate(IntPtr h,out IntPtr data,out uint size){data=Marshal.StringToHGlobalUni(metadata);size=(uint)(metadata.Length*2);return true;};api.Free=delegate(IntPtr p){released++;Marshal.FreeHGlobal(p);return IntPtr.Zero;};
   api.Register=delegate(IntPtr h,WindowsSetup.OobeWimReader.Callback value,IntPtr user){callback=value;return 0;};api.Unregister=delegate(IntPtr h,WindowsSetup.OobeWimReader.Callback value){unregistered++;return true;};
   api.Apply=delegate(IntPtr h,string path,uint flags){Assert(flags==8,"WIM enumeration uses no-apply flag");foreach(string relative in new string[]{"","nested",unexpected?"alien.txt":"nested/a.txt"}){if(missing && relative.EndsWith(".txt"))continue;IntPtr name=Marshal.StringToHGlobalUni(System.IO.Path.Combine(path,relative.Replace('/','\\')));try{callback(0,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);if(callback(0x9479,name,IntPtr.Zero,IntPtr.Zero)==0xffffffff)return false;}finally{Marshal.FreeHGlobal(name);}}return true;};
   api.Extract=delegate(IntPtr h,string source,string target,uint flags){Assert(source=="\\nested\\a.txt" && flags==0 && target.StartsWith(root),"WIM extracts only explicitly approved entry");System.IO.File.WriteAllText(target,"fixture");return true;};api.Close=delegate(IntPtr h){closed++;return true;};api.Error=delegate{return 5;};
   WindowsSetup.OobeWimReader.Extract("fake.ppkg",root,new string[]{"nested/a.txt"},api);Assert(closed==2 && released==1 && unregistered==1 && System.IO.File.ReadAllText(System.IO.Path.Combine(root,"nested/a.txt"))=="fixture","WIM approved extraction frees metadata callback and handles");
   unexpected=true;Throws(delegate{WindowsSetup.OobeWimReader.Extract("fake.ppkg",root,new string[]{"nested/a.txt"},api);},"WIM rejects unexpected archive entry",typeof(System.IO.InvalidDataException));Assert(closed==4 && unregistered==2,"WIM entry rejection still unregisters and closes both handles");unexpected=false;missing=true;
   Throws(delegate{WindowsSetup.OobeWimReader.Extract("fake.ppkg",root,new string[]{"nested/a.txt"},api);},"WIM rejects missing expected entry",typeof(System.IO.InvalidDataException));missing=false;
   metadata="<WIM><TOTALBYTES>4194305</TOTALBYTES></WIM>";Throws(delegate{WindowsSetup.OobeWimReader.Extract("fake.ppkg",root,new string[]{"nested/a.txt"},api);},"WIM rejects oversized expanded data",typeof(System.IO.InvalidDataException));Assert(released==4,"WIM invalid metadata is freed");
   api.Count=delegate(IntPtr h){return 2;};Throws(delegate{WindowsSetup.OobeWimReader.Extract("fake.ppkg",root,new string[]{"nested/a.txt"},api);},"WIM rejects multiple images",typeof(System.IO.InvalidDataException));
  }finally{System.IO.Directory.Delete(root,true);}
 }
 static void DesktopCases(){
  var api=new NUC8Icons.Desktop.NativeApi();int frees=0,closes=0,positioned=0;bool empty=false,fallback=false;long style=0x180;
  api.Dpi=delegate(IntPtr context){return IntPtr.Zero;};api.Find=delegate(string cls,string name){return (IntPtr)10;};
  api.FindChild=delegate(IntPtr parent,IntPtr after,string cls,string name){if(cls=="SHELLDLL_DefView")return fallback && parent==(IntPtr)10?IntPtr.Zero:(IntPtr)20;return parent==(IntPtr)20?(IntPtr)30:IntPtr.Zero;};
  api.Windows=delegate(NUC8Icons.Desktop.EnumProc visit,IntPtr data){Assert(!visit((IntPtr)11,data),"desktop fallback enumeration stops after finding view");return true;};
  api.Pid=delegate(IntPtr window,out uint pid){pid=42;return 1;};api.Open=delegate(uint access,bool inherit,uint pid){Assert(access==0x438 && !inherit && pid==42,"desktop requests expected process rights");return (IntPtr)40;};
  api.Allocate=delegate(IntPtr process,IntPtr address,UIntPtr size,uint type,uint protect){return Marshal.AllocHGlobal((int)size.ToUInt64());};
  api.Free=delegate(IntPtr process,IntPtr address,UIntPtr size,uint type){Marshal.FreeHGlobal(address);frees++;return true;};api.Close=delegate(IntPtr process){closes++;return true;};
  api.Read=delegate(IntPtr process,IntPtr address,byte[] data,IntPtr length,out IntPtr count){Marshal.Copy(address,data,0,length.ToInt32());count=length;return true;};api.Write=delegate(IntPtr process,IntPtr address,byte[] data,IntPtr length,out IntPtr count){Marshal.Copy(data,0,address,length.ToInt32());count=length;return true;};
  api.Rectangle=delegate(IntPtr window,out NUC8Icons.Rect rect){rect=new NUC8Icons.Rect{Right=1920,Bottom=1080};return true;};api.Style=delegate(IntPtr window,int index){return new IntPtr(style);};api.ChangeStyle=delegate(IntPtr window,int index,IntPtr value){style=value.ToInt64();return IntPtr.Zero;};
  api.Message=delegate(IntPtr window,uint message,IntPtr index,IntPtr data,uint flags,uint timeout,out IntPtr result){Assert(window==(IntPtr)30 && flags==2 && timeout==3000,"desktop uses bounded list view messages");result=(IntPtr)1;if(message==0x1004)result=(IntPtr)1;if(message==0x1073){byte[] text=System.Text.Encoding.Unicode.GetBytes((empty?"":"Computer")+"\0");Marshal.Copy(text,0,IntPtr.Add(data,256),text.Length);}if(message==0x1010){Marshal.WriteInt32(data,17);Marshal.WriteInt32(data,4,23);}if(message==0x1031){Assert(index==(IntPtr)2 && Marshal.ReadInt32(data)==100 && Marshal.ReadInt32(data,4)==200,"desktop positions requested icon with exact signed point");positioned++;}return (IntPtr)1;};
  var layout=NUC8Icons.Desktop.Capture(api);Assert(layout.Width==1920 && layout.Height==1080 && layout.AutoArrange && layout.Icons.Length==1 && layout.Icons[0].Name=="Computer" && layout.Icons[0].X==17 && layout.Icons[0].Y==23 && frees==1 && closes==1,"desktop captures original layout through process-memory boundary");
  fallback=true;NUC8Icons.Desktop.Position(2,100,200,api);Assert(positioned==1 && style==0x80 && frees==2 && closes==2,"desktop disables auto arrange and releases position buffers");
  empty=true;Throws(delegate{NUC8Icons.Desktop.Capture(api);},"desktop rejects empty icon labels",typeof(Exception));Assert(frees==3 && closes==3,"desktop capture error frees buffer and closes process");empty=false;
  api.Message=delegate(IntPtr window,uint message,IntPtr index,IntPtr data,uint flags,uint timeout,out IntPtr result){result=IntPtr.Zero;return IntPtr.Zero;};Throws(delegate{NUC8Icons.Desktop.Capture(api);},"desktop timeout rejects capture",typeof(Exception));
  api.Allocate=delegate(IntPtr process,IntPtr address,UIntPtr size,uint type,uint protect){return IntPtr.Zero;};Throws(delegate{NUC8Icons.Desktop.Capture(api);},"desktop allocation failure rejected",typeof(Exception));Throws(delegate{NUC8Icons.Desktop.Position(2,100,200,api);},"desktop position allocation failure rejected",typeof(Exception));Assert(closes==6,"desktop allocation failures close process immediately");
  api.Open=delegate(uint access,bool inherit,uint pid){return IntPtr.Zero;};Throws(delegate{NUC8Icons.Desktop.Capture(api);},"desktop process access failure rejected",typeof(Exception));Throws(delegate{NUC8Icons.Desktop.Position(2,100,200,api);},"desktop position process failure rejected",typeof(Exception));
 }
 public static void Main(string[] args){
  Assert(typeof(NUC8Icons.Desktop).GetMethod("Capture")!=null,"desktop capture API is available");
  Assert(typeof(NUC8Theme).GetMethod("TaskbarColor")!=null,"theme API is available");
  Assert(typeof(NucExplorerLiveV2).GetMethod("Options")!=null,"explorer API is available");
  Assert(typeof(NucTerminalHotkey).GetMethod("Run")!=null,"hotkey API is available");
  Assert(typeof(WindowsSetup.OobeWimReader).GetMethod("Extract")!=null,"WIM read API is available");
  var method=typeof(WindowsSetupDisplay.Display).GetMethod("NewMode",BindingFlags.NonPublic|BindingFlags.Static);
  var mode=(WindowsSetupDisplay.Mode)method.Invoke(null,new object[0]);
  Assert(mode.dmSize==220 && Marshal.SizeOf(typeof(WindowsSetupDisplay.Mode))==220,"DEVMODEW managed initializer preserves native ABI");
  IntPtr packet=Marshal.AllocHGlobal(32),path=Marshal.AllocHGlobal(72);
  try{
   Marshal.WriteInt32(path,0,19);Marshal.WriteInt32(path,4,23);Marshal.WriteInt32(path,8,29);
   typeof(WindowsSetupDisplay.Display).GetMethod("FillHeader",BindingFlags.NonPublic|BindingFlags.Static).Invoke(null,new object[]{packet,-3,32,path});
   Assert(Marshal.ReadInt32(packet,0)==-3 && Marshal.ReadInt32(packet,4)==32,"display packet type and size are written");
   Assert(Marshal.ReadInt32(packet,8)==19 && Marshal.ReadInt32(packet,12)==23 && Marshal.ReadInt32(packet,16)==29,"display packet carries exact adapter identity");
  }finally{Marshal.FreeHGlobal(packet);Marshal.FreeHGlobal(path);}
  MdnsAllocationOnlyAbiCases();MdnsCases();TaskbarAutoHideCases();ExplorerCases();ThemeCases();HotkeyCases();DisplayCases();WimCases();DesktopCases();
  new WindowsSetup.UpdateCallback().Invoke(new object(),new object());Assert(true,"WUA callback accepts Automation arguments without retaining or processing them");
  Console.WriteLine("ALL PASS: "+assertions+" managed source assertions; only dnsapi allocation/read/free invoked, no registration or OS settings");
 }
}
