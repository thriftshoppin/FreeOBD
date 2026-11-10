param([Parameter(Mandatory)][string]$Address, [string[]]$Pins = @('1234','0000','6789','1111'))
$src=@'
using System;using System.Runtime.InteropServices;
public static class Bt {
 [StructLayout(LayoutKind.Sequential)] public struct SYSTEMTIME{public ushort a,b,c,d,e,f,g,h;}
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct DEV{public int dwSize;public ulong Address;public uint ulClassofDevice;public bool fConnected,fRemembered,fAuthenticated;public SYSTEMTIME lastSeen,lastUsed;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=248)] public string szName;}
 [StructLayout(LayoutKind.Sequential)] public struct RADIOP{public int dwSize;}
 [DllImport("bthprops.cpl",SetLastError=true)] static extern IntPtr BluetoothFindFirstRadio(ref RADIOP p,out IntPtr h);
 [DllImport("bthprops.cpl",CharSet=CharSet.Unicode)] static extern uint BluetoothAuthenticateDevice(IntPtr hwnd,IntPtr hRadio,ref DEV d,string pass,uint len);
 [DllImport("bthprops.cpl",CharSet=CharSet.Unicode)] static extern uint BluetoothSetServiceState(IntPtr hRadio,ref DEV d,ref Guid g,uint flags);
 public static string Pair(ulong addr,string pin){
  var rp=new RADIOP{dwSize=4}; IntPtr h; IntPtr f=BluetoothFindFirstRadio(ref rp,out h);
  if(f==IntPtr.Zero) return "no radio";
  var d=new DEV{dwSize=Marshal.SizeOf(typeof(DEV)),Address=addr};
  uint r=BluetoothAuthenticateDevice(IntPtr.Zero,h,ref d,pin,(uint)pin.Length);
  if(r!=0) return "auth error "+r;
  Guid spp=new Guid("00001101-0000-1000-8000-00805F9B34FB");
  uint s=BluetoothSetServiceState(h,ref d,ref spp,1);
  return "paired; SPP enable="+s;
 }
}
'@
Add-Type -TypeDefinition $src
$a=[Convert]::ToUInt64($Address,16)
foreach($pin in $Pins){ $r=[Bt]::Pair($a,$pin); "PIN $pin -> $r"; if($r -like 'paired*'){break} }
Start-Sleep 4
"COM ports: " + ([System.IO.Ports.SerialPort]::GetPortNames() -join ',')

