import fs from 'node:fs';
import {spawn} from 'node:child_process';
const old=fs.readFileSync(new URL('./test-private-desktop-input.mjs',import.meta.url),'utf8');
const match=old.match(/const ps=String\.raw`([\s\S]*?)`;/);
if(!match)throw new Error('Fixture not found');
const ps=match[1].replace("DC isolated input acceptance","DC MCP live acceptance").replace('[void]$f.ShowDialog()',"$timer=New-Object Windows.Forms.Timer; $timer.Interval=180000; $timer.add_Tick({$f.Close()}); $timer.Start(); [void]$f.ShowDialog(); $timer.Dispose(); $f.Dispose()");
const child=spawn(process.env.SystemRoot+'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',['-NoProfile','-STA','-EncodedCommand',Buffer.from(ps,'utf16le').toString('base64')],{windowsHide:false,stdio:['ignore','inherit','inherit']});
child.on('exit',code=>process.exit(code??1));
