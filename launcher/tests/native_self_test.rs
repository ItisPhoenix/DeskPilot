use serde_json::Value;
use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

struct Scratch(PathBuf);

impl Scratch {
    fn new(label: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            env::temp_dir().join(format!("deskpilot-{label}-{}-{nonce}", std::process::id()));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn process_is_alive(pid: u32) -> bool {
    use windows_sys::Win32::{
        Foundation::{CloseHandle, WAIT_TIMEOUT},
        System::Threading::{
            OpenProcess, WaitForSingleObject, PROCESS_QUERY_LIMITED_INFORMATION,
            PROCESS_SYNCHRONIZE,
        },
    };
    unsafe {
        let handle = OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
            0,
            pid,
        );
        if handle == 0 {
            return std::io::Error::last_os_error().raw_os_error() == Some(5);
        }
        let alive = WaitForSingleObject(handle, 0) == WAIT_TIMEOUT;
        CloseHandle(handle);
        alive
    }
}

#[test]
fn native_self_test_uses_modern_fresh_evidence_and_kills_job_tree() {
    let scratch = Scratch::new("native-self-test");
    let local_app_data = scratch.0.join("local-app-data");
    let data = local_app_data.join("DeskPilot");
    let temp = scratch.0.join("temp");
    fs::create_dir_all(&data).unwrap();
    fs::create_dir_all(&temp).unwrap();

    // Stale artifacts must never satisfy this run's evidence contract.
    fs::write(data.join("self-test-modern.txt"), "STALE").unwrap();
    fs::write(
        data.join("self-test-evidence-modern.json"),
        br#"{"runId":"stale","descendantTreeKilled":false,"survivingDescendantPids":[999999]}"#,
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_deskpilot"))
        .arg("--self-test")
        .env("LOCALAPPDATA", &local_app_data)
        .env("TEMP", &temp)
        .env("TMP", &temp)
        .output()
        .expect("launch DeskPilot self-test");

    let self_test_output = fs::read_to_string(data.join("self-test-modern.txt"))
        .unwrap_or_else(|error| format!("unreadable: {error}"));
    assert!(
        output.status.success(),
        "self-test exited {:?}: result={self_test_output} stdout={} stderr={}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read_to_string(data.join("self-test-modern.txt")).unwrap(),
        "DPAPI_AND_JOB_PASS"
    );
    assert!(!data.join("self-test.txt").exists());

    let evidence = read_json(&data.join("self-test-evidence-modern.json"));
    assert_ne!(evidence["runId"], "stale");
    assert!(evidence["runId"].as_str().is_some_and(|id| !id.is_empty()));
    assert_eq!(evidence["descendantTreeKilled"], true);
    assert_eq!(evidence["jobObjectClosed"], true);
    assert_eq!(evidence["survivingDescendantPids"], serde_json::json!([]));
    assert_eq!(
        evidence["processTreePids"].as_array().unwrap().len(),
        3,
        "evidence must cover the supervised child and two descendants"
    );
    for pid in evidence["processTreePids"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_u64)
    {
        assert!(
            !process_is_alive(pid as u32),
            "self-test process {pid} survived Job Object close"
        );
    }
    assert_eq!(evidence["tempArtifactsRemoved"], true);

    let leftovers: Vec<_> = fs::read_dir(&temp)
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert!(
        leftovers.is_empty(),
        "self-test left temporary files: {leftovers:?}"
    );
}
