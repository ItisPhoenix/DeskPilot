import {lstatSync, readFileSync} from 'node:fs';
const categories: Record<string,number> = {
  start_process:1,read_process_output:1,interact_with_process:1,force_terminate:1,list_sessions:1,list_processes:1,kill_process:1,
  read_file:2,read_multiple_files:2,write_file:2,write_pdf:2,create_directory:2,list_directory:2,move_file:2,start_search:2,get_more_search_results:2,stop_search:2,list_searches:2,get_file_info:2,edit_block:2,
  capture_screen:4,list_windows:4,focus_window:8,mouse_move:8,mouse_click:8,mouse_scroll:8,keyboard_type:16,keyboard_press:16,
  get_config:0,get_usage_stats:0,get_recent_tool_calls:31,track_ui_event:31
};
export function managedPermission(name:string):boolean{
  const p=process.env.DC_MANAGED_POLICY;
  // Configuration changes are local-owner operations. Managed remote callers
  // are denied; direct local development/tests can present an environment
  // capability that the managed launcher never forwards.
  if(name==='set_config_value')return !p || !!process.env.DESKPILOT_TEST_LOCAL_CONFIG_TOKEN || process.env.DESKPILOT_LOCAL_DIAGNOSTICS === '1';
  const required=categories[name];
  if(typeof required!=='number')return false;
  if(process.env.DESKPILOT_LOCAL_DIAGNOSTICS === '1')return true;
  if(!p)return required===0;
  try{
  const stat=lstatSync(p);
  if(!stat.isFile()||stat.isSymbolicLink()||stat.size>2)return false;
  const v=readFileSync(p,'utf8');
  if(!/^(?:[0-9]|[12][0-9]|3[01])$/.test(v))return false;
  return (Number(v)&required)===required;
  }catch{return false;}
}
