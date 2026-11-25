use std::{
    env,
    fs,
    io::{Read, Write},
    mem::{size_of, zeroed},
    net::TcpStream,
    os::windows::{ffi::OsStrExt, io::AsRawHandle},
    path::{Path, PathBuf},
    ptr::{null, null_mut},
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use sha2::{Digest, Sha256};
use windows_sys::Win32::{
    Foundation::*,
    Graphics::Gdi::*,
    NetworkManagement::IpHelper::*,
    Security::{Cryptography::*, WinTrust::*},
    System::{
        Diagnostics::ToolHelp::*,
        JobObjects::*,
        LibraryLoader::*,
        Registry::*,
        Threading::*,
    },
    UI::{Input::KeyboardAndMouse::*, Shell::*, WindowsAndMessaging::*},
};

const TITLE: &str = "DeskPilot";
const DASH: &str = "http://127.0.0.1:8080/ui";
const APPID: &str = "DeskPilot.PrivateDesktopControl.1";
const TRAY: u32 = WM_APP + 1;
const HOT: i32 = 77;
const RUN_VALUE_NAME: &str = "DeskPilot";
const SELF_TEST_OUTPUT: &str = "self-test-modern.txt";
const SELF_TEST_EVIDENCE: &str = "self-test-evidence-modern.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RuntimeKind {
    Node,
    TunnelClient,
}

impl RuntimeKind {
    fn directory(self) -> &'static str {
        match self {
            Self::Node => "runtime",
            Self::TunnelClient => "bin",
        }
    }

    fn filename(self) -> &'static str {
        match self {
            Self::Node => "node.exe",
            Self::TunnelClient => "tunnel-client.exe",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ListenerOwner {
    loopback: bool,
    port: u16,
    pid: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PortOwnership {
    Free,
    Supervised,
    Foreign,
}

fn classify_port_ownership(
    listeners: &[ListenerOwner],
    port: u16,
    supervised_pid: Option<u32>,
) -> PortOwnership {
    let matching: Vec<_> = listeners.iter().filter(|row| row.port == port).collect();
    if matching.is_empty() {
        PortOwnership::Free
    } else if let Some(pid) = supervised_pid {
        if matching
            .iter()
            .all(|row| row.loopback && row.pid == pid)
        {
            PortOwnership::Supervised
        } else {
            PortOwnership::Foreign
        }
    } else {
        PortOwnership::Foreign
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DashboardOpen {
    Opened,
    NotReady,
    BrowserFailed(u32),
}

fn classify_dashboard_open(ready: bool, shell_result: isize) -> DashboardOpen {
    if !ready {
        DashboardOpen::NotReady
    } else if shell_result <= 32 {
        DashboardOpen::BrowserFailed(shell_result.max(0) as u32)
    } else {
        DashboardOpen::Opened
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WindowCloseAction {
    Exit,
    Hide,
    KeepVisible,
}

fn close_window_action(preview: bool, tray_registered: bool) -> WindowCloseAction {
    if preview {
        WindowCloseAction::Exit
    } else if tray_registered {
        WindowCloseAction::Hide
    } else {
        WindowCloseAction::KeepVisible
    }
}

#[repr(C)]
struct LocalTime {
    year: u16,
    month: u16,
    dow: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    millis: u16,
}

#[link(name = "kernel32")]
extern "system" {
    fn GetLocalTime(t: *mut LocalTime);
}

#[link(name = "crypt32")]
extern "system" {
    fn CryptMsgClose(message: *mut core::ffi::c_void) -> i32;
}

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

fn local_clock() -> String {
    unsafe {
        let mut t: LocalTime = zeroed();
        GetLocalTime(&mut t);
        format!("{:02}:{:02}:{:02}", t.hour, t.minute, t.second)
    }
}

fn w(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn err() -> String {
    std::io::Error::last_os_error().to_string()
}

fn dir() -> PathBuf {
    env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir)
        .join("DeskPilot")
}

fn app_root() -> PathBuf {
    env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(PathBuf::from))
        .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| env::temp_dir()))
}

fn server_root() -> PathBuf {
    app_root().join("server")
}

fn runtime_path(root: &Path, kind: RuntimeKind) -> Result<PathBuf, String> {
    let candidate = root.join(kind.directory()).join(kind.filename());
    if !trusted_runtime_candidate(root, kind, &candidate) {
        return Err(format!(
            "{} is missing or outside its trusted packaged location",
            candidate.display()
        ));
    }
    candidate
        .canonicalize()
        .map_err(|error| format!("Cannot resolve {}: {error}", candidate.display()))
}

fn trusted_runtime_candidate(root: &Path, kind: RuntimeKind, candidate: &Path) -> bool {
    let (Ok(root), Ok(directory), Ok(candidate)) = (
        root.canonicalize(),
        root.join(kind.directory()).canonicalize(),
        candidate.canonicalize(),
    ) else {
        return false;
    };
    let expected_directory = root.join(kind.directory());
    if !directory
        .to_string_lossy()
        .eq_ignore_ascii_case(&expected_directory.to_string_lossy())
    {
        return false;
    }
    candidate.parent().is_some_and(|parent| {
        parent
            .to_string_lossy()
            .eq_ignore_ascii_case(&directory.to_string_lossy())
    }) && candidate
        .file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case(kind.filename()))
}

fn non_verbatim_path(path: &Path) -> String {
    let path = path.to_string_lossy();
    path.strip_prefix(r"\\?\").unwrap_or(&path).to_string()
}

fn profile_uses_trusted_command(profile: &str, node: &Path, server: &Path) -> bool {
    let command = format!(
        "\"{}\" \"{}\"",
        non_verbatim_path(node),
        non_verbatim_path(&server.join("managed-launcher.mjs"))
    );
    let Ok(expected) = serde_json::to_string(&command) else {
        return false;
    };
    let mut commands = profile
        .lines()
        .map(str::trim)
        .filter_map(|line| line.strip_prefix("command:"));
    matches!(commands.next(), Some(actual) if actual.trim() == expected)
        && commands.next().is_none()
}

fn parse_stable_semver(input: &str) -> Option<String> {
    let input = input.strip_prefix('v').unwrap_or(input);
    let (version, metadata) = input.split_once('+').unwrap_or((input, ""));
    if metadata.is_empty() && input.contains('+') {
        return None;
    }
    if !metadata
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'.')
    {
        return None;
    }
    let mut parts = version.split('.');
    let major = parts.next()?;
    let minor = parts.next()?;
    let patch = parts.next()?;
    if parts.next().is_some()
        || [major, minor, patch].iter().any(|part| {
            part.is_empty()
                || (part.len() > 1 && part.starts_with('0'))
                || !part.bytes().all(|byte| byte.is_ascii_digit())
        })
    {
        return None;
    }
    Some(input.to_string())
}

fn parse_node_version(output: &str) -> Option<String> {
    let output = output.trim();
    if output.contains(char::is_whitespace) {
        return None;
    }
    let version = parse_stable_semver(output.strip_prefix('v')?)?;
    (version.split('.').next()? == "24").then_some(version)
}

fn parse_tunnel_version(output: &str) -> Option<String> {
    let output = output.trim();
    if output.contains(['\r', '\n']) {
        return None;
    }
    let version = if let Some(version) = output.strip_prefix("tunnel-client version ") {
        version
    } else if let Some(version) = output.strip_prefix("tunnel-client ") {
        version
    } else {
        output
    };
    let version = if let Some((version, suffix)) = version.split_once(" (git sha: ") {
        let sha = suffix.strip_suffix(')')?;
        if sha.len() < 7
            || sha.len() > 64
            || !sha.bytes().all(|byte| byte.is_ascii_hexdigit())
            || version.split_once('+')?.1 != sha
        {
            return None;
        }
        version
    } else {
        version
    };
    parse_stable_semver(version)
}

fn signer_allowed(kind: RuntimeKind, subject: &str) -> bool {
    let normalized = subject.split_whitespace().collect::<Vec<_>>().join(" ");
    let normalized = normalized.to_ascii_lowercase();
    match kind {
        RuntimeKind::Node => matches!(normalized.as_str(), "openjs foundation" | "node.js foundation"),
        RuntimeKind::TunnelClient => matches!(
            normalized.as_str(),
            "openai, l.l.c." | "openai llc" | "openai, inc." | "openai inc."
        ),
    }
}

#[derive(Default)]
struct RuntimePolicy {
    node_version: Option<String>,
    node_sha256: Option<String>,
    node_signer_subject: Option<String>,
    tunnel_version: Option<String>,
    tunnel_sha256: Option<String>,
    tunnel_signer_subject: Option<String>,
}

#[derive(Debug)]
struct ValidatedRuntime {
    path: PathBuf,
    version: String,
}

fn normalized_subject(subject: &str) -> String {
    subject
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase()
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn policy_string(
    object: &serde_json::Map<String, serde_json::Value>,
    key: &str,
) -> Result<Option<String>, String> {
    match object.get(key) {
        None => Ok(None),
        Some(serde_json::Value::String(value)) if !value.trim().is_empty() => {
            Ok(Some(value.trim().to_string()))
        }
        Some(_) => Err(format!("Runtime manifest field {key} must be a nonempty string")),
    }
}

fn runtime_policy(root: &Path) -> Result<RuntimePolicy, String> {
    let path = root.join("runtime-manifest.json");
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(RuntimePolicy::default())
        }
        Err(error) => return Err(format!("Cannot read runtime manifest: {error}")),
    };
    let value: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("Invalid runtime manifest: {e}"))?;
    let Some(root_object) = value.as_object() else {
        return Err("Runtime manifest must be a JSON object".into());
    };
    let mut policy = RuntimePolicy::default();
    for (name, kind) in [("node", RuntimeKind::Node), ("tunnelClient", RuntimeKind::TunnelClient)] {
        let Some(value) = root_object.get(name) else {
            continue;
        };
        let Some(object) = value.as_object() else {
            return Err(format!("Runtime manifest section {name} must be an object"));
        };
        let mut version = policy_string(object, "version")?;
        let sha256 = policy_string(object, "sha256")?.map(|value| value.to_ascii_lowercase());
        if let Some(version) = &mut version {
            let parsed = match kind {
                RuntimeKind::Node => {
                    let node_version = if version.starts_with('v') {
                        version.clone()
                    } else {
                        format!("v{version}")
                    };
                    parse_node_version(&node_version)
                }
                RuntimeKind::TunnelClient => parse_tunnel_version(version),
            };
            let Some(parsed) = parsed else {
                return Err(format!("Runtime manifest has an unsupported {name} version"));
            };
            *version = parsed;
        }
        if let Some(sha256) = &sha256 {
            if !valid_sha256(sha256) {
                return Err(format!("Runtime manifest has an invalid {name} SHA-256"));
            }
        }
        match kind {
            RuntimeKind::Node => {
                policy.node_version = version;
                policy.node_sha256 = sha256;
                policy.node_signer_subject = policy_string(object, "signerSubject")?;
            }
            RuntimeKind::TunnelClient => {
                policy.tunnel_version = version;
                policy.tunnel_sha256 = sha256;
                policy.tunnel_signer_subject = policy_string(object, "signerSubject")?;
            }
        }
    }
    Ok(policy)
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = fs::File::open(path).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn signer_subject(path: &Path) -> Result<String, String> {
    unsafe {
        let path = w(&path.to_string_lossy());
        let mut encoding = 0u32;
        let mut content_type = 0u32;
        let mut format_type = 0u32;
        let mut store: HCERTSTORE = null_mut();
        let mut message: *mut core::ffi::c_void = null_mut();
        let ok = CryptQueryObject(
            CERT_QUERY_OBJECT_FILE,
            path.as_ptr().cast(),
            CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
            CERT_QUERY_FORMAT_FLAG_BINARY,
            0,
            &mut encoding,
            &mut content_type,
            &mut format_type,
            &mut store,
            &mut message,
            null_mut(),
        );
        if ok == 0 {
            let error = err();
            if !message.is_null() {
                CryptMsgClose(message);
            }
            if !store.is_null() {
                CertCloseStore(store, 0);
            }
            return Err(format!("Cannot read Authenticode signer: {error}"));
        }

        let result = (|| {
            let mut size = 0u32;
            if CryptMsgGetParam(
                message,
                CMSG_SIGNER_CERT_INFO_PARAM,
                0,
                null_mut(),
                &mut size,
            ) == 0
            {
                return Err(format!("Cannot size Authenticode signer: {}", err()));
            }
            let words = (size as usize).div_ceil(size_of::<usize>());
            let mut buffer = vec![0usize; words];
            if CryptMsgGetParam(
                message,
                CMSG_SIGNER_CERT_INFO_PARAM,
                0,
                buffer.as_mut_ptr().cast(),
                &mut size,
            ) == 0
            {
                return Err(format!("Cannot read Authenticode signer: {}", err()));
            }
            let info = &*(buffer.as_ptr() as *const CERT_INFO);
            let certificate = CertGetSubjectCertificateFromStore(store, encoding, info);
            if certificate.is_null() {
                return Err(format!("Cannot find Authenticode signer certificate: {}", err()));
            }
            let required = CertGetNameStringW(
                certificate,
                CERT_NAME_SIMPLE_DISPLAY_TYPE,
                0,
                null(),
                null_mut(),
                0,
            );
            if required == 0 {
                CertFreeCertificateContext(certificate);
                return Err(format!("Cannot read signer name: {}", err()));
            }
            let mut name = vec![0u16; required as usize + 1];
            let written = CertGetNameStringW(
                certificate,
                CERT_NAME_SIMPLE_DISPLAY_TYPE,
                0,
                null(),
                name.as_mut_ptr(),
                name.len() as u32,
            );
            CertFreeCertificateContext(certificate);
            if written == 0 {
                return Err(format!("Cannot read signer name: {}", err()));
            }
            name.truncate(written as usize);
            Ok(String::from_utf16_lossy(&name)
                .trim_end_matches('\0')
                .trim()
                .to_string())
        })();
        CryptMsgClose(message);
        CertCloseStore(store, 0);
        result
    }
}

fn verify_authenticode(path: &Path) -> Result<Option<String>, String> {
    const TRUST_E_NOSIGNATURE: u32 = 0x800b0100;
    unsafe {
        let file_path = path;
        let path = w(&path.to_string_lossy());
        let mut file: WINTRUST_FILE_INFO = zeroed();
        file.cbStruct = size_of::<WINTRUST_FILE_INFO>() as u32;
        file.pcwszFilePath = path.as_ptr();
        let mut data: WINTRUST_DATA = zeroed();
        data.cbStruct = size_of::<WINTRUST_DATA>() as u32;
        data.dwUIChoice = WTD_UI_NONE;
        data.fdwRevocationChecks = WTD_REVOKE_NONE;
        data.dwUnionChoice = WTD_CHOICE_FILE;
        data.Anonymous = WINTRUST_DATA_0 { pFile: &mut file };
        data.dwStateAction = WTD_STATEACTION_VERIFY;
        data.dwProvFlags = WTD_SAFER_FLAG | WTD_CACHE_ONLY_URL_RETRIEVAL;
        let mut action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
        let status = WinVerifyTrust(0, &mut action, (&mut data) as *mut _ as _) as u32;
        data.dwStateAction = WTD_STATEACTION_CLOSE;
        WinVerifyTrust(0, &mut action, (&mut data) as *mut _ as _);
        if status == TRUST_E_NOSIGNATURE {
            return Ok(None);
        }
        if status != 0 {
            return Err(format!("Authenticode verification failed: 0x{status:08x}"));
        }
        signer_subject(file_path).map(Some)
    }
}

fn run_version_command(exe: &Path) -> Result<String, String> {
    let output = temporary_path(&env::temp_dir(), "deskpilot-version");
    let running = match launch_with_output(exe, "--version", "", false, Some(&output)) {
        Ok(running) => running,
        Err(error) => {
            let _ = fs::remove_file(&output);
            return Err(error);
        }
    };
    let exited = unsafe { WaitForSingleObject(running.process, 5000) } == WAIT_OBJECT_0;
    if !exited {
        drop(running);
        let _ = fs::remove_file(&output);
        return Err("Runtime version check timed out".into());
    }
    let mut code = 1;
    let code_ok = unsafe { GetExitCodeProcess(running.process, &mut code) } != 0;
    drop(running);
    if !code_ok || code != 0 {
        let _ = fs::remove_file(&output);
        return Err(format!("Runtime version check exited with code {code}"));
    }
    let size = match fs::metadata(&output) {
        Ok(metadata) => metadata.len(),
        Err(error) => {
            let _ = fs::remove_file(&output);
            return Err(error.to_string());
        }
    };
    if size > 4096 {
        let _ = fs::remove_file(&output);
        return Err("Runtime version check returned too much output".into());
    }
    let bytes = fs::read(&output).map_err(|e| e.to_string());
    let _ = fs::remove_file(&output);
    String::from_utf8(bytes?).map_err(|e| format!("Runtime version is not UTF-8: {e}"))
}

fn runtime_version_matches(kind: RuntimeKind, expected: &str, actual: &str) -> bool {
    if kind == RuntimeKind::TunnelClient && !expected.contains('+') {
        expected == actual.split('+').next().unwrap_or(actual)
    } else {
        expected == actual
    }
}

fn validate_runtime(root: &Path, kind: RuntimeKind) -> Result<ValidatedRuntime, String> {
    let path = runtime_path(root, kind)?;
    let policy = runtime_policy(root)?;
    let signer_subject = verify_authenticode(&path)?;
    if let Some(subject) = &signer_subject {
        if !signer_allowed(kind, subject) {
            return Err(format!(
                "{} has an unexpected Authenticode signer: {subject}",
                path.display()
            ));
        }
    }
    match kind {
        RuntimeKind::Node if signer_subject.is_none() => {
            return Err("Node.js runtime is not Authenticode-signed".into())
        }
        RuntimeKind::TunnelClient => {
            if let Some(expected) = &policy.tunnel_signer_subject {
                if signer_subject
                    .as_deref()
                    .is_none_or(|actual| normalized_subject(actual) != normalized_subject(expected))
                {
                    return Err("tunnel-client signer does not match the runtime manifest".into());
                }
            }
        }
        RuntimeKind::Node => {
            if let Some(expected) = &policy.node_signer_subject {
                if signer_subject
                    .as_deref()
                    .is_none_or(|actual| normalized_subject(actual) != normalized_subject(expected))
                {
                    return Err("Node.js signer does not match the runtime manifest".into());
                }
            }
        }
    }
    let output = run_version_command(&path)?;
    let version = match kind {
        RuntimeKind::Node => parse_node_version(&output),
        RuntimeKind::TunnelClient => parse_tunnel_version(&output),
    }
    .ok_or_else(|| format!("{} returned an unsupported version: {output:?}", path.display()))?;
    let (expected_version, expected_hash) = match kind {
        RuntimeKind::Node => (&policy.node_version, &policy.node_sha256),
        RuntimeKind::TunnelClient => (&policy.tunnel_version, &policy.tunnel_sha256),
    };
    if let Some(expected) = expected_version {
        if !runtime_version_matches(kind, expected, &version) {
            return Err(format!(
                "{} version {version} does not match the pinned version {expected}",
                path.display()
            ));
        }
    }
    if let Some(expected) = expected_hash {
        let actual = sha256_file(&path)?;
        if !actual.eq_ignore_ascii_case(expected) {
            return Err(format!("{} SHA-256 does not match the runtime manifest", path.display()));
        }
    }
    Ok(ValidatedRuntime { path, version })
}

fn profile_file() -> PathBuf {
    dir().join("tunnel-client.yaml")
}

fn keyfile() -> PathBuf {
    dir().join("runtime-key.dpapi")
}

fn logfile() -> PathBuf {
    dir().join("activity.log")
}

fn policy() -> PathBuf {
    dir().join("permissions.txt")
}

fn temporary_path(directory: &Path, label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    directory.join(format!(
        ".{label}-{}-{nonce}-{}.tmp",
        std::process::id(),
        TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
    ))
}

fn atomic_write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "missing parent"))?;
    fs::create_dir_all(parent)?;
    let temporary = temporary_path(parent, "deskpilot-write");
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn save_policy(mask: u8) -> std::io::Result<()> {
    atomic_write(&policy(), mask.to_string().as_bytes())
}

fn startup_pref() -> PathBuf {
    dir().join("launch-on-sign-in.txt")
}

fn startup_enabled() -> bool {
    fs::read_to_string(startup_pref())
        .map(|s| s.trim() == "1")
        .unwrap_or(false)
}

fn read_run_value() -> Result<Option<Vec<u16>>, String> {
    unsafe {
        let sub = w("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
        let name = w(RUN_VALUE_NAME);
        let mut key: HKEY = 0;
        let rc = RegOpenKeyExW(
            HKEY_CURRENT_USER,
            sub.as_ptr(),
            0,
            KEY_QUERY_VALUE,
            &mut key,
        );
        if rc == ERROR_FILE_NOT_FOUND {
            return Ok(None);
        }
        if rc != 0 {
            return Err(format!("Registry open failed: {rc}"));
        }
        let mut kind = 0u32;
        let mut size = 0u32;
        let rc = RegQueryValueExW(key, name.as_ptr(), null(), &mut kind, null_mut(), &mut size);
        if rc == ERROR_FILE_NOT_FOUND {
            RegCloseKey(key);
            return Ok(None);
        }
        if rc != 0 {
            RegCloseKey(key);
            return Err(format!("Registry query failed: {rc}"));
        }
        // This launcher owns the value name. Read any even-sized legacy value
        // so opt-out reconciliation can remove it instead of leaving autostart on.
        if !size.is_multiple_of(2) {
            RegCloseKey(key);
            return Err(format!("Run value {RUN_VALUE_NAME} has an invalid registry size"));
        }
        let mut bytes = vec![0u8; size as usize];
        let rc = RegQueryValueExW(
            key,
            name.as_ptr(),
            null(),
            &mut kind,
            bytes.as_mut_ptr(),
            &mut size,
        );
        RegCloseKey(key);
        if rc != 0 {
            return Err(format!("Registry read failed: {rc}"));
        }
        bytes.truncate(size as usize);
        let (chunks, _) = bytes.as_chunks::<2>();
        let mut words: Vec<u16> = chunks
            .iter()
            .map(|pair| u16::from_le_bytes(*pair))
            .collect();
        if let Some(0) = words.last() {
            words.pop();
        }
        Ok(Some(words))
    }
}

fn write_run_value(value: Option<&[u16]>) -> Result<(), String> {
    unsafe {
        let sub = w("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
        let name = w(RUN_VALUE_NAME);
        let mut key: HKEY = 0;
        if let Some(value) = value {
            let mut disposition = 0u32;
            let rc = RegCreateKeyExW(
                HKEY_CURRENT_USER,
                sub.as_ptr(),
                0,
                null(),
                REG_OPTION_NON_VOLATILE,
                KEY_SET_VALUE,
                null(),
                &mut key,
                &mut disposition,
            );
            if rc != 0 {
                return Err(format!("Registry create failed: {rc}"));
            }
            let mut terminated = value.to_vec();
            terminated.push(0);
            let rc = RegSetValueExW(
                key,
                name.as_ptr(),
                0,
                REG_SZ,
                terminated.as_ptr() as *const u8,
                (terminated.len() * 2) as u32,
            );
            RegCloseKey(key);
            if rc != 0 {
                return Err(format!("Registry write failed: {rc}"));
            }
        } else {
            let rc = RegOpenKeyExW(
                HKEY_CURRENT_USER,
                sub.as_ptr(),
                0,
                KEY_SET_VALUE,
                &mut key,
            );
            if rc == ERROR_FILE_NOT_FOUND {
                return Ok(());
            }
            if rc != 0 {
                return Err(format!("Registry open failed: {rc}"));
            }
            let rc = RegDeleteValueW(key, name.as_ptr());
            RegCloseKey(key);
            if rc != 0 && rc != ERROR_FILE_NOT_FOUND {
                return Err(format!("Registry delete failed: {rc}"));
            }
        }
        Ok(())
    }
}

trait StartupStore {
    fn read_run(&mut self) -> Result<Option<Vec<u16>>, String>;
    fn write_run(&mut self, value: Option<&[u16]>) -> Result<(), String>;
    fn read_preference(&mut self) -> Result<Option<Vec<u8>>, String>;
    fn write_preference(&mut self, value: Option<&[u8]>) -> Result<(), String>;
}

struct SystemStartupStore {
    preference: PathBuf,
}

impl StartupStore for SystemStartupStore {
    fn read_run(&mut self) -> Result<Option<Vec<u16>>, String> {
        read_run_value()
    }

    fn write_run(&mut self, value: Option<&[u16]>) -> Result<(), String> {
        write_run_value(value)
    }

    fn read_preference(&mut self) -> Result<Option<Vec<u8>>, String> {
        match fs::read(&self.preference) {
            Ok(value) => Ok(Some(value)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.to_string()),
        }
    }

    fn write_preference(&mut self, value: Option<&[u8]>) -> Result<(), String> {
        match value {
            Some(value) => atomic_write(&self.preference, value).map_err(|e| e.to_string()),
            None => match fs::remove_file(&self.preference) {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(error.to_string()),
            },
        }
    }
}

fn reconcile_startup<S: StartupStore>(
    store: &mut S,
    exe: &Path,
    enabled: bool,
    persist_preference: bool,
) -> Result<(), String> {
    let previous_run = store.read_run()?;
    let previous_preference = store.read_preference()?;
    let command = w(&format!("\"{}\" --background", exe.display()));
    let desired_run = enabled.then_some(command);
    let desired_preference = if persist_preference {
        Some(if enabled { b"1".to_vec() } else { b"0".to_vec() })
    } else {
        previous_preference.clone()
    };
    let mut run_attempted = false;
    let mut preference_attempted = false;

    let mut apply = || -> Result<(), String> {
        if previous_run != desired_run {
            run_attempted = true;
            store.write_run(desired_run.as_deref())?;
        }
        if previous_preference != desired_preference {
            preference_attempted = true;
            store.write_preference(desired_preference.as_deref())?;
        }
        if store.read_run()? != desired_run {
            return Err("Run value verification failed".into());
        }
        if store.read_preference()? != desired_preference {
            return Err("Startup preference verification failed".into());
        }
        Ok(())
    };

    if let Err(error) = apply() {
        let mut rollback_errors = Vec::new();
        if run_attempted {
            if let Err(error) = store.write_run(previous_run.as_deref()) {
                rollback_errors.push(format!("Run value: {error}"));
            }
        }
        if preference_attempted {
            if let Err(error) = store.write_preference(previous_preference.as_deref()) {
                rollback_errors.push(format!("preference: {error}"));
            }
        }
        if rollback_errors.is_empty() {
            return Err(error);
        }
        return Err(format!(
            "{error}; rollback failed: {}",
            rollback_errors.join("; ")
        ));
    }
    Ok(())
}

fn startup_init_with<S: StartupStore>(store: &mut S, exe: &Path) -> Result<(), String> {
    match store.read_preference()? {
        None => reconcile_startup(store, exe, false, false),
        Some(value) if value == b"1" => reconcile_startup(store, exe, true, true),
        Some(value) if value == b"0" => reconcile_startup(store, exe, false, true),
        Some(_) => match reconcile_startup(store, exe, false, true) {
            Ok(()) => Err("Invalid startup preference; repaired to disabled".into()),
            Err(error) => Err(format!("{error}; invalid preference repaired to disabled")),
        },
    }
}

fn startup_apply(enabled: bool) -> Result<(), String> {
    let exe = env::current_exe().map_err(|e| e.to_string())?;
    let mut store = SystemStartupStore {
        preference: startup_pref(),
    };
    reconcile_startup(&mut store, &exe, enabled, true)
}

fn startup_init() -> Result<(), String> {
    let exe = env::current_exe().map_err(|e| e.to_string())?;
    let mut store = SystemStartupStore {
        preference: startup_pref(),
    };
    startup_init_with(&mut store, &exe)
}

fn crypt(input: &[u8], protect: bool) -> Result<Vec<u8>, String> {
    unsafe {
        let src = CRYPT_INTEGER_BLOB {
            cbData: input.len() as u32,
            pbData: input.as_ptr() as *mut u8,
        };
        let mut dst: CRYPT_INTEGER_BLOB = zeroed();
        let ok = if protect {
            CryptProtectData(
                &src,
                null(),
                null(),
                null(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut dst,
            )
        } else {
            CryptUnprotectData(
                &src,
                null_mut(),
                null(),
                null(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut dst,
            )
        };

        if ok == 0 {
            return Err(err());
        }

        let value = std::slice::from_raw_parts(dst.pbData, dst.cbData as usize).to_vec();
        std::ptr::write_bytes(dst.pbData, 0, dst.cbData as usize);
        LocalFree(dst.pbData as _);
        Ok(value)
    }
}

struct Running {
    job: HANDLE,
    process: HANDLE,
    pid: u32,
    creation_time: FILETIME,
}

impl Running {
    fn is_current(&self) -> bool {
        unsafe {
            if WaitForSingleObject(self.process, 0) == WAIT_OBJECT_0 {
                return false;
            }
            let mut creation: FILETIME = zeroed();
            let mut exit: FILETIME = zeroed();
            let mut kernel: FILETIME = zeroed();
            let mut user: FILETIME = zeroed();
            GetProcessTimes(
                self.process,
                &mut creation,
                &mut exit,
                &mut kernel,
                &mut user,
            ) != 0
                && creation.dwLowDateTime == self.creation_time.dwLowDateTime
                && creation.dwHighDateTime == self.creation_time.dwHighDateTime
        }
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        unsafe {
            // Closing the last Job Object handle is the termination mechanism.
            // Do not replace this with a parent-only TerminateProcess call.
            CloseHandle(self.job);
            WaitForSingleObject(self.process, 2000);
            CloseHandle(self.process);
        }
    }
}

fn listener_owners(port: u16) -> Result<Vec<ListenerOwner>, String> {
    unsafe {
        let mut rows = Vec::new();
        for family in [2u32, 23u32] {
            let mut size = 0u32;
            let rc = GetExtendedTcpTable(
                null_mut(),
                &mut size,
                0,
                family,
                TCP_TABLE_OWNER_PID_LISTENER,
                0,
            );
            if rc != ERROR_INSUFFICIENT_BUFFER {
                if rc != 0 {
                    return Err(format!("TCP listener query failed: {rc}"));
                }
                continue;
            }
            if size < size_of::<u32>() as u32 || size > 16 * 1024 * 1024 {
                return Err("TCP listener table has an invalid size".into());
            }
            let words = (size as usize).div_ceil(size_of::<usize>());
            let mut buffer = vec![0usize; words];
            let rc = GetExtendedTcpTable(
                buffer.as_mut_ptr().cast(),
                &mut size,
                0,
                family,
                TCP_TABLE_OWNER_PID_LISTENER,
                0,
            );
            if rc != 0 {
                return Err(format!("TCP listener query failed: {rc}"));
            }
            if family == 2 {
                let table = &*(buffer.as_ptr() as *const MIB_TCPTABLE_OWNER_PID);
                let count = (table.dwNumEntries as usize)
                    .min((size as usize).saturating_sub(size_of::<u32>()) / size_of::<MIB_TCPROW_OWNER_PID>());
                let first = std::ptr::addr_of!(table.table[0]);
                for row in std::slice::from_raw_parts(first, count) {
                    let row_port = u16::from_be(row.dwLocalPort as u16);
                    if row_port == port {
                        rows.push(ListenerOwner {
                            loopback: row.dwLocalAddr
                                == u32::from_ne_bytes([127, 0, 0, 1]),
                            port: row_port,
                            pid: row.dwOwningPid,
                        });
                    }
                }
            } else {
                let table = &*(buffer.as_ptr() as *const MIB_TCP6TABLE_OWNER_PID);
                let count = (table.dwNumEntries as usize)
                    .min((size as usize).saturating_sub(size_of::<u32>()) / size_of::<MIB_TCP6ROW_OWNER_PID>());
                let first = std::ptr::addr_of!(table.table[0]);
                for row in std::slice::from_raw_parts(first, count) {
                    let row_port = u16::from_be(row.dwLocalPort as u16);
                    if row_port == port {
                        let mut loopback = [0u8; 16];
                        loopback[15] = 1;
                        rows.push(ListenerOwner {
                            loopback: row.ucLocalAddr == loopback && row.dwLocalScopeId == 0,
                            port: row_port,
                            pid: row.dwOwningPid,
                        });
                    }
                }
            }
        }
        Ok(rows)
    }
}

fn port_ownership(supervised: Option<&Running>) -> Result<PortOwnership, String> {
    if supervised.is_some_and(|running| !running.is_current()) {
        return Ok(PortOwnership::Foreign);
    }
    let pid = supervised.map(|running| running.pid);
    let listeners = listener_owners(8080)?;
    Ok(classify_port_ownership(&listeners, 8080, pid))
}

fn port_busy() -> Result<bool, String> {
    Ok(!matches!(port_ownership(None)?, PortOwnership::Free))
}

fn http_get(path: &str) -> Option<Vec<u8>> {
    let timeout = Duration::from_millis(600);
    let mut stream = TcpStream::connect_timeout(&"127.0.0.1:8080".parse().unwrap(), timeout)
        .ok()?;
    stream.set_read_timeout(Some(timeout)).ok()?;
    stream.set_write_timeout(Some(timeout)).ok()?;
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(request.as_bytes()).ok()?;
    let mut response = Vec::new();
    let mut buffer = [0u8; 8192];
    while response.len() < 64 * 1024 {
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => response.extend_from_slice(&buffer[..count]),
            Err(_) => break,
        }
    }
    let header_end = response
        .windows(4)
        .position(|bytes| bytes == b"\r\n\r\n")?;
    let status = std::str::from_utf8(&response[..header_end]).ok()?.lines().next()?;
    let success = status.starts_with("HTTP/1.1 200 ") || status.starts_with("HTTP/1.0 200 ");
    success.then(|| response[header_end + 4..].to_vec())
}

fn http_ok_for(running: &Running, path: &str, needle: &str) -> bool {
    if !matches!(port_ownership(Some(running)), Ok(PortOwnership::Supervised)) {
        return false;
    }
    let Some(body) = http_get(path) else {
        return false;
    };
    matches!(port_ownership(Some(running)), Ok(PortOwnership::Supervised))
        && String::from_utf8_lossy(&body).contains(needle)
}

fn dashboard_ready_for(running: &Running) -> bool {
    if !http_ok_for(running, "/readyz", "") {
        return false;
    }
    let Some(status) = http_get("/api/status") else {
        return false;
    };
    let instance = serde_json::from_slice::<serde_json::Value>(&status)
        .ok()
        .and_then(|value| value.get("client_instance_id")?.as_str().map(str::to_string))
        .filter(|value| !value.is_empty());
    if !matches!(port_ownership(Some(running)), Ok(PortOwnership::Supervised)) {
        return false;
    }
    instance.is_some() && http_ok_for(running, "/ui", "admin-ui-root")
}

fn open_dashboard(running: &Running) -> Result<(), DashboardOpen> {
    if !dashboard_ready_for(running) {
        return Err(DashboardOpen::NotReady);
    }
    let result = unsafe {
        ShellExecuteW(
            0,
            w("open").as_ptr(),
            w(DASH).as_ptr(),
            null(),
            null(),
            SW_SHOWNORMAL,
        )
    };
    match classify_dashboard_open(true, result) {
        DashboardOpen::Opened => Ok(()),
        error => Err(error),
    }
}

fn set_app_id() {
    unsafe {
        let id = w(APPID);
        let _ = SetCurrentProcessExplicitAppUserModelID(id.as_ptr());
    }
}

fn launch_with_output(
    exe: &Path,
    args: &str,
    key: &str,
    managed: bool,
    output: Option<&Path>,
) -> Result<Running, String> {
    unsafe {
        let job = CreateJobObjectW(null(), null());
        if job == 0 {
            return Err(err());
        }

        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = zeroed();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            &limits as *const _ as _,
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        ) == 0
        {
            let error = err();
            CloseHandle(job);
            return Err(error);
        }

        let blocked = [
            "CONTROL_PLANE_API_KEY",
            "OPENAI_API_KEY",
            "OPENAI_ADMIN_KEY",
            "CONTROL_PLANE_TUNNEL_ID",
            "DC_MANAGED_POLICY",
            "TUNNEL_CLIENT_PROFILE",
            "TUNNEL_CLIENT_PROFILE_FILE",
        ];
        let mut variables: Vec<(String, Vec<u16>)> = env::vars_os()
            .filter_map(|(key, value)| {
                let name = key.to_string_lossy().to_string();
                if blocked.iter().any(|item| name.eq_ignore_ascii_case(item)) {
                    return None;
                }
                let mut entry: Vec<u16> = key.encode_wide().collect();
                entry.push(61);
                entry.extend(value.encode_wide());
                entry.push(0);
                Some((name, entry))
            })
            .collect();
        if !key.is_empty() {
            variables.push((
                "CONTROL_PLANE_API_KEY".into(),
                w(&format!("CONTROL_PLANE_API_KEY={key}")),
            ));
        }
        if managed {
            variables.push((
                "DC_MANAGED_POLICY".into(),
                w(&format!("DC_MANAGED_POLICY={}", policy().display())),
            ));
        }
        variables.sort_by_key(|entry| entry.0.to_uppercase());
        let mut environment: Vec<u16> = variables.into_iter().flat_map(|entry| entry.1).collect();
        environment.push(0);

        let output_file = match output {
            Some(path) => match fs::OpenOptions::new().write(true).create_new(true).open(path) {
                Ok(file) => Some(file),
                Err(error) => {
                    environment.fill(0);
                    CloseHandle(job);
                    return Err(error.to_string());
                }
            },
            None => None,
        };
        let mut startup: STARTUPINFOW = zeroed();
        startup.cb = size_of::<STARTUPINFOW>() as u32;
        if let Some(file) = output_file.as_ref() {
            let handle = file.as_raw_handle() as HANDLE;
            if SetHandleInformation(handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) == 0 {
                let error = err();
                drop(output_file);
                environment.fill(0);
                CloseHandle(job);
                return Err(error);
            }
            startup.dwFlags |= STARTF_USESTDHANDLES;
            startup.hStdInput = 0;
            startup.hStdOutput = handle;
            startup.hStdError = handle;
        }
        let exe_wide = w(&exe.to_string_lossy());
        let mut command_line = w(&format!("\"{}\" {args}", exe.display()));
        let current_directory = w(&app_root().to_string_lossy());
        let mut process: PROCESS_INFORMATION = zeroed();
        let inherit = if output_file.is_some() { 1 } else { 0 };
        let ok = CreateProcessW(
            exe_wide.as_ptr(),
            command_line.as_mut_ptr(),
            null(),
            null(),
            inherit,
            CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
            environment.as_ptr() as _,
            current_directory.as_ptr(),
            &startup,
            &mut process,
        );
        environment.fill(0);
        drop(output_file);

        if ok == 0 {
            let error = err();
            CloseHandle(job);
            return Err(error);
        }
        let mut creation: FILETIME = zeroed();
        let mut exit: FILETIME = zeroed();
        let mut kernel: FILETIME = zeroed();
        let mut user: FILETIME = zeroed();
        if GetProcessTimes(
            process.hProcess,
            &mut creation,
            &mut exit,
            &mut kernel,
            &mut user,
        ) == 0
        {
            let error = err();
            TerminateProcess(process.hProcess, 1);
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            CloseHandle(job);
            return Err(error);
        }
        if AssignProcessToJobObject(job, process.hProcess) == 0 {
            let error = err();
            TerminateProcess(process.hProcess, 1);
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            CloseHandle(job);
            return Err(format!("Cannot contain process: {error}"));
        }
        if ResumeThread(process.hThread) == u32::MAX {
            let error = err();
            TerminateProcess(process.hProcess, 1);
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            CloseHandle(job);
            return Err(error);
        }
        CloseHandle(process.hThread);
        Ok(Running {
            job,
            process: process.hProcess,
            pid: process.dwProcessId,
            creation_time: creation,
        })
    }
}

fn launch(exe: &str, args: &str, key: &str, managed: bool) -> Result<Running, String> {
    launch_with_output(Path::new(exe), args, key, managed, None)
}

struct ProcessHandle(HANDLE, u32);

impl Drop for ProcessHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

fn open_process_handle(pid: u32) -> Result<ProcessHandle, String> {
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE, 0, pid);
        if handle == 0 {
            return Err(format!("Cannot open test process {pid}: {}", err()));
        }
        Ok(ProcessHandle(handle, pid))
    }
}

fn process_relations() -> Result<Vec<(u32, u32, String)>, String> {
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return Err(err());
        }
        let mut entry: PROCESSENTRY32W = zeroed();
        entry.dwSize = size_of::<PROCESSENTRY32W>() as u32;
        let mut relations = Vec::new();
        let mut ok = Process32FirstW(snapshot, &mut entry);
        while ok != 0 {
            let name = String::from_utf16_lossy(&entry.szExeFile)
                .trim_end_matches('\0')
                .to_string();
            relations.push((entry.th32ProcessID, entry.th32ParentProcessID, name));
            entry.dwSize = size_of::<PROCESSENTRY32W>() as u32;
            ok = Process32NextW(snapshot, &mut entry);
        }
        let error_code = GetLastError();
        CloseHandle(snapshot);
        if ok == 0 && error_code != ERROR_NO_MORE_FILES {
            return Err(format!("Process snapshot failed: {error_code}"));
        }
        Ok(relations)
    }
}

fn wait_for_process_ids(path: &Path) -> Result<(u32, u32), String> {
    for _ in 0..200 {
        if let Ok(text) = fs::read_to_string(path) {
            let mut lines = text.lines();
            let parent = lines
                .next()
                .and_then(|value| value.parse::<u32>().ok())
                .filter(|pid| *pid != 0);
            let child = lines
                .next()
                .and_then(|value| value.parse::<u32>().ok())
                .filter(|pid| *pid != 0);
            if let (Some(parent), Some(child)) = (parent, child) {
                return Ok((parent, child));
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(format!("Timed out waiting for {}", path.display()))
}

fn powershell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn job_tree_proof() -> Result<(Vec<u32>, Vec<u32>, bool), String> {
    let scratch = temporary_path(&env::temp_dir(), "deskpilot-job-tree");
    fs::create_dir_all(&scratch).map_err(|e| e.to_string())?;
    let result = (|| {
        let windows = env::var_os("SystemRoot")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
        let powershell = windows.join("System32").join("WindowsPowerShell").join("v1.0").join("powershell.exe");
        let ping = windows.join("System32").join("PING.EXE");
        if !powershell.is_file() || !ping.is_file() {
            return Err("Windows PowerShell or ping is missing".into());
        }
        let parent_script = scratch.join("parent.ps1");
        let child_script = scratch.join("child.ps1");
        let parent_marker = scratch.join("parent.txt");
        let child_marker = scratch.join("child.txt");
        let parent_text = format!(
            "$ErrorActionPreference = 'Stop'\n$child = Start-Process -FilePath {powershell} -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',{child_script}) -PassThru -WindowStyle Hidden\n[IO.File]::WriteAllText({parent_marker}, \"$PID`n$($child.Id)\")\nwhile ($true) {{ Start-Sleep -Seconds 1 }}\n",
            powershell = powershell_quote(&powershell.to_string_lossy()),
            child_script = powershell_quote(&child_script.to_string_lossy()),
            parent_marker = powershell_quote(&parent_marker.to_string_lossy()),
        );
        let child_text = format!(
            "$ErrorActionPreference = 'Stop'\n$grandchild = Start-Process -FilePath {ping} -ArgumentList @('-n','600','127.0.0.1') -PassThru -WindowStyle Hidden\n[IO.File]::WriteAllText({child_marker}, \"$PID`n$($grandchild.Id)\")\nwhile ($true) {{ Start-Sleep -Seconds 1 }}\n",
            ping = powershell_quote(&ping.to_string_lossy()),
            child_marker = powershell_quote(&child_marker.to_string_lossy()),
        );
        fs::write(&parent_script, parent_text).map_err(|e| e.to_string())?;
        fs::write(&child_script, child_text).map_err(|e| e.to_string())?;
        let args = format!(
            "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{}\"",
            parent_script.display()
        );
        let running = launch_with_output(
            &powershell,
            &args,
            "",
            false,
            None,
        )?;
        let (parent_pid, child_pid) = wait_for_process_ids(&parent_marker)?;
        let (actual_child_pid, grandchild_pid) = wait_for_process_ids(&child_marker)?;
        if parent_pid != running.pid || child_pid != actual_child_pid {
            return Err("Self-test process tree markers do not match the supervised child".into());
        }
        let relations = process_relations()?;
        let parent_of = |pid| {
            relations
                .iter()
                .find(|(candidate, _, _)| *candidate == pid)
                .map(|(_, parent, _)| *parent)
        };
        if parent_of(child_pid) != Some(parent_pid) || parent_of(grandchild_pid) != Some(child_pid) {
            return Err("Self-test processes are not the expected descendant tree".into());
        }
        let pids = vec![parent_pid, child_pid, grandchild_pid];
        let handles: Result<Vec<_>, _> = pids.iter().copied().map(open_process_handle).collect();
        let handles = handles?;
        drop(running);
        let mut surviving = Vec::new();
        for handle in &handles {
            if unsafe { WaitForSingleObject(handle.0, 5000) } != WAIT_OBJECT_0 {
                surviving.push(handle.1);
            }
        }
        if !surviving.is_empty() {
            for handle in &handles {
                unsafe {
                    TerminateProcess(handle.0, 1);
                    WaitForSingleObject(handle.0, 2000);
                }
            }
            return Err(format!(
                "Job Object close left descendant processes alive: {surviving:?}"
            ));
        }
        Ok((pids, surviving))
    })();
    let cleanup = fs::remove_dir_all(&scratch);
    match (result, cleanup) {
        (Ok(proof), Ok(())) => Ok((proof.0, proof.1, true)),
        (Ok(_), Err(error)) => Err(format!("Cannot remove self-test temporary files: {error}")),
        (Err(error), Err(cleanup_error)) => {
            Err(format!("{error}; temporary cleanup failed: {cleanup_error}"))
        }
        (Err(error), Ok(())) => Err(error),
    }
}

fn fresh_run_id() -> String {
    format!(
        "{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    )
}

fn self_test(run_id: &str) -> Result<serde_json::Value, String> {
    let secret = b"dummy-test-only";
    let blob = crypt(secret, true)?;
    if blob == secret || crypt(&blob, false)? != secret {
        return Err("DPAPI test failed".into());
    }
    if parse_node_version("v24.0.0").as_deref() != Some("24.0.0")
        || parse_node_version("v22.0.0").is_some()
        || parse_tunnel_version("tunnel-client 0.0.10").as_deref() != Some("0.0.10")
        || !signer_allowed(RuntimeKind::Node, "OpenJS Foundation")
        || signer_allowed(RuntimeKind::Node, "OpenJS Foundation Evil")
        || !matches!(
            classify_port_ownership(
                &[ListenerOwner {
                    loopback: true,
                    port: 8080,
                    pid: 7,
                }],
                8080,
                Some(7)
            ),
            PortOwnership::Supervised
        )
        || !matches!(
            classify_port_ownership(
                &[ListenerOwner {
                    loopback: true,
                    port: 8080,
                    pid: 8,
                }],
                8080,
                Some(7)
            ),
            PortOwnership::Foreign
        )
        || close_window_action(false, false) != WindowCloseAction::KeepVisible
        || classify_dashboard_open(true, 2) != DashboardOpen::BrowserFailed(2)
    {
        return Err("Launcher hardening contract check failed".into());
    }
    let (process_tree_pids, surviving_descendant_pids, temp_artifacts_removed) = job_tree_proof()?;
    Ok(serde_json::json!({
        "runId": run_id,
        "success": true,
        "descendantTreeKilled": true,
        "jobObjectClosed": true,
        "processTreePids": process_tree_pids,
        "survivingDescendantPids": surviving_descendant_pids,
        "tempArtifactsRemoved": temp_artifacts_removed,
        "completedAt": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs(),
    }))
}

fn write_self_test_results(
    data: &Path,
    run_id: &str,
    result: &Result<serde_json::Value, String>,
) -> Result<(), String> {
    let (output, evidence) = match result {
        Ok(evidence) => ("DPAPI_AND_JOB_PASS".to_string(), evidence.clone()),
        Err(error) => (
            format!("FAIL {error}"),
            serde_json::json!({
                "runId": run_id,
                "success": false,
                "descendantTreeKilled": false,
                "jobObjectClosed": false,
                "processTreePids": [],
                "survivingDescendantPids": [],
                "tempArtifactsRemoved": false,
                "error": error,
                "completedAt": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs(),
            }),
        ),
    };
    atomic_write(&data.join(SELF_TEST_OUTPUT), output.as_bytes()).map_err(|e| e.to_string())?;
    let evidence = serde_json::to_vec(&evidence).map_err(|e| e.to_string())?;
    atomic_write(&data.join(SELF_TEST_EVIDENCE), &evidence).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::time::{SystemTime, UNIX_EPOCH};

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(label: &str) -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = env::temp_dir().join(format!(
                "deskpilot-unit-{label}-{}-{nonce}",
                std::process::id()
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[derive(Default)]
    struct FakeStartupStore {
        run: Option<Vec<u16>>,
        preference: Option<Vec<u8>>,
        fail_next_run_write: bool,
        fail_next_preference_write: bool,
        fail_run_value: Option<Option<Vec<u16>>>,
        fail_preference_value: Option<Option<Vec<u8>>>,
    }

    impl StartupStore for FakeStartupStore {
        fn read_run(&mut self) -> Result<Option<Vec<u16>>, String> {
            Ok(self.run.clone())
        }

        fn write_run(&mut self, value: Option<&[u16]>) -> Result<(), String> {
            if self.fail_next_run_write
                || self
                    .fail_run_value
                    .as_ref()
                    .is_some_and(|failed| failed.as_deref() == value)
            {
                self.fail_next_run_write = false;
                return Err("run write failed".into());
            }
            self.run = value.map(<[u16]>::to_vec);
            Ok(())
        }

        fn read_preference(&mut self) -> Result<Option<Vec<u8>>, String> {
            Ok(self.preference.clone())
        }

        fn write_preference(&mut self, value: Option<&[u8]>) -> Result<(), String> {
            if self.fail_next_preference_write
                || self
                    .fail_preference_value
                    .as_ref()
                    .is_some_and(|failed| failed.as_deref() == value)
            {
                self.fail_next_preference_write = false;
                return Err("preference write failed".into());
            }
            self.preference = value.map(<[u8]>::to_vec);
            Ok(())
        }
    }

    #[test]
    fn port_ownership_requires_the_supervised_loopback_listener() {
        let child = ListenerOwner {
            loopback: true,
            port: 8080,
            pid: 42,
        };
        assert_eq!(
            classify_port_ownership(&[child], 8080, Some(42)),
            PortOwnership::Supervised
        );
        assert_eq!(
            classify_port_ownership(&[child], 8080, Some(43)),
            PortOwnership::Foreign
        );
        assert_eq!(
            classify_port_ownership(&[child], 8080, None),
            PortOwnership::Foreign
        );
        assert_eq!(
            classify_port_ownership(
                &[
                    child,
                    ListenerOwner {
                        loopback: true,
                        port: 8080,
                        pid: 43,
                    },
                ],
                8080,
                Some(42)
            ),
            PortOwnership::Foreign
        );
        assert_eq!(
            classify_port_ownership(
                &[ListenerOwner {
                    loopback: false,
                    port: 8080,
                    pid: 42,
                }],
                8080,
                Some(42)
            ),
            PortOwnership::Foreign
        );
        assert_eq!(classify_port_ownership(&[], 8080, Some(42)), PortOwnership::Free);
    }

    #[test]
    fn browser_open_failure_is_not_reported_as_success() {
        assert_eq!(classify_dashboard_open(false, 33), DashboardOpen::NotReady);
        assert_eq!(classify_dashboard_open(true, 33), DashboardOpen::Opened);
        assert_eq!(
            classify_dashboard_open(true, 2),
            DashboardOpen::BrowserFailed(2)
        );
    }

    #[test]
    fn close_without_a_tray_icon_keeps_the_recovery_window_visible() {
        assert_eq!(close_window_action(true, false), WindowCloseAction::Exit);
        assert_eq!(close_window_action(false, true), WindowCloseAction::Hide);
        assert_eq!(close_window_action(false, false), WindowCloseAction::KeepVisible);
    }

    #[test]
    fn runtime_resolution_never_uses_path() {
        let _guard = ENV_LOCK.lock().unwrap();
        let scratch = Scratch::new("path");
        let evil = scratch.0.join("evil");
        fs::create_dir_all(&evil).unwrap();
        fs::write(evil.join("node.exe"), b"not node").unwrap();
        fs::write(evil.join("tunnel-client.exe"), b"not tunnel").unwrap();
        env::set_var("PATH", &evil);

        assert!(runtime_path(&scratch.0, RuntimeKind::Node).is_err());
        assert!(runtime_path(&scratch.0, RuntimeKind::TunnelClient).is_err());
    }

    #[test]
    fn runtime_candidate_must_be_the_exact_managed_file() {
        let scratch = Scratch::new("runtime-path");
        let managed = scratch
            .0
            .join("runtime")
            .join("node.exe");
        fs::create_dir_all(managed.parent().unwrap()).unwrap();
        fs::write(&managed, b"managed").unwrap();
        let outside = scratch.0.join("outside.exe");
        fs::write(&outside, b"outside").unwrap();

        assert!(trusted_runtime_candidate(
            &scratch.0,
            RuntimeKind::Node,
            &managed
        ));
        assert!(!trusted_runtime_candidate(
            &scratch.0,
            RuntimeKind::Node,
            &outside
        ));
        assert!(!trusted_runtime_candidate(
            &scratch.0,
            RuntimeKind::TunnelClient,
            &managed
        ));
    }

    #[test]
    fn tunnel_profile_must_use_the_exact_packaged_node_command() {
        let node = Path::new(r"C:\Users\test\AppData\Local\DeskPilot\runtime\node.exe");
        let server = Path::new(r"C:\Program Files\DeskPilot\server");
        let command = serde_json::to_string(&format!(
            "\"{}\" \"{}\"",
            node.display(),
            server.join("managed-launcher.mjs").display()
        ))
        .unwrap();
        let valid = format!("mcp:\n  commands:\n    - channel: main\n      command: {command}\n");
        assert!(profile_uses_trusted_command(&valid, node, server));
        assert!(!profile_uses_trusted_command(
            "mcp:\n  commands:\n    - channel: main\n      command: \"node.exe managed-launcher.mjs\"\n",
            node,
            server
        ));
        assert!(!profile_uses_trusted_command(
            &format!("{valid}      command: \"C:\\evil\\node.exe\"\n"),
            node,
            server
        ));
    }

    #[test]
    fn runtime_manifest_can_tighten_exact_versions_and_hashes() {
        let scratch = Scratch::new("runtime-manifest");
        let hash = "a".repeat(64);
        fs::write(
            scratch.0.join("runtime-manifest.json"),
            serde_json::json!({
                "node": {"version": "24.22.3", "sha256": hash, "signerSubject": "OpenJS Foundation"},
                "tunnelClient": {"version": "0.0.10", "sha256": hash, "signerSubject": "OpenAI, L.L.C."}
            })
            .to_string(),
        )
        .unwrap();
        let policy = runtime_policy(&scratch.0).unwrap();
        assert_eq!(policy.node_version.as_deref(), Some("24.22.3"));
        assert_eq!(policy.node_sha256.as_deref(), Some(hash.as_str()));
        assert_eq!(
            policy.node_signer_subject.as_deref(),
            Some("OpenJS Foundation")
        );
        assert_eq!(policy.tunnel_version.as_deref(), Some("0.0.10"));
        assert_eq!(
            policy.tunnel_signer_subject.as_deref(),
            Some("OpenAI, L.L.C.")
        );
    }

    #[test]
    fn malformed_or_incompatible_runtime_manifest_fails_closed() {
        let scratch = Scratch::new("runtime-manifest-invalid");
        fs::write(
            scratch.0.join("runtime-manifest.json"),
            br#"{"node":{"version":"22.0.0"}}"#,
        )
        .unwrap();
        assert!(runtime_policy(&scratch.0).is_err());
        fs::write(
            scratch.0.join("runtime-manifest.json"),
            br#"{"tunnelClient":{"sha256":"not-a-hash"}}"#,
        )
        .unwrap();
        assert!(runtime_policy(&scratch.0).is_err());
    }

    #[test]
    fn unsigned_node_runtime_is_rejected_before_execution() {
        let scratch = Scratch::new("unsigned-node");
        let runtime = scratch.0.join("runtime");
        fs::create_dir_all(&runtime).unwrap();
        fs::copy(env::current_exe().unwrap(), runtime.join("node.exe")).unwrap();
        let error = validate_runtime(&scratch.0, RuntimeKind::Node).unwrap_err();
        assert!(error.contains("sign") || error.contains("version"));
    }

    #[test]
    fn atomic_write_replaces_existing_files_without_temp_residue() {
        let scratch = Scratch::new("atomic-write");
        let path = scratch.0.join("state.txt");
        atomic_write(&path, b"old").unwrap();
        atomic_write(&path, b"new").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"new");
        assert_eq!(fs::read_dir(&scratch.0).unwrap().count(), 1);
    }

    #[test]
    fn node_version_must_be_an_exact_stable_v24_release() {
        assert_eq!(parse_node_version("v24.22.3\n"), Some("24.22.3".into()));
        assert_eq!(parse_node_version("v24.0.0"), Some("24.0.0".into()));
        assert_eq!(parse_node_version("v22.23.5"), None);
        assert_eq!(parse_node_version("v24.1.0-rc.1"), None);
        assert_eq!(parse_node_version("v24.1.0\nv22.0.0"), None);
        assert_eq!(parse_node_version("24.1.0"), None);
    }

    #[test]
    fn pinned_tunnel_release_matches_its_verified_git_build_metadata() {
        assert!(runtime_version_matches(
            RuntimeKind::TunnelClient,
            "0.0.10",
            "0.0.10+0123456789abcdef"
        ));
        assert!(runtime_version_matches(
            RuntimeKind::TunnelClient,
            "0.0.10+0123456789abcdef",
            "0.0.10+0123456789abcdef"
        ));
        assert!(!runtime_version_matches(
            RuntimeKind::TunnelClient,
            "0.0.10",
            "0.0.11+0123456789abcdef"
        ));
        assert!(!runtime_version_matches(
            RuntimeKind::TunnelClient,
            "0.0.10+0123456789abcdef",
            "0.0.10+fedcba9876543210"
        ));
    }

    #[test]
    fn tunnel_version_must_be_one_stable_semantic_version() {
        for output in [
            "tunnel-client 0.0.10",
            "tunnel-client version v0.0.10",
            "0.0.10",
            "0.0.10+0123456789abcdef (git sha: 0123456789abcdef)",
        ] {
            let expected = if output.contains("+0123456789abcdef") {
                "0.0.10+0123456789abcdef"
            } else {
                "0.0.10"
            };
            assert_eq!(parse_tunnel_version(output), Some(expected.into()));
        }
        assert_eq!(parse_tunnel_version("tunnel-client 0.0.10-rc.1"), None);
        assert_eq!(
            parse_tunnel_version("0.0.10+0123456789abcdef (git sha: fedcba9876543210)"),
            None
        );
        assert_eq!(parse_tunnel_version("tunnel-client 0.0.10\nunexpected"), None);
        assert_eq!(parse_tunnel_version("tunnel-client version unknown"), None);
    }

    #[test]
    fn embedded_authenticode_signature_is_verified_when_a_fixture_is_available() {
        let chrome = PathBuf::from(r"C:\Program Files\Google\Chrome\Application\chrome.exe");
        if !chrome.is_file() {
            return;
        }
        let subject = verify_authenticode(&chrome)
            .unwrap()
            .expect("Chrome fixture must have an embedded Authenticode signature");
        assert_eq!(normalized_subject(&subject), "google llc");
    }

    #[test]
    fn runtime_signer_allowlist_is_exact() {
        assert!(signer_allowed(RuntimeKind::Node, "OpenJS Foundation"));
        assert!(signer_allowed(RuntimeKind::Node, "Node.js Foundation"));
        assert!(!signer_allowed(
            RuntimeKind::Node,
            "OpenJS Foundation Evil"
        ));
        assert!(signer_allowed(RuntimeKind::TunnelClient, "OpenAI, L.L.C."));
        assert!(!signer_allowed(
            RuntimeKind::TunnelClient,
            "OpenAI, L.L.C. Evil"
        ));
    }

    #[test]
    fn first_launch_removes_stale_run_entry_without_creating_a_preference() {
        let mut store = FakeStartupStore {
            run: Some(w("stale --background")),
            ..Default::default()
        };
        startup_init_with(&mut store, Path::new(r"C:\DeskPilot\DeskPilot.exe")).unwrap();
        assert_eq!(store.run, None);
        assert_eq!(store.preference, None);
    }

    #[test]
    fn invalid_startup_preference_is_repaired_to_opt_out() {
        let mut store = FakeStartupStore {
            run: Some(w("stale --background")),
            preference: Some(b"yes".to_vec()),
            ..Default::default()
        };
        let result = startup_init_with(&mut store, Path::new(r"C:\DeskPilot\DeskPilot.exe"));
        assert!(result.is_err());
        assert_eq!(store.run, None);
        assert_eq!(store.preference, Some(b"0".to_vec()));
    }

    #[test]
    fn startup_apply_rolls_back_registry_when_preference_write_fails() {
        let old_run = w("old --background");
        let mut store = FakeStartupStore {
            run: Some(old_run.clone()),
            preference: Some(b"0".to_vec()),
            fail_next_preference_write: true,
            ..Default::default()
        };
        let result = reconcile_startup(
            &mut store,
            Path::new(r"C:\DeskPilot\DeskPilot.exe"),
            true,
            true,
        );
        assert!(result.is_err());
        assert_eq!(store.run, Some(old_run));
        assert_eq!(store.preference, Some(b"0".to_vec()));
    }

    #[test]
    fn startup_apply_reports_a_failed_rollback() {
        let old_run = w("old --background");
        let mut store = FakeStartupStore {
            run: Some(old_run.clone()),
            preference: Some(b"0".to_vec()),
            fail_next_preference_write: true,
            fail_run_value: Some(Some(old_run)),
            ..Default::default()
        };
        let result = reconcile_startup(
            &mut store,
            Path::new(r"C:\DeskPilot\DeskPilot.exe"),
            true,
            true,
        );
        assert!(result.unwrap_err().to_ascii_lowercase().contains("rollback"));
    }

    #[test]
    fn startup_apply_writes_one_quoted_background_run_command() {
        let mut store = FakeStartupStore::default();
        reconcile_startup(
            &mut store,
            Path::new(r"C:\DeskPilot\DeskPilot.exe"),
            true,
            true,
        )
        .unwrap();
        assert_eq!(
            store.run,
            Some(w("\"C:\\DeskPilot\\DeskPilot.exe\" --background"))
        );
        assert_eq!(store.preference, Some(b"1".to_vec()));
    }
}
