#![windows_subsystem = "windows"]
include!("../core.inc.rs");
#[path = "../dashboard_proxy.rs"]
mod dashboard_proxy;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use raw_window_handle::{
    HandleError, HasWindowHandle, RawWindowHandle, Win32WindowHandle, WindowHandle,
};
use serde_json::{json, Value};
use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    num::NonZeroIsize,
    sync::Arc,
};
use wry::{
    dpi::{PhysicalPosition, PhysicalSize},
    Rect as ViewRect, WebView, WebViewBuilder,
};
const IPC: u32 = WM_APP + 4;
const EXIT_APP: u32 = WM_APP + 5;
thread_local! {
    static QUEUE: RefCell<VecDeque<Value>> = const { RefCell::new(VecDeque::new()) };
}
struct Host(HWND);
impl HasWindowHandle for Host {
    fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
        let v = NonZeroIsize::new(self.0).ok_or(HandleError::Unavailable)?;
        Ok(unsafe { WindowHandle::borrow_raw(RawWindowHandle::Win32(Win32WindowHandle::new(v))) })
    }
}
#[link(name = "dwmapi")]
extern "system" {
    fn DwmSetWindowAttribute(h: HWND, a: u32, v: *const core::ffi::c_void, n: u32) -> i32;
}
unsafe fn icon() -> HICON {
    let i = LoadIconW(GetModuleHandleW(null()), 101usize as *const u16);
    if i == 0 {
        LoadIconW(0, IDI_APPLICATION)
    } else {
        i
    }
}
unsafe fn dark(h: HWND) {
    for (a, v) in [
        (20, 1u32),
        (35, 0x25241d),
        (34, 0x4d5046),
        (36, 0x00ecf2f0),
        (33, 2),
    ] {
        DwmSetWindowAttribute(h, a, &v as *const _ as _, 4);
    }
}
unsafe fn bounds(h: HWND) -> ViewRect {
    let mut r: RECT = zeroed();
    GetClientRect(h, &mut r);
    ViewRect {
        position: PhysicalPosition::new(0, 0).into(),
        size: PhysicalSize::new(
            r.right.clamp(1, i32::MAX) as u32,
            r.bottom.clamp(1, i32::MAX) as u32,
        )
        .into(),
    }
}
struct Modern {
    h: HWND,
    view: Option<WebView>,
    preview: bool,
    hot: bool,
    tray: bool,
    tray_error: bool,
    tray_retry_at: Option<std::time::Instant>,
    startup_enabled: bool,
    run: Option<Running>,
    ready: bool,
    external: bool,
    error: bool,
    detail: String,
    mask: u8,
    events: Vec<Value>,
    last_render: String,
}
impl Modern {
    fn new(h: HWND, preview: bool) -> Self {
        Self {
            h,
            view: None,
            preview,
            hot: false,
            tray: false,
            tray_error: false,
            tray_retry_at: None,
            startup_enabled: startup_enabled(),
            run: None,
            ready: false,
            external: false,
            error: false,
            detail: String::new(),
            mask: fs::read_to_string(policy())
                .ok()
                .and_then(|s| s.trim().parse::<u8>().ok())
                .filter(|m| *m <= 31)
                .unwrap_or(0),
            events: vec![],
            last_render: String::new(),
        }
    }
    fn note(&mut self, s: &str) {
        if !self.preview {
            if let Ok(mut f) = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(logfile())
            {
                let _ = writeln!(
                    f,
                    "{} {s}",
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs()
                );
            }
        }
        self.events.push(json!({"time":local_clock(),"body":s}));
        if self.events.len() > 50 {
            self.events.remove(0);
        }
    }
    fn status(&mut self, s: &str) {
        if self.detail != s {
            self.detail = s.into();
            self.note(s);
        }
    }
    fn fail(&mut self, s: &str) {
        self.error = true;
        self.status(s);
    }
    fn publish(&mut self, force: bool) {
        let (state, label) = if self.preview {
            ("", "Preview")
        } else if self.ready {
            ("connected", "Connected")
        } else if self.run.is_some() {
            ("connecting", "Connecting")
        } else if self.error {
            ("error", "Error")
        } else {
            ("", "Offline")
        };
        let s=json!({"preview":self.preview,"hot":self.hot,"tray":self.tray,"running":self.run.is_some(),"ready":self.ready,"external":self.external,"state":state,"label":label,"detail":self.detail,"saved":keyfile().exists(),"mask":self.mask,"startupEnabled":self.startup_enabled,"events":self.events}).to_string();
        if !force && s == self.last_render {
            return;
        }
        if let Some(v) = self.view.as_ref() {
            if v.evaluate_script(&format!("if(window.renderState)window.renderState({s});"))
                .is_ok()
            {
                self.last_render = s;
            }
        }
    }
    fn start(&mut self, mut key: String, remember: bool) {
        if self.preview || !self.hot || self.run.is_some() {
            return;
        }
        self.error = false;
        match port_busy() {
            Ok(true) => {
                self.external = true;
                self.fail("Another process owns a protected dashboard port. Stop it before starting here.");
                return;
            }
            Ok(false) => {}
            Err(error) => {
                self.external = true;
                self.fail(&format!(
                    "Could not verify protected dashboard port ownership: {error}"
                ));
                return;
            }
        }
        self.external = false;

        let profile = profile_file();
        if !profile.is_file() {
            self.fail("DeskPilot setup is incomplete. Run Install-DeskPilot.ps1 first.");
            return;
        }
        let tunnel_client = match validate_runtime(&dir(), RuntimeKind::TunnelClient) {
            Ok(runtime) => runtime,
            Err(error) => {
                self.fail(&format!("Tunnel runtime validation failed: {error}"));
                return;
            }
        };
        let node = match validate_runtime(&dir(), RuntimeKind::Node) {
            Ok(runtime) => runtime,
            Err(error) => {
                self.fail(&format!("Node runtime validation failed: {error}"));
                return;
            }
        };
        self.note(&format!(
            "Validated tunnel-client {} and Node.js {}.",
            tunnel_client.version, node.version
        ));
        let server = server_root();
        if !server.join("managed-launcher.mjs").is_file()
            || !server.join("dist").join("index.js").is_file()
        {
            self.fail("DeskPilot's packaged server files are missing. Repair the installation.");
            return;
        }
        let profile_text = match fs::read_to_string(&profile) {
            Ok(text) => text,
            Err(error) => {
                self.fail(&format!("Could not read the tunnel profile: {error}"));
                return;
            }
        };
        if !profile_uses_trusted_command(&profile_text, &node.path, &server) {
            self.fail("The tunnel profile does not use DeskPilot's exact packaged Node runtime. Repair the installation.");
            return;
        }
        if !profile_uses_trusted_dashboard(&profile_text) {
            self.fail("The tunnel profile does not use DeskPilot's protected loopback dashboard. Repair the installation.");
            return;
        }
        if !profile_uses_trusted_control_plane(&profile_text) {
            self.fail("The tunnel profile does not use the official OpenAI control plane and managed runtime-key reference. Repair the installation.");
            return;
        }
        let dashboard_path = profile_dashboard_base_path(&profile_text)
            .expect("trusted dashboard profile must contain a base path");

        if key.trim().is_empty() {
            match fs::read(keyfile())
                .ok()
                .and_then(|b| crypt(&b, false).ok())
                .and_then(|v| String::from_utf8(v).ok())
            {
                Some(v) => key = v,
                None => {
                    self.fail("Enter your runtime API key first.");
                    return;
                }
            }
        }
        if key.contains('\0') || key.len() > 4096 {
            self.fail("Invalid runtime API key.");
            return;
        }
        if remember {
            if crypt(key.as_bytes(), true)
                .and_then(|b| {
                    fs::create_dir_all(dir()).map_err(|e| e.to_string())?;
                    fs::write(keyfile(), b).map_err(|e| e.to_string())
                })
                .is_err()
            {
                self.fail("Could not protect and save the key. Start canceled.");
                return;
            }
        } else if keyfile().exists() && fs::remove_file(keyfile()).is_err() {
            self.fail("Could not remove stored key. Start canceled.");
            return;
        }
        if save_policy(self.mask).is_err() {
            self.fail("Permission save failed. Start canceled.");
            return;
        }

        let args = format!(
            "run --profile-file \"{}\" --control-plane.base-url=https://api.openai.com --control-plane.url-path= --health.listen-addr={} --health.unix-socket= --allow-remote-ui=false --open-web-ui=false --admin-ui.base-path={} --admin-ui.public-origin= --cloudflared.managed=false",
            profile.display(),
            dashboard_proxy::UPSTREAM_ADDR,
            dashboard_path
        );
        let log_path = runtime_log_path();
        if log_path.exists() && fs::remove_file(&log_path).is_err() {
            self.fail("Could not reset the tunnel diagnostic log. Start canceled.");
            return;
        }
        let r = launch_with_output(
            Path::new(tunnel_client.path.to_string_lossy().as_ref()),
            &args,
            &key,
            true,
            Some(&log_path),
        );
        unsafe {
            key.as_mut_vec().fill(0);
        }
        match r {
            Ok(mut running) => {
                let upstream_pid = running.pid;
                let validator = Arc::new(move || {
                    listener_owners(dashboard_proxy::UPSTREAM_PORT)
                        .map(|listeners| listeners_are_owned_by(&listeners, upstream_pid))
                        .unwrap_or(false)
                });
                match dashboard_proxy::DashboardProxy::start(
                    dashboard_proxy::PUBLIC_ADDR.parse().unwrap(),
                    dashboard_proxy::UPSTREAM_ADDR.parse().unwrap(),
                    &dashboard_path,
                    validator,
                ) {
                    Ok(proxy) => {
                        running.dashboard = Some(proxy);
                        self.run = Some(running);
                        self.ready = false;
                        self.status("Connecting to your private tunnel…");
                    }
                    Err(error) => {
                        self.fail(&format!("Could not protect the local dashboard: {error}"))
                    }
                }
            }
            Err(error) => self.fail(&format!("Could not launch the tunnel: {error}")),
        }
    }
    fn stop(&mut self, why: &str) {
        if self.preview {
            return;
        }
        let was = self.run.take().is_some();
        self.ready = false;
        self.error = false;
        if was {
            self.note(why);
        }
        self.status("Offline — start when needed.");
    }
    fn tick(&mut self) {
        if self.preview {
            return;
        }
        if !self.tray
            && self
                .tray_retry_at
                .is_none_or(|at| at.elapsed() >= std::time::Duration::from_secs(5))
        {
            let _ = unsafe { self.ensure_tray() };
        }
        if let Some(r) = self.run.as_ref() {
            if unsafe { WaitForSingleObject(r.process, 0) } == WAIT_OBJECT_0 {
                let code = process_exit_code(r.process);
                self.run.take();
                self.ready = false;
                let detail = runtime_error_summary();
                let message = match (code, detail.is_empty()) {
                    (Some(code), false) => format!(
                        "Tunnel exited with code {code}. {detail} Review the runtime key or profile, then retry."
                    ),
                    (Some(code), true) => format!(
                        "Tunnel exited with code {code}. Review the runtime key or profile, then retry."
                    ),
                    (None, false) => format!("Tunnel exited. {detail} Review the runtime key or profile, then retry."),
                    (None, true) => "Tunnel exited. Review the runtime key or profile, then retry.".to_string(),
                };
                self.fail(&message);
                return;
            }
            let ready = dashboard_ready_for(r);
            let ownership = port_ownership(Some(r));
            self.ready = ready;
            let mut stop_reason = None;
            match ownership {
                Ok(PortOwnership::Supervised) => self.status(if ready {
                    "Connected — tunnel ready."
                } else {
                    "Connecting to your private tunnel…"
                }),
                Ok(PortOwnership::Foreign) => {
                    stop_reason = Some(
                        "The supervised tunnel lost ownership of the protected dashboard ports. Stopping."
                            .to_string(),
                    );
                }
                Err(error) => {
                    stop_reason = Some(format!("Could not verify tunnel port ownership: {error}"));
                }
                Ok(PortOwnership::Starting | PortOwnership::Free) => {
                    self.status("Connecting to your private tunnel…")
                }
            }
            if let Some(reason) = stop_reason {
                self.external = true;
                self.stop(&reason);
                self.fail(&reason);
            }
        } else {
            match port_ownership(None) {
                Ok(PortOwnership::Free) => self.external = false,
                Ok(_) => {
                    self.external = true;
                    self.status("Another process owns a protected dashboard port. Stop it first.");
                }
                Err(error) => {
                    self.external = true;
                    self.fail(&format!(
                        "Could not verify protected dashboard port ownership: {error}"
                    ));
                }
            }
            if !self.external {
                if !profile_file().is_file() {
                    self.status(
                        "Setup required — run Install-DeskPilot.ps1 to configure DeskPilot.",
                    );
                } else if runtime_path(&dir(), RuntimeKind::TunnelClient).is_err()
                    || runtime_path(&dir(), RuntimeKind::Node).is_err()
                {
                    self.status("Setup incomplete — repair DeskPilot's runtime dependencies.");
                } else if !self.error {
                    self.status("Offline — start when needed.");
                }
            }
        }
    }
    fn permission(&mut self, i: usize) {
        if self.preview || i >= 5 || self.external {
            return;
        }
        let m = self.mask ^ (1 << i);
        if save_policy(m).is_ok() {
            self.mask = m;
            let name = ["Terminal", "Files", "Screen", "Mouse", "Keyboard"][i];
            self.note(&format!(
                "{name}: {}",
                if m & (1 << i) != 0 {
                    "Allowed"
                } else {
                    "Blocked"
                }
            ));
        } else {
            self.stop("Permission update failed; stopped.");
            self.fail("Could not write permission policy.");
        }
    }
    unsafe fn tray(&mut self, add: bool) {
        let mut n: NOTIFYICONDATAW = zeroed();
        n.cbSize = size_of::<NOTIFYICONDATAW>() as u32;
        n.hWnd = self.h;
        n.uID = 1;
        n.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        n.uCallbackMessage = TRAY;
        n.hIcon = icon();
        let tip = w(TITLE);
        n.szTip[..tip.len()].copy_from_slice(&tip);
        if add {
            self.tray = Shell_NotifyIconW(NIM_ADD, &n) != 0;
        } else {
            Shell_NotifyIconW(NIM_DELETE, &n);
            self.tray = false;
        }
    }
    unsafe fn ensure_tray(&mut self) -> Result<(), String> {
        if self.preview || self.tray {
            return Ok(());
        }
        self.tray_retry_at = Some(std::time::Instant::now());
        self.tray(false);
        self.tray(true);
        if self.tray {
            self.tray_error = false;
            self.note("System tray recovery icon registered.");
            return Ok(());
        }
        let message =
            "Could not add the system tray icon. The DeskPilot window will stay open for recovery.";
        if !self.tray_error {
            self.note(message);
        }
        self.tray_error = true;
        Err(message.into())
    }
    fn hide_to_tray(&mut self) {
        if self.preview {
            return;
        }
        if unsafe { self.ensure_tray() }.is_ok() {
            unsafe { ShowWindow(self.h, SW_HIDE) };
        } else {
            self.fail("Could not hide to the tray. The recovery window remains open.");
            unsafe { ShowWindow(self.h, SW_RESTORE) };
        }
    }
    unsafe fn open(&mut self, path: &str) -> Result<(), u32> {
        let result = ShellExecuteW(
            self.h,
            w("open").as_ptr(),
            w(path).as_ptr(),
            null(),
            null(),
            SW_SHOWNORMAL,
        );
        if result <= 32 {
            Err(result.max(0) as u32)
        } else {
            Ok(())
        }
    }
    unsafe fn action(&mut self, v: Value) {
        let action = v.get("action").and_then(Value::as_str).unwrap_or("");
        if action == "ready" {
            if self.preview {
                let _ = fs::write(dir().join("modern-ui-ready.txt"), "UI_IPC_READY");
            }
            self.publish(true);
            return;
        }
        if self.preview {
            return;
        }
        match action {
            "start" => {
                let k = v
                    .get("key")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                self.start(
                    k,
                    v.get("remember").and_then(Value::as_bool).unwrap_or(false),
                );
            }
            "stop" => self.stop("Stopped by user."),
            "emergency" => self.stop("Emergency stop triggered."),
            "permission" => {
                if let Some(i) = v.get("index").and_then(Value::as_u64) {
                    self.permission(i as usize);
                }
            }
            "dashboard" => {
                let result = self.run.as_ref().map(open_dashboard);
                match result {
                    Some(Err(DashboardOpen::Opened)) => {
                        self.fail("Dashboard open returned an invalid result.")
                    }
                    Some(Ok(())) => self.note("Opened the local dashboard."),
                    Some(Err(DashboardOpen::BrowserFailed(code))) => self.fail(&format!(
                        "The dashboard is ready, but Windows could not open the browser (error {code})."
                    )),
                    Some(Err(DashboardOpen::NotReady)) => match port_ownership(self.run.as_ref()) {
                        Ok(PortOwnership::Supervised) => {
                            self.fail("The supervised tunnel's dashboard API is not ready.")
                        }
                        Ok(_) => {
                            self.external = true;
                            self.fail("The protected dashboard ports are not owned by the supervised DeskPilot tunnel. Refusing to open it.")
                        }
                        Err(error) => {
                            self.fail(&format!("Could not verify dashboard ownership: {error}"))
                        }
                    },
                    None => match port_busy() {
                        Ok(true) => {
                            self.external = true;
                            self.fail("Another process owns a protected dashboard port. Start DeskPilot's own tunnel first.")
                        }
                        Ok(false) => self.fail("Start the tunnel before opening the local dashboard."),
                        Err(error) => {
                            self.fail(&format!("Could not verify protected dashboard port ownership: {error}"))
                        }
                    },
                }
            }
            "open-keys" => {
                if let Err(code) =
                    self.open("https://platform.openai.com/settings/organization/api-keys")
                {
                    self.fail(&format!(
                        "Could not open API key settings (Windows error {code})."
                    ));
                }
            }
            "save-key" => {
                let mut k = v
                    .get("key")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let remember = v.get("remember").and_then(Value::as_bool).unwrap_or(false);
                if self.run.is_some() || self.external {
                    self.fail("Stop the active session before changing credentials.");
                } else if !remember {
                    self.fail("Enable Windows DPAPI storage before saving the key.");
                } else if k.trim().is_empty() || k.contains('\0') || k.len() > 4096 {
                    self.fail("Invalid runtime API key.");
                } else {
                    match crypt(k.as_bytes(), true)
                        .and_then(|b| fs::write(keyfile(), b).map_err(|e| e.to_string()))
                    {
                        Ok(()) => {
                            self.error = false;
                            self.status("Runtime key saved with Windows DPAPI.");
                        }
                        Err(_) => self.fail("Could not protect and save the runtime key."),
                    }
                }
                unsafe {
                    k.as_mut_vec().fill(0);
                }
            }
            "forget" => {
                if self.run.is_none() && !self.external {
                    if !keyfile().exists() || fs::remove_file(keyfile()).is_ok() {
                        self.note("Saved key removed.");
                    } else {
                        self.fail("Could not remove saved key.");
                    }
                }
            }
            "logs" => {
                let p = logfile().to_string_lossy().into_owned();
                if let Err(code) = self.open(&p) {
                    self.fail(&format!(
                        "Could not open the activity log (Windows error {code})."
                    ));
                }
            }
            "startup" => {
                let enabled = v.get("enabled").and_then(Value::as_bool).unwrap_or(false);
                match startup_apply(enabled) {
                    Ok(()) => {
                        self.startup_enabled = enabled;
                        self.error = false;
                        self.status(if enabled{"DeskPilot will launch quietly when you sign in. The tunnel remains stopped."}else{"Automatic launch disabled."});
                    }
                    Err(error) => {
                        self.startup_enabled = startup_enabled();
                        self.fail(&format!(
                            "Could not update Windows sign-in startup setting: {error}"
                        ));
                    }
                }
            }
            "tray" => self.hide_to_tray(),
            "show" => {
                ShowWindow(self.h, SW_RESTORE);
                SetForegroundWindow(self.h);
            }
            _ => {}
        }
        self.publish(false);
    }
}
unsafe extern "system" fn wnd(h: HWND, m: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let p = GetWindowLongPtrW(h, GWLP_USERDATA) as *mut Modern;
    if p.is_null() {
        if m == WM_DESTROY {
            PostQuitMessage(0);
            return 0;
        }
        return DefWindowProcW(h, m, wp, lp);
    }
    let a = &mut *p;
    match m {
        IPC => {
            loop {
                let msg = QUEUE.with(|q| q.borrow_mut().pop_front());
                match msg {
                    Some(v) => a.action(v),
                    None => break,
                }
            }
            0
        }
        WM_SIZE => {
            if wp != SIZE_MINIMIZED as usize {
                if let Some(v) = a.view.as_ref() {
                    let _ = v.set_bounds(bounds(h));
                }
            }
            0
        }
        WM_TIMER => {
            a.tick();
            a.publish(false);
            0
        }
        WM_HOTKEY => {
            if wp == HOT as usize && !a.preview {
                a.stop("Emergency stop triggered.");
                a.publish(true);
                ShowWindow(h, SW_RESTORE);
                SetForegroundWindow(h);
            }
            0
        }
        TRAY => {
            if lp as u32 == WM_LBUTTONDBLCLK {
                ShowWindow(h, SW_RESTORE);
                SetForegroundWindow(h);
            } else if lp as u32 == WM_RBUTTONUP {
                let menu = CreatePopupMenu();
                if menu != 0 {
                    for (id, name, disabled) in [
                        (110, "Open DeskPilot", false),
                        (101, "Start server", a.run.is_some() || !a.hot || a.external),
                        (102, "Stop server", a.run.is_none()),
                        (103, "Local dashboard", !a.ready),
                        (111, "Preferences", false),
                        (109, "Exit DeskPilot", false),
                    ] {
                        AppendMenuW(
                            menu,
                            MF_STRING | if disabled { MF_GRAYED } else { 0 },
                            id,
                            w(name).as_ptr(),
                        );
                    }
                    let mut pt: POINT = zeroed();
                    GetCursorPos(&mut pt);
                    SetForegroundWindow(h);
                    let id = TrackPopupMenu(
                        menu,
                        TPM_RETURNCMD | TPM_RIGHTBUTTON,
                        pt.x,
                        pt.y,
                        0,
                        h,
                        null(),
                    );
                    DestroyMenu(menu);
                    if id != 0 {
                        PostMessageW(h, WM_COMMAND, id as usize, 0);
                    }
                    PostMessageW(h, WM_NULL, 0, 0);
                }
            }
            0
        }
        WM_COMMAND => {
            let id = (wp & 0xffff) as i32;
            match id {
                110 => a.action(json!({"action":"show"})),
                101 => {
                    if keyfile().exists() {
                        a.action(json!({"action":"start","key":"","remember":true}));
                    } else {
                        a.action(json!({"action":"show"}));
                    }
                }
                102 => a.action(json!({"action":"stop"})),
                103 => a.action(json!({"action":"dashboard"})),
                111 => {
                    ShowWindow(h, SW_RESTORE);
                    SetForegroundWindow(h);
                    if let Some(v) = a.view.as_ref() {
                        let _ = v.evaluate_script("if(window.openSettings)window.openSettings();");
                    }
                }
                109 => {
                    PostMessageW(h, EXIT_APP, 0, 0);
                }
                _ => {}
            }
            0
        }
        WM_GETMINMAXINFO => {
            let m = &mut *(lp as *mut MINMAXINFO);
            m.ptMinTrackSize.x = 760;
            m.ptMinTrackSize.y = 680;
            0
        }
        WM_CLOSE => {
            match close_window_action(a.preview, a.tray) {
                WindowCloseAction::Exit => {
                    PostMessageW(h, EXIT_APP, 0, 0);
                }
                WindowCloseAction::Hide => {
                    ShowWindow(h, SW_HIDE);
                }
                WindowCloseAction::KeepVisible => {
                    a.fail("Could not hide to the tray. The recovery window remains open.");
                    ShowWindow(h, SW_RESTORE);
                    a.publish(true);
                }
            }
            0
        }
        WM_QUERYENDSESSION => 1,
        WM_ENDSESSION => {
            if wp != 0 {
                PostMessageW(h, EXIT_APP, 0, 0);
            }
            0
        }
        EXIT_APP => {
            a.note("DeskPilot exited.");
            a.stop("DeskPilot exited.");
            KillTimer(h, 1);
            UnregisterHotKey(h, HOT);
            a.tray(false);
            SetWindowLongPtrW(h, GWLP_USERDATA, 0);
            drop(Box::from_raw(p));
            DestroyWindow(h);
            0
        }
        _ => DefWindowProcW(h, m, wp, lp),
    }
}
fn main() {
    set_app_id();
    let _ = fs::create_dir_all(dir());
    if std::env::args().any(|a| a == "--self-test") {
        let run_id = fresh_run_id();
        let result = self_test(&run_id);
        let written = write_self_test_results(&dir(), &run_id, &result);
        std::process::exit(if result.is_ok() && written.is_ok() {
            0
        } else {
            1
        })
    }
    let preview = std::env::args().any(|a| a == "--preview");
    let background = std::env::args().any(|a| a == "--background");
    // Startup reconciliation never starts a tunnel. --background only changes
    // initial window visibility after the user explicitly enabled sign-in launch.
    let startup_result = if preview { Ok(()) } else { startup_init() };
    unsafe {
        let mutex = CreateMutexW(
            null(),
            1,
            w(if preview {
                "Local\\CommandCenterModernPreview"
            } else {
                "Local\\DeskPilotLauncher"
            })
            .as_ptr(),
        );
        if mutex == 0 || GetLastError() == ERROR_ALREADY_EXISTS {
            if mutex != 0 {
                CloseHandle(mutex);
            }
            if !background {
                MessageBoxW(
                    0,
                    w("DeskPilot is already running. Open it from the system tray.").as_ptr(),
                    w(TITLE).as_ptr(),
                    MB_OK,
                );
            }
            return;
        }
        SetProcessDPIAware();
        let instance = GetModuleHandleW(null());
        let cls = w("DeskPilotWindow");
        let brush = CreateSolidBrush(0x25241d);
        let wc = WNDCLASSW {
            lpfnWndProc: Some(wnd),
            hInstance: instance,
            lpszClassName: cls.as_ptr(),
            hCursor: LoadCursorW(0, IDC_ARROW),
            hIcon: icon(),
            hbrBackground: brush,
            ..zeroed()
        };
        RegisterClassW(&wc);
        let mut work: RECT = zeroed();
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &mut work as *mut _ as _, 0);
        let width = (work.right - work.left - 48).clamp(760, 1080);
        let height = (work.bottom - work.top - 48).clamp(680, 760);
        let h = CreateWindowExW(
            0,
            cls.as_ptr(),
            w(if preview {
                "DeskPilot - Preview"
            } else {
                TITLE
            })
            .as_ptr(),
            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
            work.left + (work.right - work.left - width) / 2,
            work.top + (work.bottom - work.top - height) / 2,
            width,
            height,
            0,
            0,
            instance,
            null(),
        );
        if h != 0 {
            dark(h);
            SendMessageW(h, WM_SETICON, ICON_SMALL as usize, icon());
            SendMessageW(h, WM_SETICON, ICON_BIG as usize, icon());
            let p = Box::into_raw(Box::new(Modern::new(h, preview)));
            SetWindowLongPtrW(h, GWLP_USERDATA, p as isize);
            let html = include_str!("../../assets/dashboard.html").replace(
                "__ICON__",
                &STANDARD.encode(include_bytes!("../../assets/icon.png")),
            );
            let initial_navigation = Cell::new(true);
            let result = WebViewBuilder::new()
                .with_html(html)
                .with_background_color((29, 36, 37, 255))
                .with_incognito(true)
                .with_devtools(false)
                .with_navigation_handler(move |url| {
                    let local = url == "about:blank" || url.starts_with("data:text/html");
                    if local && initial_navigation.get() {
                        if url.starts_with("data:text/html") {
                            initial_navigation.set(false);
                        }
                        true
                    } else {
                        false
                    }
                })
                .with_new_window_req_handler(|_, _| wry::NewWindowResponse::Deny)
                .with_ipc_handler(move |req| {
                    let origin = req.uri().to_string();
                    if origin != "about:blank" || req.body().len() > 24576 {
                        return;
                    }
                    if let Ok(v) = serde_json::from_str::<Value>(req.body()) {
                        QUEUE.with(|q| {
                            let mut q = q.borrow_mut();
                            if q.len() < 16 {
                                q.push_back(v);
                            }
                        });
                        PostMessageW(h, IPC, 0, 0);
                    }
                })
                .with_bounds(bounds(h))
                .build_as_child(&Host(h));
            match result {
                Ok(v) => {
                    let a = &mut *p;
                    a.view = Some(v);
                    if preview {
                        a.detail = "Design preview only — existing tunnel is unaffected.".into();
                        a.note("Preview opened. Server controls are disabled.");
                    } else {
                        if let Err(error) = startup_result {
                            a.startup_enabled = false;
                            a.fail(&format!(
                                "Sign-in startup state could not be reconciled: {error}"
                            ));
                        }
                        a.hot = RegisterHotKey(
                            h,
                            HOT,
                            MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT,
                            VK_F12 as u32,
                        ) != 0;
                        a.note(if a.hot {
                            "Emergency hotkey registered."
                        } else {
                            "Emergency hotkey unavailable. Start blocked."
                        });
                        if a.ensure_tray().is_err() {
                            a.fail(
                                "System tray recovery is unavailable. The window will stay open.",
                            );
                        }
                        a.note("Tunnel stopped. Start it only when needed.");
                        if keyfile().exists() {
                            a.note("Saved runtime key available.");
                        }
                        a.tick();
                        SetTimer(h, 1, 1200, None);
                    }
                    a.publish(true);
                    if !background || !a.tray {
                        ShowWindow(h, SW_SHOW);
                    } else {
                        ShowWindow(h, SW_HIDE);
                    }
                    UpdateWindow(h);
                    if let Some(v) = a.view.as_ref() {
                        let _ = v.set_visible(true);
                        let _ = v.set_bounds(bounds(h));
                    }
                    let mut msg: MSG = zeroed();
                    while IsWindow(h) != 0 && GetMessageW(&mut msg, 0, 0, 0) > 0 {
                        TranslateMessage(&msg);
                        DispatchMessageW(&msg);
                    }
                }
                Err(e) => {
                    SetWindowLongPtrW(h, GWLP_USERDATA, 0);
                    drop(Box::from_raw(p));
                    DestroyWindow(h);
                    MessageBoxW(
                        0,
                        w(&format!("WebView2 initialization failed: {e}")).as_ptr(),
                        w(TITLE).as_ptr(),
                        MB_OK,
                    );
                }
            }
        }
        CloseHandle(mutex);
    }
}
