#![cfg_attr(windows, windows_subsystem = "windows")]

mod backend;
mod icon;
#[cfg(windows)]
mod install;
mod params;
mod settings;
mod tray;
mod ui;

fn main() -> eframe::Result {
    #[cfg(windows)]
    if let Some(code) = windows_cli() {
        std::process::exit(code);
    }
    let options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_title("just an eq")
            .with_inner_size([376.0, 620.0])
            .with_resizable(false)
            .with_icon(eframe::egui::IconData { rgba: icon::rgba(), width: icon::SIZE, height: icon::SIZE }),
        ..Default::default()
    };
    // `--screenshot out.png [--graphic]`: render the demo panel to a PNG and quit (README pictures).
    let shot = std::env::args().skip_while(|a| a != "--screenshot").nth(1).map(std::path::PathBuf::from);
    let graphic = std::env::args().any(|a| a == "--graphic");
    eframe::run_native(
        "just an eq",
        options,
        Box::new(move |cc| {
            Ok(Box::new(match shot {
                Some(path) => ui::App::for_screenshot(cc, path, graphic),
                None => ui::App::new(cc),
            }))
        }),
    )
}

/// `--register-apo`, `--install`, `--uninstall` run elevated and exit; a first
/// start from a download folder turns into `--install` after one UAC prompt.
#[cfg(windows)]
fn windows_cli() -> Option<i32> {
    let arg = std::env::args().nth(1);
    let code = |r: Result<(), String>| {
        if let Err(e) = &r {
            let log = std::env::temp_dir().join("just-an-eq-install.log");
            let _ = std::fs::write(log, format!("{}: {e}\n", arg.as_deref().unwrap_or("start")));
        }
        Some(if r.is_ok() { 0 } else { 1 })
    };
    match arg.as_deref() {
        Some("--register-apo") => code(backend::apo_reg::register_all().map(|_| ())),
        Some("--install") if install::is_admin() => {
            let r = install::install().map(|exe| install::launch_unelevated(&exe));
            code(r)
        }
        Some("--install") => code(install::relaunch_elevated("--install")),
        Some("--uninstall") if install::is_admin() => code(install::uninstall()),
        Some("--uninstall") => code(install::relaunch_elevated("--uninstall")),
        None if install::wants_install() => code(install::relaunch_elevated("--install")),
        _ => None,
    }
}
