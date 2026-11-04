//! Tray icon per OS. Events reach the UI through a channel; the tray asks egui
//! to repaint so the event is handled right away.

use std::sync::mpsc::{channel, Receiver, Sender};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrayEvent {
    ToggleWindow,
    ToggleEnabled,
    Quit,
}

pub struct Tray {
    rx: Receiver<TrayEvent>,
    inner: imp::Inner,
}

impl Tray {
    pub fn new(ctx: eframe::egui::Context) -> Result<Tray, String> {
        let (tx, rx) = channel();
        let inner = imp::start(ctx, tx)?;
        Ok(Tray { rx, inner })
    }

    pub fn poll(&self) -> Vec<TrayEvent> {
        self.rx.try_iter().collect()
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        imp::set_enabled(&mut self.inner, enabled);
    }
}

fn send(tx: &Sender<TrayEvent>, ctx: &eframe::egui::Context, event: TrayEvent) {
    let _ = tx.send(event);
    ctx.request_repaint();
}

#[cfg(target_os = "linux")]
mod imp {
    use super::{send, TrayEvent};
    use eframe::egui::Context;
    use ksni::blocking::TrayMethods;
    use std::sync::mpsc::Sender;

    pub type Inner = ksni::blocking::Handle<Item>;

    pub struct Item {
        ctx: Context,
        tx: Sender<TrayEvent>,
        enabled: bool,
    }

    impl ksni::Tray for Item {
        fn id(&self) -> String {
            "just-an-eq".into()
        }
        fn title(&self) -> String {
            "just an eq".into()
        }
        fn icon_pixmap(&self) -> Vec<ksni::Icon> {
            // ksni wants ARGB32 in network byte order.
            let rgba = crate::icon::rgba();
            let data = rgba.chunks(4).flat_map(|p| [p[3], p[0], p[1], p[2]]).collect();
            vec![ksni::Icon { width: crate::icon::SIZE as i32, height: crate::icon::SIZE as i32, data }]
        }
        fn activate(&mut self, _x: i32, _y: i32) {
            send(&self.tx, &self.ctx, TrayEvent::ToggleWindow);
        }
        fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
            use ksni::menu::*;
            vec![
                StandardItem {
                    label: "Show / hide".into(),
                    activate: Box::new(|t: &mut Item| send(&t.tx, &t.ctx, TrayEvent::ToggleWindow)),
                    ..Default::default()
                }
                .into(),
                CheckmarkItem {
                    label: "On".into(),
                    checked: self.enabled,
                    activate: Box::new(|t: &mut Item| send(&t.tx, &t.ctx, TrayEvent::ToggleEnabled)),
                    ..Default::default()
                }
                .into(),
                MenuItem::Separator,
                StandardItem {
                    label: "Quit".into(),
                    activate: Box::new(|t: &mut Item| send(&t.tx, &t.ctx, TrayEvent::Quit)),
                    ..Default::default()
                }
                .into(),
            ]
        }
    }

    pub fn start(ctx: Context, tx: Sender<TrayEvent>) -> Result<Inner, String> {
        Item { ctx, tx, enabled: false }.spawn().map_err(|e| format!("tray: {e}"))
    }

    pub fn set_enabled(handle: &mut Inner, enabled: bool) {
        handle.update(|t| t.enabled = enabled);
    }
}

#[cfg(windows)]
mod imp {
    use super::{send, TrayEvent};
    use eframe::egui::Context;
    use std::sync::mpsc::Sender;
    use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
    use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};

    pub struct Inner {
        _tray: TrayIcon,
        toggle: MenuItem,
    }

    pub fn start(ctx: Context, tx: Sender<TrayEvent>) -> Result<Inner, String> {
        let show = MenuItem::new("Show / hide", true, None);
        let toggle = MenuItem::new("Turn on", true, None);
        let quit = MenuItem::new("Quit", true, None);
        let menu = Menu::new();
        menu.append_items(&[&show, &toggle, &PredefinedMenuItem::separator(), &quit]).map_err(|e| e.to_string())?;
        let ids = (show.id().clone(), toggle.id().clone(), quit.id().clone());
        let (ctx2, tx2) = (ctx.clone(), tx.clone());
        MenuEvent::set_event_handler(Some(move |e: MenuEvent| {
            let event = if e.id == ids.0 {
                TrayEvent::ToggleWindow
            } else if e.id == ids.1 {
                TrayEvent::ToggleEnabled
            } else if e.id == ids.2 {
                TrayEvent::Quit
            } else {
                return;
            };
            send(&tx2, &ctx2, event);
        }));
        TrayIconEvent::set_event_handler(Some(move |e: TrayIconEvent| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = e {
                send(&tx, &ctx, TrayEvent::ToggleWindow);
            }
        }));
        let icon = Icon::from_rgba(crate::icon::rgba(), crate::icon::SIZE, crate::icon::SIZE).map_err(|e| e.to_string())?;
        let tray = TrayIconBuilder::new()
            .with_menu(Box::new(menu))
            .with_tooltip("just an eq")
            .with_icon(icon)
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Inner { _tray: tray, toggle })
    }

    pub fn set_enabled(inner: &mut Inner, enabled: bool) {
        inner.toggle.set_text(if enabled { "Turn off" } else { "Turn on" });
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod imp {
    use super::TrayEvent;
    use eframe::egui::Context;
    use std::sync::mpsc::Sender;
    pub struct Inner;
    pub fn start(_ctx: Context, _tx: Sender<TrayEvent>) -> Result<Inner, String> {
        Err("no tray on this OS".into())
    }
    pub fn set_enabled(_: &mut Inner, _: bool) {}
}
