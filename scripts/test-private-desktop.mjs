import {runDesktopTool,desktopTools} from '../dist/tools/private-desktop.js';
process.env.DC_PRIVATE_DESKTOP='1';
const run=async(n,a={})=>{const r=await runDesktopTool(n,a); const t=r.content.find(c=>c.type==='text')?.text; return {ok:!r.isError,t,image:r.content.find(c=>c.type==='image')};};
console.log('TOOL_COUNT',desktopTools().length);
for(const n of ['list_windows','capture_screen']){
const r=await run(n); if(n==='list_windows'){console.log(n,r.ok,r.ok?JSON.parse(r.t).length:r.t)} else {console.log(n,r.ok,r.t,r.image?.mimeType,r.image?.data?.length,r.image?.data?.slice(0,4))}
}
console.log('INVALID_TARGET',await run('focus_window',{window:'1',pid:1}));
console.log('INVALID_ARGUMENT',await run('mouse_click',{window:'1',pid:1,x:0,y:0,count:99}));
