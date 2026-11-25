use sha2::{Digest, Sha256};
use std::{fs, path::PathBuf};

fn launcher_file(relative: &str) -> String {
    fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(relative)).unwrap()
}

fn sha256(path: &str) -> String {
    let bytes = fs::read(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(path)).unwrap();
    format!("{:x}", Sha256::digest(bytes))
}

#[test]
fn launcher_has_no_path_fallback_and_one_well_named_run_value() {
    let core = launcher_file("src/core.inc.rs");
    assert!(
        !core.contains("find_on_path"),
        "PATH fallback is still present"
    );
    assert!(
        !core.contains("env::var_os(\"PATH\")"),
        "PATH must not select executables"
    );
    assert!(core.contains("const RUN_VALUE_NAME: &str = \"DeskPilot\";"));
    assert_eq!(core.matches("HKCU_CURRENT_USER").count(), 0);
}

#[test]
fn validator_is_fail_closed_fresh_and_never_starts_the_gui_or_tunnel() {
    let script = launcher_file("scripts/validate-deskpilot.ps1");
    assert!(
        script.contains("finally"),
        "validator needs guaranteed cleanup"
    );
    assert!(
        script.contains("exit 1"),
        "failures must produce a nonzero exit code"
    );
    assert!(script.contains("self-test-modern.txt"));
    assert!(script.contains("NewGuid"), "each run needs fresh evidence");
    assert!(
        !script.contains("--background"),
        "validator must not launch normal GUI startup"
    );
    assert!(
        !script.contains("127.0.0.1:8080"),
        "validator must not probe or use port 8080"
    );
    assert!(
        !script.contains("Invoke-WebRequest"),
        "validator must not contact the tunnel API"
    );
}

#[test]
fn cargo_lock_identifies_the_deskpilot_launcher_package() {
    let lock = launcher_file("Cargo.lock");
    let root = lock
        .split("[[package]]")
        .find(|section| section.contains("name = \"deskpilot-launcher\""))
        .unwrap_or_else(|| panic!("Cargo.lock has no deskpilot-launcher root package"));
    assert!(root.contains("version = \"1.0.0\""));
    assert!(!lock.contains("name = \"desktop-commander-local\""));
}

#[test]
fn approved_dashboard_wordmark_and_monogram_are_unchanged() {
    // These are regression sentinels for the approved assets. The validator
    // performs the authoritative SHA-256 comparison.
    assert_eq!(
        sha256("assets/dashboard.html"),
        "140646f09168de8f9870bced99c3f18e6e93dc5d2d4bb4502e42fd40b9330648"
    );
    assert_eq!(
        sha256("assets/deskpilot-wordmark.svg"),
        "c1e4e01a231c11be3f1eec70916b30a75f4284afa04f1a4da03e4e8d2acab54c"
    );
    assert_eq!(
        sha256("assets/deskpilot-mark.svg"),
        "10c045fdcdc2364ab549e454a62e4890d5024f924bf76803daf726a1d87aba0d"
    );
}
