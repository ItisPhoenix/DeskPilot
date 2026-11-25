import {spawn} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {runDesktopTool} from '../dist/tools/private-desktop.js';

process.env.DC_PRIVATE_DESKTOP='1';
const focusFlag=fs.mkdtempSync(path.join(os.tmpdir(),'deskpilot-focus-flag-'));
const flagFile=path.join(focusFlag,'lose-focus.txt');
const ps=String.raw`
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type 'using System.Runtime.InteropServices; public static class TestDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
[void][TestDpi]::SetProcessDPIAware()
$f=New-Object Windows.Forms.Form
$f.Text='DC isolated input acceptance'
$f.ClientSize=New-Object Drawing.Size(430,310)
$f.StartPosition='CenterScreen'
$f.TopMost=$true
$t=New-Object Windows.Forms.TextBox
$t.Location=New-Object Drawing.Point(20,20)
$t.Width=340; $t.Multiline=$true; $t.Height=27
$b=New-Object Windows.Forms.Button
$b.Text='Test click'; $b.Location=New-Object Drawing.Point(20,60); $b.Width=140
$l=New-Object Windows.Forms.ListBox
$l.Location=New-Object Drawing.Point(20,110); $l.Size=New-Object Drawing.Size(340,170)
1..40 | ForEach-Object { [void]$l.Items.Add("Test item $_") }
$f.Controls.AddRange(@($t,$b,$l))
$t.add_KeyDown({param($sender,$e) [Console]::WriteLine("KEY "+$e.KeyData); if($e.Control -and $e.KeyCode -eq [Windows.Forms.Keys]::A){$t.SelectAll(); $e.SuppressKeyPress=$true; [Console]::WriteLine('CTRL_A_RECEIVED')}})
$t.add_TextChanged({[Console]::WriteLine("TEXT "+$t.Text)})
$b.add_Click({[Console]::WriteLine('CLICK')})
$l.add_MouseWheel({param($s,$e) [Console]::WriteLine("SCROLL "+$e.Delta)})
$poll=New-Object Windows.Forms.Timer
$poll.Interval=100
$poll.add_Tick({
 if(Test-Path $env:DC_TEST_FOCUS_FLAG){
  $poll.Stop()
  $other=New-Object Windows.Forms.Form
  $other.Text='DC focus loss fixture'; $other.TopMost=$true; $other.Size=New-Object Drawing.Size(240,120); $other.StartPosition='CenterScreen'
  [void]$other.Show(); [void]$other.Activate(); Start-Sleep -Milliseconds 150
  [Console]::WriteLine('FOCUS_LOST')
 }
})
$poll.Start()
$f.add_Shown({
 $f.Activate()
 $a=$t.PointToScreen((New-Object Drawing.Point(10,10)))
 $c=$b.PointToScreen((New-Object Drawing.Point(40,10)))
 $d=$l.PointToScreen((New-Object Drawing.Point(80,35)))
 [Console]::WriteLine('READY '+(@{window=$f.Handle.ToInt64().ToString();pid=$PID;textX=$a.X;textY=$a.Y;buttonX=$c.X;buttonY=$c.Y;scrollX=$d.X;scrollY=$d.Y}|ConvertTo-Json -Compress))
})
[void]$f.ShowDialog()
$poll.Dispose()
`;
const child=spawn(process.env.SystemRoot+'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',['-NoProfile','-STA','-EncodedCommand',Buffer.from(ps,'utf16le').toString('base64')],{windowsHide:false,stdio:['ignore','pipe','pipe'],env:{...process.env,DC_TEST_FOCUS_FLAG:flagFile}});
let lines=[],buf='',err='';
child.stderr.on('data',c=>err+=c);
child.stdout.setEncoding('utf8');
child.stdout.on('data',c=>{buf+=c;const parts=buf.split(/\r?\n/);buf=parts.pop();lines.push(...parts);});
const delay=ms=>new Promise(r=>setTimeout(r,ms));
async function until(predicate,ms=7000){const end=Date.now()+ms;while(Date.now()<end){const value=predicate();if(value)return value;if(child.exitCode!==null)throw new Error('Test window exited: '+err);await delay(100);}throw new Error('Timed out waiting for test window evidence: '+err);}
let passed=0;
async function check(name,args){const result=await runDesktopTool(name,args);const text=result.content.find(c=>c.type==='text')?.text;console.log(name,!result.isError,text);if(result.isError)throw new Error(name+' failed');passed++;}
async function checkDenied(name,args,pattern){const result=await runDesktopTool(name,args);const text=result.content.find(c=>c.type==='text')?.text;console.log(name,'DENIED',text);if(!result.isError||!pattern.test(text??''))throw new Error(name+' was not denied as expected');passed++;}
try{
  const ready=JSON.parse((await until(()=>lines.find(l=>l.startsWith('READY ')))).slice(6));
  console.log(JSON.stringify({ready,childPid:child.pid}));
  const target={window:ready.window,pid:ready.pid};
  const at=(x,y)=>({...target,x,y});
  await check('focus_window',target);
  const listing=await runDesktopTool('list_windows',{});
  const matches=JSON.parse(listing.content[0].text).filter(w=>w.title==='DC isolated input acceptance');
  if(matches.length!==1||!matches[0].foreground)throw new Error('Focused fixture was not reported as the foreground window');
  console.log('FOREGROUND_TARGET_VERIFIED');
  await check('mouse_move',at(ready.buttonX,ready.buttonY));
  await check('mouse_click',at(ready.buttonX,ready.buttonY));
  await until(()=>lines.includes('CLICK'));
  console.log('CLICK_EVENT_VERIFIED');
  await check('mouse_click',at(ready.textX,ready.textY));
  await check('keyboard_type',{...target,text:'DC_TEST_123'});
  await until(()=>lines.includes('TEXT DC_TEST_123'));
  console.log('TYPED_TEXT_VERIFIED');
  await check('keyboard_press',{...target,key:'BACKSPACE'});
  await until(()=>lines.includes('TEXT DC_TEST_12'));
  await check('keyboard_press',{...target,key:'A',modifiers:['CTRL']});
  await check('keyboard_type',{...target,text:'DC_FINAL'});
  await until(()=>lines.includes('TEXT DC_FINAL'));
  console.log('KEYBOARD_SHORTCUT_VERIFIED');
  await check('mouse_click',at(ready.scrollX,ready.scrollY));
  await check('mouse_scroll',{...at(ready.scrollX,ready.scrollY),steps:-2});
  await until(()=>lines.some(l=>l.startsWith('SCROLL -')));
  console.log('SCROLL_EVENT_VERIFIED');

  fs.writeFileSync(flagFile,'lose focus');
  await until(()=>lines.includes('FOCUS_LOST'));
  await checkDenied('keyboard_type',{...target,text:'SHOULD_NOT_APPEAR'},/not foreground/i);
  if(lines.some(l=>l.includes('SHOULD_NOT_APPEAR')))throw new Error('Input reached the fixture after focus loss');
  console.log('FOCUS_LOSS_REJECTED_WITHOUT_RETRY');
  await check('focus_window',target);
  await checkDenied('focus_window',{window:target.window,pid:target.pid+1},/identity changed|unavailable/i);
  console.log('NATIVE_PID_VALIDATION_VERIFIED');
  console.log('INPUT_ACCEPTANCE_PASS',passed);
}catch(e){console.error('INPUT_ACCEPTANCE_FAIL',e.message,JSON.stringify(lines));process.exitCode=1;}finally{child.kill();fs.rmSync(focusFlag,{recursive:true,force:true});}
