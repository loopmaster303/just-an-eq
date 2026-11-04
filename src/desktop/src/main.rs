#![cfg_attr(windows, windows_subsystem = "windows")]

mod backend;
mod icon;
mod params;
mod settings;
mod tray;
mod ui;

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_title("just an eq")
            .with_inner_size([400.0, 330.0])
            .with_resizable(false)
            .with_icon(eframe::egui::IconData { rgba: icon::rgba(), width: icon::SIZE, height: icon::SIZE }),
        ..Default::default()
    };
    eframe::run_native("just an eq", options, Box::new(|cc| Ok(Box::new(ui::App::new(cc)))))
}
