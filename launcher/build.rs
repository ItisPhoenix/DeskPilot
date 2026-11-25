use std::{env, fs, path::PathBuf, process::Command};
fn main() {
    println!("cargo:rerun-if-changed=assets/deskpilot.ico");
    println!("cargo:rerun-if-changed=assets/icon.png");
    println!("cargo:rerun-if-changed=assets/deskpilot-wordmark.svg");
    println!("cargo:rerun-if-changed=assets/deskpilot-mark.svg");
    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let icon = root.join("assets/deskpilot.ico");
    let rcfile = out.join("deskpilot.rc");
    let resource = out.join("deskpilot.res");
    let rc = format!(
        r#"101 ICON "{}"
1 VERSIONINFO
 FILEVERSION 1,0,0,0
 PRODUCTVERSION 1,0,0,0
 FILEFLAGSMASK 0x3fL
 FILEFLAGS 0
 FILEOS 0x40004L
 FILETYPE 0x1L
 FILESUBTYPE 0
BEGIN
 BLOCK "StringFileInfo"
 BEGIN
  BLOCK "040904B0"
  BEGIN
   VALUE "CompanyName", "DeskPilot\0"
   VALUE "FileDescription", "DeskPilot - Private Desktop Control\0"
   VALUE "FileVersion", "1.0.0.0\0"
   VALUE "InternalName", "DeskPilot\0"
   VALUE "OriginalFilename", "DeskPilot.exe\0"
   VALUE "ProductName", "DeskPilot\0"
   VALUE "ProductVersion", "1.0.0\0"
  END
 END
 BLOCK "VarFileInfo"
 BEGIN
  VALUE "Translation", 0x409, 1200
 END
END
"#,
        icon.to_string_lossy().replace('\\', "\\\\")
    );
    fs::write(&rcfile, rc).unwrap();
    let sdk = PathBuf::from(r"C:\Program Files (x86)\Windows Kits\10\bin");
    let mut paths: Vec<_> = fs::read_dir(sdk)
        .expect("Windows SDK")
        .filter_map(Result::ok)
        .map(|e| e.path().join("x64/rc.exe"))
        .filter(|p| p.is_file())
        .collect();
    paths.sort();
    let compiler = paths.last().expect("Windows SDK resource compiler");
    let status = Command::new(compiler)
        .arg("/nologo")
        .arg("/fo")
        .arg(&resource)
        .arg(&rcfile)
        .status()
        .unwrap();
    assert!(status.success(), "Windows resource compiler failed");
    println!("cargo:rustc-link-arg={}", resource.display());
}
