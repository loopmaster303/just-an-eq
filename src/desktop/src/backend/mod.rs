//! The platform does the DSP; a backend only writes configuration and switches it on and off.

use crate::settings::Settings;

pub trait Backend {
    /// Push the settings. `enabled == false` must leave the system as it was before.
    fn apply(&mut self, settings: &Settings, enabled: bool) -> Result<(), String>;
    /// Called a few times per second while the app runs; for following device changes.
    fn tick(&mut self, _settings: &Settings, _enabled: bool) -> Result<(), String> {
        Ok(())
    }
}

#[cfg(target_os = "linux")]
pub mod pipewire;
#[cfg(any(windows, test))]
pub mod apo;

#[cfg(target_os = "linux")]
pub fn create() -> Box<dyn Backend> {
    Box::new(pipewire::PipeWire::default())
}

#[cfg(windows)]
pub fn create() -> Box<dyn Backend> {
    Box::new(apo::Apo::default())
}

#[cfg(not(any(target_os = "linux", windows)))]
pub fn create() -> Box<dyn Backend> {
    struct Unsupported;
    impl Backend for Unsupported {
        fn apply(&mut self, _: &Settings, enabled: bool) -> Result<(), String> {
            if enabled {
                Err("no backend on this OS; use the Swift app on macOS".into())
            } else {
                Ok(())
            }
        }
    }
    Box::new(Unsupported)
}
