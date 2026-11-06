//! Windows: the exe is its own installer. First start from a download folder
//! copies it to Program Files, installs the bundled Equalizer APO silently,
//! registers it on every active playback device and starts the app in the tray.

use crate::backend::apo_reg;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;
use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, KEY_WRITE};
use winreg::RegKey;

const NO_WINDOW: u32 = 0x0800_0000;
const RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const UNINST: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\just-an-eq";
/// Equalizer APO installer, bundled at build time (see build.rs).
const APO_SETUP: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/EqualizerAPO64.exe"));

pub fn install_dir() -> PathBuf {
    let base = std::env::var_os("ProgramFiles").unwrap_or_else(|| r"C:\Program Files".into());
    PathBuf::from(base).join("just an eq")
}

fn installed_exe() -> PathBuf {
    install_dir().join("just-an-eq.exe")
}

pub fn is_admin() -> bool {
    RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey_with_flags("SOFTWARE", KEY_WRITE).is_ok()
}

/// True when this exe runs from somewhere else, for example a download
/// folder: first install, or an update that replaces the installed copy.
pub fn wants_install() -> bool {
    let Ok(me) = std::env::current_exe() else { return false };
    !me.starts_with(install_dir())
}

/// Re-run this exe elevated (one UAC prompt) with the given argument.
pub fn relaunch_elevated(arg: &str) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    Command::new("powershell")
        .args(["-NoProfile", "-WindowStyle", "Hidden", "-Command"])
        .arg(format!("Start-Process -Verb RunAs -FilePath '{}' -ArgumentList '{arg}'", exe.display()))
        .creation_flags(NO_WINDOW)
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn run_hidden(program: &str, args: &[&str]) -> Result<bool, String> {
    Command::new(program)
        .args(args)
        .creation_flags(NO_WINDOW)
        .status()
        .map(|s| s.success())
        .map_err(|e| format!("{program}: {e}"))
}

fn install_apo() -> Result<(), String> {
    if apo_reg::installed() {
        return Ok(());
    }
    if APO_SETUP.is_empty() {
        return Err("Equalizer APO installer is not bundled in this build".into());
    }
    let setup = std::env::temp_dir().join("EqualizerAPO64-setup.exe");
    std::fs::write(&setup, APO_SETUP).map_err(|e| format!("write APO setup: {e}"))?;
    // Even with /S the APO setup opens its device selector and waits for it.
    // We pick the devices ourselves, so close it as soon as it appears.
    let mut child = Command::new(&setup).arg("/S").creation_flags(NO_WINDOW).spawn().map_err(|e| format!("APO setup: {e}"))?;
    let started = std::time::Instant::now();
    let ok = loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            break status.success();
        }
        if started.elapsed() > std::time::Duration::from_secs(180) {
            let _ = child.kill();
            break false;
        }
        for p in ["DeviceSelector.exe", "Configurator.exe"] {
            let _ = run_hidden("taskkill", &["/IM", p, "/F"]);
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    };
    let _ = std::fs::remove_file(&setup);
    if !ok || !apo_reg::installed() {
        return Err("Equalizer APO setup failed".into());
    }
    Ok(())
}

fn shortcut(target: &str) -> Result<(), String> {
    let script = format!(
        "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Programs')+'\\just an eq.lnk');$s.TargetPath='{target}';$s.Save()"
    );
    run_hidden("powershell", &["-NoProfile", "-WindowStyle", "Hidden", "-Command", &script])?;
    Ok(())
}

/// Must run elevated. Returns the installed exe path.
pub fn install() -> Result<PathBuf, String> {
    let me = std::env::current_exe().map_err(|e| e.to_string())?;
    let dir = install_dir();
    let exe = installed_exe();
    std::fs::create_dir_all(&dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    if me != exe {
        let _ = run_hidden("taskkill", &["/IM", "just-an-eq.exe", "/F", "/FI", &format!("PID ne {}", std::process::id())]);
        std::fs::copy(&me, &exe).map_err(|e| format!("copy to {}: {e}", exe.display()))?;
    }
    install_apo()?;
    apo_reg::register_all()?;
    let quoted = format!("\"{}\"", exe.display());
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    hkcu.create_subkey(RUN).and_then(|(k, _)| k.set_value("just an eq", &quoted)).map_err(|e| e.to_string())?;
    let (u, _) = RegKey::predef(HKEY_LOCAL_MACHINE).create_subkey(UNINST).map_err(|e| e.to_string())?;
    u.set_value("DisplayName", &"just an eq").map_err(|e| e.to_string())?;
    u.set_value("DisplayIcon", &exe.to_string_lossy().to_string()).map_err(|e| e.to_string())?;
    u.set_value("UninstallString", &format!("{quoted} --uninstall")).map_err(|e| e.to_string())?;
    u.set_value("Publisher", &"just an eq").map_err(|e| e.to_string())?;
    u.set_value("NoModify", &1u32).map_err(|e| e.to_string())?;
    u.set_value("NoRepair", &1u32).map_err(|e| e.to_string())?;
    let _ = shortcut(&exe.to_string_lossy());
    Ok(exe)
}

/// Start the installed app as the logged-in user, not as admin.
pub fn launch_unelevated(exe: &std::path::Path) {
    let windir = std::env::var("WINDIR").unwrap_or_else(|_| r"C:\Windows".into());
    let _ = Command::new(format!("{windir}\\explorer.exe")).arg(exe).spawn();
}

/// Must run elevated. Equalizer APO stays; our filter file is switched off.
pub fn uninstall() -> Result<(), String> {
    let _ = run_hidden("taskkill", &["/IM", "just-an-eq.exe", "/F", "/FI", &format!("PID ne {}", std::process::id())]);
    if let Some(cfg) = crate::backend::apo::config_dir() {
        let _ = std::fs::write(cfg.join(crate::backend::apo::FILE), "# off\n");
    }
    let _ = RegKey::predef(HKEY_CURRENT_USER).open_subkey_with_flags(RUN, KEY_WRITE).and_then(|k| k.delete_value("just an eq"));
    let _ = RegKey::predef(HKEY_LOCAL_MACHINE).delete_subkey_all(UNINST);
    let script = "Remove-Item -LiteralPath ([Environment]::GetFolderPath('Programs')+'\\just an eq.lnk') -ErrorAction SilentlyContinue";
    let _ = run_hidden("powershell", &["-NoProfile", "-WindowStyle", "Hidden", "-Command", script]);
    // the running exe cannot delete itself; cmd does it after we exit
    let dir = install_dir();
    // raw_arg: cmd.exe would strip the outer quotes std adds around "/C ...".
    let _ = Command::new("cmd")
        .raw_arg(format!("/C ping -n 3 127.0.0.1 >nul & rmdir /S /Q \"{}\"", dir.display()))
        .creation_flags(NO_WINDOW)
        .spawn();
    Ok(())
}
