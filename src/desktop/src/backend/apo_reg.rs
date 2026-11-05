//! Windows: register Equalizer APO on every active playback device, the way
//! its DeviceSelector does, so the user never has to pick devices by hand.
//! Writing needs admin rights; reading does not.

use std::os::windows::process::CommandExt;
use std::process::Command;
use winreg::enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WRITE};
use winreg::RegKey;

const RENDER: &str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render";
const APO: &str = r"SOFTWARE\EqualizerAPO";
const FX: &str = "{d04e05a6-594b-4fb6-a80d-01af5eed7d1d}";
const NAME: &str = "{a45c254e-df1c-4efd-8020-67d146a850e0},2";
/// Equalizer APO's stream (pre-mix) and endpoint (post-mix) effect classes.
const SFX: &str = "{EACD2258-FCAC-4FF4-B36D-419E924A6D79}";
const EFX: &str = "{EC1CC9CE-FAED-4822-828A-82A81A6F018F}";
const NO_WINDOW: u32 = 0x0800_0000;

pub struct Endpoint {
    pub id: String,
    pub name: String,
}

/// Installed means the registry entry and the DLL both exist; the APO
/// uninstaller can leave the key behind.
pub fn installed() -> bool {
    RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey_with_flags(APO, KEY_READ)
        .and_then(|k| k.get_value::<String, _>("InstallPath"))
        .is_ok_and(|p| std::path::Path::new(&p).join("EqualizerAPO.dll").is_file())
}

fn fx_value(id: &str, index: u8) -> Option<String> {
    RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey_with_flags(format!(r"{RENDER}\{id}\FxProperties"), KEY_READ)
        .ok()?
        .get_value(format!("{FX},{index}"))
        .ok()
}

pub fn is_registered(id: &str) -> bool {
    fx_value(id, 5).is_some_and(|v| v.eq_ignore_ascii_case(SFX))
}

/// Active playback endpoints (DeviceState 1).
pub fn active_endpoints() -> Vec<Endpoint> {
    let Ok(render) = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey_with_flags(RENDER, KEY_READ) else {
        return Vec::new();
    };
    render
        .enum_keys()
        .flatten()
        .filter_map(|id| {
            let key = render.open_subkey_with_flags(&id, KEY_READ).ok()?;
            (key.get_value::<u32, _>("DeviceState").ok()? == 1).then_some(())?;
            let name = key
                .open_subkey_with_flags("Properties", KEY_READ)
                .and_then(|p| p.get_value::<String, _>(NAME))
                .unwrap_or_else(|_| id.clone());
            Some(Endpoint { id, name })
        })
        .collect()
}

pub fn missing() -> Vec<Endpoint> {
    active_endpoints().into_iter().filter(|e| !is_registered(&e.id)).collect()
}

/// Register on every active endpoint that lacks it and restart the audio
/// service. Needs admin rights. Returns how many endpoints were changed.
pub fn register_all() -> Result<usize, String> {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let mut changed = 0;
    for e in missing() {
        // The endpoint keys belong to SYSTEM and are read-only for admins.
        acl::make_writable(&format!(r"MACHINE\{RENDER}\{}", e.id)).map_err(|err| format!("{}: {err}", e.name))?;
        // FxProperties may exist already with its own, non-inherited ACL.
        let _ = acl::make_writable(&format!(r"MACHINE\{RENDER}\{}\FxProperties", e.id));
        let fx = hklm
            .create_subkey(format!(r"{RENDER}\{}\FxProperties", e.id))
            .map_err(|err| format!("{}: {err}", e.name))?
            .0;
        let (backup, _) = hklm
            .create_subkey(format!(r"{APO}\Child APOs\{}", e.id))
            .map_err(|err| format!("backup {}: {err}", e.name))?;
        let orig = |i: u8| fx.get_value::<String, _>(format!("{FX},{i}")).ok();
        for i in [1u8, 2, 5, 6, 7] {
            let v = orig(i).unwrap_or_else(|| "!VALUE".into());
            backup.set_value(format!("{FX},{i}"), &v).map_err(|err| err.to_string())?;
        }
        backup.set_value("PreMixChild", &orig(5).unwrap_or_default()).map_err(|err| err.to_string())?;
        backup.set_value("PostMixChild", &orig(7).unwrap_or_default()).map_err(|err| err.to_string())?;
        backup.set_value("AllowSilentBufferModification", &"false").map_err(|err| err.to_string())?;
        backup.set_value("Version", &"2").map_err(|err| err.to_string())?;
        let fx = hklm
            .open_subkey_with_flags(format!(r"{RENDER}\{}\FxProperties", e.id), KEY_WRITE)
            .map_err(|err| format!("{}: {err}", e.name))?;
        fx.set_value(format!("{FX},5"), &SFX).map_err(|err| err.to_string())?;
        fx.set_value(format!("{FX},7"), &EFX).map_err(|err| err.to_string())?;
        changed += 1;
    }
    if changed > 0 {
        restart_audio()?;
    }
    Ok(changed)
}

fn restart_audio() -> Result<(), String> {
    for args in [["stop", "audiosrv", "/y"], ["start", "audiosrv", ""]] {
        let status = Command::new("net")
            .args(args.iter().filter(|a| !a.is_empty()))
            .creation_flags(NO_WINDOW)
            .status()
            .map_err(|e| format!("net {}: {e}", args[0]))?;
        if !status.success() && args[0] == "start" {
            return Err("could not restart the Windows Audio service".into());
        }
    }
    Ok(())
}

/// Ask for admin rights (UAC) and run `--register-apo` in a second process.
pub fn request_register() -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    Command::new("powershell")
        .args(["-NoProfile", "-WindowStyle", "Hidden", "-Command"])
        .arg(format!("Start-Process -Verb RunAs -FilePath '{}' -ArgumentList '--register-apo'", exe.display()))
        .creation_flags(NO_WINDOW)
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Take ownership of a registry key and give Administrators full control,
/// recursively. This is what Equalizer APO's own device selector does.
mod acl {
    use std::ptr::null_mut;
    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, ERROR_SUCCESS, HANDLE, LUID};
    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSidToSidW, GetNamedSecurityInfoW, SetEntriesInAclW, SetNamedSecurityInfoW, EXPLICIT_ACCESS_W,
        SET_ACCESS, SE_REGISTRY_KEY, TRUSTEE_IS_GROUP, TRUSTEE_IS_SID, TRUSTEE_W,
    };
    use windows_sys::Win32::Security::{
        AdjustTokenPrivileges, LookupPrivilegeValueW, ACL, DACL_SECURITY_INFORMATION,
        LUID_AND_ATTRIBUTES, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, SE_PRIVILEGE_ENABLED,
        SUB_CONTAINERS_AND_OBJECTS_INHERIT, TOKEN_ADJUST_PRIVILEGES, TOKEN_PRIVILEGES,
    };
    use windows_sys::Win32::System::Registry::KEY_ALL_ACCESS;
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    fn enable_privilege(name: &str) -> Result<(), String> {
        unsafe {
            let mut token: HANDLE = null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES, &mut token) == 0 {
                return Err("OpenProcessToken failed".into());
            }
            let mut luid = LUID { LowPart: 0, HighPart: 0 };
            let ok = LookupPrivilegeValueW(null_mut(), wide(name).as_ptr(), &mut luid);
            if ok == 0 {
                CloseHandle(token);
                return Err(format!("no privilege {name}"));
            }
            let tp = TOKEN_PRIVILEGES {
                PrivilegeCount: 1,
                Privileges: [LUID_AND_ATTRIBUTES { Luid: luid, Attributes: SE_PRIVILEGE_ENABLED }],
            };
            let ok = AdjustTokenPrivileges(token, 0, &tp, 0, null_mut(), null_mut());
            CloseHandle(token);
            if ok == 0 {
                return Err(format!("cannot enable {name}"));
            }
        }
        Ok(())
    }

    pub fn make_writable(path: &str) -> Result<(), String> {
        enable_privilege("SeTakeOwnershipPrivilege")?;
        enable_privilege("SeRestorePrivilege")?;
        let path = wide(path);
        unsafe {
            let mut admins = null_mut();
            if ConvertStringSidToSidW(wide("S-1-5-32-544").as_ptr(), &mut admins) == 0 {
                return Err("admin SID".into());
            }
            let r = SetNamedSecurityInfoW(path.as_ptr(), SE_REGISTRY_KEY, OWNER_SECURITY_INFORMATION, admins, null_mut(), null_mut(), null_mut());
            if r != ERROR_SUCCESS {
                LocalFree(admins as _);
                return Err(format!("take ownership: error {r}"));
            }
            let mut old_dacl: *mut ACL = null_mut();
            let mut sd: PSECURITY_DESCRIPTOR = null_mut();
            let r = GetNamedSecurityInfoW(path.as_ptr(), SE_REGISTRY_KEY, DACL_SECURITY_INFORMATION, null_mut(), null_mut(), &mut old_dacl, null_mut(), &mut sd);
            if r != ERROR_SUCCESS {
                LocalFree(admins as _);
                return Err(format!("read DACL: error {r}"));
            }
            let mut ea: EXPLICIT_ACCESS_W = std::mem::zeroed();
            ea.grfAccessPermissions = KEY_ALL_ACCESS;
            ea.grfAccessMode = SET_ACCESS;
            ea.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
            ea.Trustee = TRUSTEE_W {
                pMultipleTrustee: null_mut(),
                MultipleTrusteeOperation: 0,
                TrusteeForm: TRUSTEE_IS_SID,
                TrusteeType: TRUSTEE_IS_GROUP,
                ptstrName: admins as *mut u16,
            };
            let mut new_dacl: *mut ACL = null_mut();
            let r = SetEntriesInAclW(1, &ea, old_dacl, &mut new_dacl);
            if r != ERROR_SUCCESS {
                LocalFree(sd as _);
                LocalFree(admins as _);
                return Err(format!("build DACL: error {r}"));
            }
            let r = SetNamedSecurityInfoW(path.as_ptr(), SE_REGISTRY_KEY, DACL_SECURITY_INFORMATION, null_mut(), null_mut(), new_dacl, null_mut());
            LocalFree(new_dacl as _);
            LocalFree(sd as _);
            LocalFree(admins as _);
            if r != ERROR_SUCCESS {
                return Err(format!("set DACL: error {r}"));
            }
        }
        Ok(())
    }
}
