import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { promisify } from 'node:util';
import { z } from 'zod';
import type { ServerResult } from '../types.js';

const exec = promisify(execFile);
const hwnd = z.string().regex(/^[1-9][0-9]{0,18}$/);
const point = { x: z.number().int().min(-32768).max(32767), y: z.number().int().min(-32768).max(32767) };
const target = { window: hwnd, pid: z.number().int().positive().max(2147483647) };
const keys = z.enum(['ENTER','ESC','TAB','SPACE','BACKSPACE','DELETE','UP','DOWN','LEFT','RIGHT','HOME','END','PAGEUP','PAGEDOWN','F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12', ...'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.split('')]);
const specs = {
  capture_screen: { schema: z.strictObject({}), description: 'Capture the primary Windows display as a JPEG MCP image. Returns original desktop bounds and image dimensions. Screenshots may contain private information.', read: true },
  list_windows: { schema: z.strictObject({}), description: 'List visible top-level Windows applications, window handles, process IDs and bounds; use handle and PID for targeted input.', read: true },
  focus_window: { schema: z.strictObject(target), description: 'Focus a visible window identified by handle and PID. Input requires a fresh lease from this call and the same window must remain foreground.', read: false },
  mouse_move: { schema: z.strictObject({...target,...point}), description: 'Move cursor to desktop coordinates on the specified foreground window. Requires a fresh focus_window lease; never refocuses automatically.', read: false },
  mouse_click: { schema: z.strictObject({...target,...point,button:z.enum(['left','right','middle']).default('left'),count:z.number().int().min(1).max(2).default(1)}), description: 'Click desktop coordinates on the specified foreground window. Requires a fresh focus_window lease and rejects coordinates over another window.', read: false },
  mouse_scroll: { schema: z.strictObject({...target,...point,steps:z.number().int().min(-10).max(10).refine(n=>n!==0)}), description: 'Scroll at desktop coordinates on the specified foreground window. Requires a fresh focus_window lease; positive steps scroll up.', read: false },
  keyboard_type: { schema: z.strictObject({...target,text:z.string().min(1).max(500).refine(s=>!/[\x00-\x1f\x7f]/.test(s))}), description: 'Type literal Unicode text into the specified foreground window. Requires a fresh focus_window lease; does not use the clipboard or refocus automatically.', read: false },
  keyboard_press: { schema: z.strictObject({...target,key:keys,modifiers:z.array(z.enum(['CTRL','ALT','SHIFT','WIN'])).max(4).refine(a=>new Set(a).size===a.length).default([])}), description: 'Press a named key with optional modifiers in the specified foreground window. Requires a fresh focus_window lease.', read: false },
};
type Name = keyof typeof specs;
export const desktopEnabled = () => process.platform === 'win32' && process.env.DC_PRIVATE_DESKTOP === '1';
export const isDesktopTool = (name:string): name is Name => Object.prototype.hasOwnProperty.call(specs,name);
export const desktopTools = () => desktopEnabled() ? Object.entries(specs).map(([name,s])=>({
  name, description:s.description, inputSchema:z.toJSONSchema(s.schema,{target:'draft-07',io:'input'}),
  annotations:{readOnlyHint:s.read,destructiveHint:!s.read,openWorldHint:!s.read,idempotentHint:false},
})) : [];

export interface ForegroundLease {
  token: string;
  window: string;
  pid: number;
  processCreated: string;
  expiresAt: number;
}

/** Returns a safe explanation when a lease cannot authorize input, otherwise null. */
export function validateForegroundLease(lease: ForegroundLease | null, target: {window:string;pid:number}, now = Date.now()): string | null {
  if (!lease || !lease.token) return 'Foreground lease token is missing; call focus_window again.';
  if (lease.window !== target.window) return 'Foreground lease window does not match the requested window.';
  if (lease.pid !== target.pid) return 'Foreground lease PID does not match the requested process.';
  if (typeof lease.processCreated !== 'string' || !/^[1-9][0-9]{0,18}$/.test(lease.processCreated)) return 'Foreground lease process identity is invalid.';
  if (!Number.isSafeInteger(lease.expiresAt) || now >= lease.expiresAt) return 'Foreground lease expired; call focus_window again.';
  return null;
}

const native = String.raw`
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DCNative {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; public POINT(int x,int y){X=x;Y=y;} }
 [StructLayout(LayoutKind.Sequential)] struct MOUSE { public int x,y; public uint data,flags,time; public UIntPtr extra; }
 [StructLayout(LayoutKind.Sequential)] struct KEY { public ushort vk,scan; public uint flags,time; public UIntPtr extra; }
 [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSE m; [FieldOffset(0)] public KEY k; }
 [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION data; }
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h,int cmd);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
 [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach,uint idAttachTo,bool fAttach);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
 [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h,uint flag);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
 [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int v);
 [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint n,INPUT[] a,int size);
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr h,out long creation,out long exitTime,out long kernelTime,out long userTime);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder b,int max);
 public delegate bool EnumProc(IntPtr h,IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f,IntPtr l);
 public static string Title(IntPtr h){var b=new StringBuilder(512);GetWindowText(h,b,b.Capacity);return b.ToString();}
 public static long ProcessCreated(uint pid){var h=OpenProcess(0x1000,false,pid);if(h==IntPtr.Zero)throw new Exception("Process identity could not be verified");try{long c,e,k,u;if(!GetProcessTimes(h,out c,out e,out k,out u))throw new Exception("Process identity could not be verified");return c;}finally{CloseHandle(h);}}
 public static bool Activate(IntPtr h){uint foregroundPid;uint foregroundThread=GetWindowThreadProcessId(GetForegroundWindow(),out foregroundPid);uint currentThread=GetCurrentThreadId();bool attached=foregroundThread!=0&&foregroundThread!=currentThread&&AttachThreadInput(foregroundThread,currentThread,true);try{ShowWindowAsync(h,9);BringWindowToTop(h);SetForegroundWindow(h);System.Threading.Thread.Sleep(100);return GetForegroundWindow()==h;}finally{if(attached)AttachThreadInput(foregroundThread,currentThread,false);}}
 static void Send(INPUT[] a){if(SendInput((uint)a.Length,a,Marshal.SizeOf(typeof(INPUT)))!=a.Length)throw new Exception("Windows rejected or partially delivered input; outcome uncertain");}
 static INPUT K(ushort vk,ushort scan,uint flags){var a=new INPUT();a.type=1;a.data.k=new KEY{vk=vk,scan=scan,flags=flags};return a;}
 static INPUT M(uint flags,uint data){var a=new INPUT();a.type=0;a.data.m=new MOUSE{flags=flags,data=data};return a;}
 public static void Text(string s){var a=new INPUT[s.Length*2];for(int i=0;i<s.Length;i++){a[2*i]=K(0,s[i],4);a[2*i+1]=K(0,s[i],6);}Send(a);}
 public static void Chord(int key,int[] mods){var a=new INPUT[mods.Length*2+2];int i=0;foreach(var m in mods)a[i++]=K((ushort)m,0,0);a[i++]=K((ushort)key,0,0);a[i++]=K((ushort)key,0,2);for(int j=mods.Length-1;j>=0;j--)a[i++]=K((ushort)mods[j],0,2);Send(a);}
 public static void Click(string button){uint d=button=="left"?2u:button=="right"?8u:32u;Send(new INPUT[]{M(d,0),M(d*2,0)});}
 public static void Scroll(int steps){Send(new INPUT[]{M(2048,unchecked((uint)(steps*120)))});}
}
`;

export const privateDesktopNativeScript = String.raw`
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
` + native + String.raw`
'@
[void][DCNative]::SetProcessDPIAware()
if (-not [Environment]::UserInteractive -or (Get-Process -Id $PID).SessionId -eq 0) { throw 'No interactive desktop session' }
$a=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:DC_DESKTOP_ARGS)))
function Target {
 param([int64]$ExpectedCreated=0)
 $h=[IntPtr]([long]$a.window); [uint32]$p=0
 [void][DCNative]::GetWindowThreadProcessId($h,[ref]$p)
 if (-not [DCNative]::IsWindow($h) -or -not [DCNative]::IsWindowVisible($h) -or $p -ne $a.pid) { throw 'Window identity changed or is unavailable' }
 if ($ExpectedCreated -gt 0) {
  $created=[DCNative]::ProcessCreated($p)
  if ($created -ne $ExpectedCreated) { throw 'Process identity changed or is unavailable' }
 }
 return $h
}
function ExpectedCreated {
 if (-not $a.lease -or -not $a.lease.token) { throw 'Foreground lease token is missing; call focus_window again' }
 return [int64]$a.lease.processCreated
}
function Foreground($h) { if ([DCNative]::GetForegroundWindow() -ne $h) { throw 'Target is not foreground; focus explicitly first' } }
function Lease($h) {
 if (-not $a.lease -or -not $a.lease.token) { throw 'Foreground lease token is missing; call focus_window again' }
 if ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -ge [int64]$a.lease.expiresAt) { throw 'Foreground lease expired; call focus_window again' }
 Foreground $h
}
function Point($h) {
 Lease $h
 $pt=New-Object DCNative+POINT([int]$a.x,[int]$a.y)
 if ([DCNative]::GetAncestor([DCNative]::WindowFromPoint($pt),2) -ne $h) { throw 'Point is not on the target window' }
 if (-not [DCNative]::SetCursorPos($a.x,$a.y)) { throw 'Windows rejected cursor move' }
 $actual=New-Object DCNative+POINT
 if (-not [DCNative]::GetCursorPos([ref]$actual) -or $actual.X -ne $a.x -or $actual.Y -ne $a.y) { throw 'Cursor position could not be verified' }
 Foreground $h
 if ([DCNative]::GetAncestor([DCNative]::WindowFromPoint($pt),2) -ne $h) { throw 'Target changed after moving cursor' }
}
function NoHeldKeys { foreach($v in @(16,17,18,91,92,1,2,4)) { if ([DCNative]::GetAsyncKeyState($v) -lt 0) { throw 'Physical modifier or mouse button is held; input was not sent' } } }
switch ($env:DC_DESKTOP_OP) {
 'capture_screen' {
  $b=[Windows.Forms.Screen]::PrimaryScreen.Bounds
  if ($b.Width -le 0 -or $b.Height -le 0 -or ([long]$b.Width*$b.Height) -gt 16000000) { throw 'Unsupported display dimensions' }
  $bmp=New-Object Drawing.Bitmap($b.Width,$b.Height)
  $g=[Drawing.Graphics]::FromImage($bmp); $ms=New-Object IO.MemoryStream
  try {
   $g.CopyFromScreen($b.Location,[Drawing.Point]::Empty,$b.Size)
   $w=[Math]::Min(1600,$b.Width); $h=[int][Math]::Round($b.Height*$w/$b.Width)
   $scaled=New-Object Drawing.Bitmap($bmp,$w,$h)
   try { $scaled.Save($ms,[Drawing.Imaging.ImageFormat]::Jpeg) } finally { $scaled.Dispose() }
   @{x=$b.X;y=$b.Y;width=$b.Width;height=$b.Height;imageWidth=$w;imageHeight=$h;data=[Convert]::ToBase64String($ms.ToArray())} | ConvertTo-Json -Compress
  } finally { $g.Dispose(); $bmp.Dispose(); $ms.Dispose() }
 }
 'list_windows' {
  $items=New-Object 'System.Collections.Generic.List[object]'
  $cb=[DCNative+EnumProc]{param($h,$l)
    if ([DCNative]::IsWindowVisible($h)) {
      $title=[DCNative]::Title($h)
      if ($title -and $items.Count -lt 100) {
       [uint32]$p=0; [void][DCNative]::GetWindowThreadProcessId($h,[ref]$p)
       $r=New-Object DCNative+RECT; [void][DCNative]::GetWindowRect($h,[ref]$r)
       $items.Add(@{window=$h.ToInt64().ToString();pid=$p;title=$title;x=$r.Left;y=$r.Top;width=$r.Right-$r.Left;height=$r.Bottom-$r.Top;foreground=([DCNative]::GetForegroundWindow() -eq $h)})
      }
    }; return $true
  }
  [void][DCNative]::EnumWindows($cb,[IntPtr]::Zero)
  ConvertTo-Json -InputObject @($items.ToArray()) -Depth 4 -Compress
 }
 'focus_window' {
  $h=Target
  if (-not [DCNative]::Activate($h)) { throw 'Windows denied explicit foreground activation' }
  Start-Sleep -Milliseconds 150; Foreground $h
  [uint32]$p=0; [void][DCNative]::GetWindowThreadProcessId($h,[ref]$p)
  @{ok=$true;focused=$true;processCreated=[string][DCNative]::ProcessCreated($p)} | ConvertTo-Json -Compress
 }
 'mouse_move' { $h=Target (ExpectedCreated); Lease $h; NoHeldKeys; Point $h; '{"ok":true,"cursorVerified":true}' }
 'mouse_click' {
  $h=Target (ExpectedCreated); Lease $h; NoHeldKeys; Point $h
  for($i=0;$i -lt $a.count;$i++){
   $h=Target (ExpectedCreated); Lease $h; [DCNative]::Click($a.button)
   if($i+1 -lt $a.count){Start-Sleep -Milliseconds 80; Point $h}
  }
  '{"ok":true,"inputDelivered":true}'
 }
 'mouse_scroll' { $h=Target (ExpectedCreated); Lease $h; NoHeldKeys; Point $h; $h=Target (ExpectedCreated); Lease $h; [DCNative]::Scroll($a.steps); '{"ok":true,"inputDelivered":true}' }
 'keyboard_type' { $h=Target (ExpectedCreated); Lease $h; NoHeldKeys; $h=Target (ExpectedCreated); Lease $h; [DCNative]::Text($a.text); '{"ok":true,"inputDelivered":true}' }
 'keyboard_press' {
  $h=Target (ExpectedCreated); Lease $h; NoHeldKeys; $h=Target (ExpectedCreated); Lease $h
  $map=@{ENTER=13;ESC=27;TAB=9;SPACE=32;BACKSPACE=8;DELETE=46;UP=38;DOWN=40;LEFT=37;RIGHT=39;HOME=36;END=35;PAGEUP=33;PAGEDOWN=34;CTRL=17;ALT=18;SHIFT=16;WIN=91}
  $v=if($map.ContainsKey($a.key)){$map[$a.key]}elseif($a.key -match '^F([1-9]|1[0-2])$'){111+[int]$a.key.Substring(1)}else{[int][char]$a.key}
  [int[]]$mods=@($a.modifiers | ForEach-Object {$map[$_]})
  [DCNative]::Chord($v,$mods); '{"ok":true,"inputDelivered":true}'
 }
 default {throw 'Unsupported desktop operation'}
}
`;

const FOREGROUND_LEASE_MS = 10_000;
let busy = false;
let focusedTarget: ForegroundLease | null = null;
const inputTools = new Set<Name>(['mouse_move','mouse_click','mouse_scroll','keyboard_type','keyboard_press']);

export async function runDesktopTool(name:Name,args:unknown):Promise<ServerResult>{
  const fail=(message:string):ServerResult=>({isError:true,content:[{type:'text',text:message}]});
  if(!desktopEnabled())return fail('Private desktop tools are disabled.');
  const parsed=specs[name].schema.safeParse(args??{});
  if(!parsed.success)return fail('Invalid desktop tool arguments. Check the tool schema.');
  const targetArgs = parsed.data as { window?: string; pid?: number };
  if(inputTools.has(name)){
    const leaseError=validateForegroundLease(focusedTarget,{window:String(targetArgs.window),pid:Number(targetArgs.pid)});
    if(leaseError)return fail(leaseError);
  }
  if(busy)return fail('Desktop operation in progress; retry sequentially.');
  busy=true;
  try{
    const leaseToken=randomBytes(24).toString('base64url');
    const nativeArgs=name==='focus_window'
      ? {...parsed.data,leaseToken}
      : inputTools.has(name)
        ? {...parsed.data,lease:focusedTarget}
        : parsed.data;
    const env={...process.env,DC_DESKTOP_OP:name,DC_DESKTOP_ARGS:Buffer.from(JSON.stringify(nativeArgs),'utf8').toString('base64')};
    const ps=process.env.SystemRoot+'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    const {stdout}=await exec(ps,['-NoProfile','-NonInteractive','-STA','-EncodedCommand',Buffer.from(privateDesktopNativeScript,'utf16le').toString('base64')],{env,windowsHide:true,timeout:12000,maxBuffer:4*1024*1024,encoding:'utf8'});
    const result=JSON.parse(stdout.trim());
    if(name==='focus_window'){
      const processCreated=String(result.processCreated??'');
      if(!/^[1-9][0-9]{0,18}$/.test(processCreated))throw new Error('Focus response did not include a valid process identity');
      focusedTarget={token:leaseToken,window:String(targetArgs.window),pid:Number(targetArgs.pid),processCreated,expiresAt:Date.now()+FOREGROUND_LEASE_MS};
      return {content:[{type:'text',text:JSON.stringify({ok:true,focused:true})}]};
    }
    if(name==='capture_screen'){
      const {data,...bounds}=result;
      if(typeof data!=='string'||data.length>3*1024*1024)return fail('Screenshot exceeds image size limit.');
      return {content:[{type:'text',text:JSON.stringify(bounds)},{type:'image',data,mimeType:'image/jpeg'}]};
    }
    return {content:[{type:'text',text:JSON.stringify(result)}]};
  }catch(e){
    if(name==='focus_window'||inputTools.has(name))focusedTarget=null;
    const err=e as {stderr?:string; killed?:boolean};
    if(process.env.DESKPILOT_DEBUG_DESKTOP==='1')console.error('Private desktop helper stderr:',err.stderr??e);
    const allowed=['No interactive desktop session','Window identity changed or is unavailable','Process identity could not be verified','Windows denied explicit foreground activation','Target is not foreground; focus explicitly first','Foreground lease token is missing; call focus_window again','Foreground lease expired; call focus_window again','Point is not on the target window','Windows rejected cursor move','Cursor position could not be verified','Target changed after moving cursor','Physical modifier or mouse button is held; input was not sent','Windows rejected or partially delivered input; outcome uncertain','Unsupported display dimensions'];
    const reason=allowed.find(s=>err.stderr?.includes(s));
    return fail(reason??(err.killed?'Desktop operation timed out; outcome uncertain.':'Desktop operation failed; outcome uncertain. Do not automatically retry input.'));
  }finally{busy=false;}
}
