//! The panel: On/Off, Mixer (4 knobs) or Graphic (10 sliders + presets), balance, boost.

use crate::backend::{self, Backend};
use crate::params::{GRAPHIC_LABELS, GRAPHIC_RANGE, MIXER_NAMES, MIXER_RANGE, PRESETS};
use crate::settings::{self, Mode, Settings, Stored};
use crate::tray::{Tray, TrayEvent};
use eframe::egui::{self, Color32, Pos2, Sense, Stroke, Vec2, ViewportCommand};
use std::time::{Duration, Instant};

const APPLY_EVERY: Duration = Duration::from_millis(60);
const BG: Color32 = Color32::from_rgb(22, 22, 24);
const ACCENT: Color32 = Color32::from_rgb(255, 159, 10);
const DIM: Color32 = Color32::from_rgb(70, 70, 74);

pub struct App {
    stored: Stored,
    enabled: bool,
    backend: Box<dyn Backend>,
    tray: Option<Tray>,
    dirty: bool,
    last_apply: Instant,
    error: Option<String>,
    visible: bool,
    quitting: bool,
}

impl App {
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        let mut visuals = egui::Visuals::dark();
        visuals.panel_fill = BG;
        visuals.window_fill = BG;
        cc.egui_ctx.set_visuals(visuals);
        let tray = match Tray::new(cc.egui_ctx.clone()) {
            Ok(t) => Some(t),
            Err(e) => {
                eprintln!("{e}");
                None
            }
        };
        App {
            stored: settings::load(),
            enabled: false,
            backend: backend::create(),
            tray,
            dirty: false,
            last_apply: Instant::now(),
            error: None,
            visible: true,
            quitting: false,
        }
    }

    fn settings(&mut self) -> &mut Settings {
        &mut self.stored.settings
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if let Some(t) = &mut self.tray {
            t.set_enabled(enabled);
        }
        self.push();
    }

    /// Push to the backend now (used for On/Off and presets).
    fn push(&mut self) {
        self.error = self.backend.apply(&self.stored.settings, self.enabled).err();
        if self.error.is_some() && self.enabled {
            self.enabled = false;
            if let Some(t) = &mut self.tray {
                t.set_enabled(false);
            }
        }
        if let Err(e) = settings::save(&self.stored) {
            self.error = Some(e);
        }
        self.dirty = false;
        self.last_apply = Instant::now();
    }

    fn handle_tray(&mut self, ctx: &egui::Context) {
        let events = self.tray.as_ref().map(|t| t.poll()).unwrap_or_default();
        for e in events {
            match e {
                TrayEvent::ToggleWindow => {
                    self.visible = !self.visible;
                    ctx.send_viewport_cmd(ViewportCommand::Visible(self.visible));
                    if self.visible {
                        ctx.send_viewport_cmd(ViewportCommand::Focus);
                    }
                }
                TrayEvent::ToggleEnabled => self.set_enabled(!self.enabled),
                TrayEvent::Quit => {
                    self.quitting = true;
                    ctx.send_viewport_cmd(ViewportCommand::Close);
                }
            }
        }
    }

    fn draw(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.heading("just an eq");
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let mut on = self.enabled;
                if toggle(ui, &mut on).changed() {
                    self.set_enabled(on);
                }
                ui.label(if self.enabled { "On" } else { "Off" });
            });
        });
        ui.add_space(6.0);
        let mut mode = self.stored.settings.mode;
        ui.horizontal(|ui| {
            ui.selectable_value(&mut mode, Mode::Mixer, "Mixer");
            ui.selectable_value(&mut mode, Mode::Graphic, "Graphic");
        });
        if mode != self.stored.settings.mode {
            self.settings().mode = mode;
            self.dirty = true;
        }
        ui.add_space(10.0);
        match mode {
            Mode::Mixer => self.draw_mixer(ui),
            Mode::Graphic => self.draw_graphic(ui),
        }
        ui.add_space(10.0);
        ui.horizontal(|ui| {
            ui.label("Balance");
            let s = self.settings();
            if ui.add(egui::Slider::new(&mut s.balance, -1.0..=1.0).show_value(false)).changed() {
                self.dirty = true;
            }
            ui.label("Boost");
            let s = self.settings();
            if ui.add(egui::Slider::new(&mut s.boost_db, 0.0..=12.0).suffix(" dB").fixed_decimals(0)).changed() {
                self.dirty = true;
            }
        });
        if let Some(err) = &self.error {
            ui.add_space(6.0);
            ui.colored_label(Color32::from_rgb(255, 90, 80), err);
        } else if let Some(note) = self.backend.status() {
            ui.add_space(6.0);
            ui.colored_label(ACCENT, note);
        }
    }

    fn draw_mixer(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.add_space(8.0);
            for (i, name) in MIXER_NAMES.iter().enumerate() {
                let mut changed = false;
                ui.vertical(|ui| {
                    ui.set_width(88.0);
                    let s = &mut self.stored.settings;
                    changed = knob(ui, &mut s.mixer_db[i], MIXER_RANGE);
                    ui.vertical_centered(|ui| {
                        ui.label(*name);
                        ui.small(format!("{:+.0} dB", s.mixer_db[i]));
                    });
                });
                self.dirty |= changed;
            }
        });
    }

    fn draw_graphic(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.label("Preset");
            let current = self.stored.preset.clone().unwrap_or_else(|| "Custom".into());
            egui::ComboBox::from_id_salt("preset").selected_text(current).show_ui(ui, |ui| {
                for (name, bands) in PRESETS {
                    if ui.selectable_label(self.stored.preset.as_deref() == Some(name), name).clicked() {
                        self.stored.settings.band_db = bands;
                        self.stored.preset = Some(name.into());
                        self.dirty = true;
                    }
                }
            });
        });
        ui.add_space(6.0);
        ui.horizontal(|ui| {
            ui.add_space(4.0);
            for i in 0..10 {
                ui.vertical(|ui| {
                    ui.set_width(34.0);
                    let s = &mut self.stored.settings;
                    let r = ui.add(
                        egui::Slider::new(&mut s.band_db[i], GRAPHIC_RANGE.0..=GRAPHIC_RANGE.1)
                            .vertical()
                            .show_value(false),
                    );
                    if r.changed() {
                        self.dirty = true;
                        self.stored.preset = None;
                    }
                    if r.double_clicked() {
                        s.band_db[i] = 0.0;
                        self.dirty = true;
                        self.stored.preset = None;
                    }
                    ui.small(GRAPHIC_LABELS[i]);
                });
            }
        });
    }
}

impl eframe::App for App {
    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.handle_tray(ctx);
        if ctx.input(|i| i.viewport().close_requested()) && self.tray.is_some() && !self.quitting {
            ctx.send_viewport_cmd(ViewportCommand::CancelClose);
            self.visible = false;
            ctx.send_viewport_cmd(ViewportCommand::Visible(false));
        }
        if let Err(e) = self.backend.tick(&self.stored.settings, self.enabled) {
            self.error = Some(e);
            self.enabled = false;
            if let Some(t) = &mut self.tray {
                t.set_enabled(false);
            }
        }
        if self.dirty {
            if self.last_apply.elapsed() >= APPLY_EVERY {
                self.push();
            } else {
                ctx.request_repaint_after(APPLY_EVERY);
            }
        }
        ctx.request_repaint_after(Duration::from_millis(500));
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        egui::Frame::new().inner_margin(14.0).show(ui, |ui| self.draw(ui));
    }

    fn on_exit(&mut self) {
        let _ = self.backend.apply(&self.stored.settings, false);
    }
}

/// A rotary knob: drag up/down, double-click resets to 0. Returns whether the value changed.
fn knob(ui: &mut egui::Ui, value: &mut f32, range: (f32, f32)) -> bool {
    let size = Vec2::splat(72.0);
    let (rect, response) = ui.allocate_exact_size(size, Sense::click_and_drag());
    let mut changed = false;
    if response.double_clicked() {
        *value = 0.0;
        changed = true;
    } else if response.dragged() {
        let span = range.1 - range.0;
        *value = (*value - response.drag_delta().y * span / 150.0).clamp(range.0, range.1);
        changed = true;
    }
    let painter = ui.painter();
    let center = rect.center();
    let radius = rect.width() / 2.0 - 6.0;
    let start = 135f32.to_radians();
    let sweep = 270f32.to_radians();
    arc(painter, center, radius, start, start + sweep, Stroke::new(4.0, DIM));
    let zero = start + sweep * (0.0 - range.0) / (range.1 - range.0);
    let at = start + sweep * (*value - range.0) / (range.1 - range.0);
    arc(painter, center, radius, zero.min(at), zero.max(at), Stroke::new(4.0, ACCENT));
    painter.circle_filled(center, radius - 8.0, Color32::from_rgb(44, 44, 48));
    let tip = center + Vec2::angled(at) * (radius - 10.0);
    painter.line_segment([center + Vec2::angled(at) * (radius - 22.0), tip], Stroke::new(3.0, Color32::WHITE));
    changed
}

fn arc(painter: &egui::Painter, center: Pos2, radius: f32, from: f32, to: f32, stroke: Stroke) {
    if to <= from {
        return;
    }
    let steps = ((to - from) / 0.05).ceil().max(1.0) as usize;
    let points: Vec<Pos2> = (0..=steps)
        .map(|i| center + Vec2::angled(from + (to - from) * i as f32 / steps as f32) * radius)
        .collect();
    painter.add(egui::Shape::line(points, stroke));
}

fn toggle(ui: &mut egui::Ui, on: &mut bool) -> egui::Response {
    let size = Vec2::new(40.0, 22.0);
    let (rect, mut response) = ui.allocate_exact_size(size, Sense::click());
    if response.clicked() {
        *on = !*on;
        response.mark_changed();
    }
    let t = ui.ctx().animate_bool(response.id, *on);
    let fill = Color32::from_rgb(
        (DIM.r() as f32 + (ACCENT.r() as f32 - DIM.r() as f32) * t) as u8,
        (DIM.g() as f32 + (ACCENT.g() as f32 - DIM.g() as f32) * t) as u8,
        (DIM.b() as f32 + (ACCENT.b() as f32 - DIM.b() as f32) * t) as u8,
    );
    let r = rect.height() / 2.0;
    ui.painter().rect_filled(rect, r, fill);
    let x = rect.left() + r + (rect.width() - 2.0 * r) * t;
    ui.painter().circle_filled(Pos2::new(x, rect.center().y), r - 3.0, Color32::WHITE);
    response
}
