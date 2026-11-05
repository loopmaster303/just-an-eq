//! Windows: Equalizer APO does the DSP inside the audio service. We write
//! `config\just-an-eq.txt` and make sure `config.txt` includes it.

use super::Backend;
use crate::params::{self, Shape};
use crate::settings::Settings;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub const FILE: &str = "just-an-eq.txt";
/// Our block goes at the top of `config.txt`, so `Device:`/`Stage:` lines of
/// other tools below it cannot switch our include off.
const BLOCK: [&str; 3] = ["# just an eq (keep at top)", "Device: all", "Include: just-an-eq.txt"];
const WATCH_EVERY: Duration = Duration::from_secs(5);

/// `%ProgramFiles%\EqualizerAPO\config`, if Equalizer APO is installed.
pub fn config_dir() -> Option<PathBuf> {
    let base = std::env::var_os("ProgramFiles")?;
    let dir = PathBuf::from(base).join("EqualizerAPO").join("config");
    dir.is_dir().then_some(dir)
}

fn db(linear: f32) -> f32 {
    if linear <= 0.0 {
        -60.0
    } else {
        (20.0 * linear.log10()).max(-60.0)
    }
}

pub fn config_text(s: &Settings, enabled: bool) -> String {
    let mut out = String::from("# written by just an eq; edits are overwritten\n");
    if !enabled {
        out.push_str("# off\n");
        return out;
    }
    let (left, right) = params::channel_gains(s);
    out.push_str(&format!("Channel: L\nPreamp: {:.2} dB\nChannel: R\nPreamp: {:.2} dB\nChannel: all\n", db(left), db(right)));
    let gains = params::effective_gains(s);
    let slots: std::ops::Range<usize> = match s.mode {
        crate::settings::Mode::Graphic => 0..10,
        crate::settings::Mode::Mixer => 10..14,
    };
    for slot in slots {
        let b = params::band(slot);
        let kind = match b.shape {
            Shape::Peak => "PK",
            Shape::LowShelf => "LSC",
            Shape::HighShelf => "HSC",
        };
        out.push_str(&format!("Filter: ON {kind} Fc {} Hz Gain {:.2} dB Q {:.4}\n", b.freq, gains[slot], b.q));
    }
    out
}

/// `config.txt` with our block first and everything else unchanged.
pub fn with_block(current: &str) -> String {
    let rest: Vec<&str> = current.lines().filter(|l| !BLOCK.contains(&l.trim())).collect();
    let mut out = BLOCK.join("\n");
    out.push('\n');
    for l in rest {
        out.push_str(l);
        out.push('\n');
    }
    out
}

/// Write the file atomically and make sure `config.txt` starts with our block.
pub fn install(dir: &Path, text: &str) -> Result<(), String> {
    let target = dir.join(FILE);
    let tmp = dir.join("just-an-eq.tmp");
    std::fs::write(&tmp, text).map_err(|e| format!("write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, &target).map_err(|e| format!("rename to {}: {e}", target.display()))?;
    let main = dir.join("config.txt");
    let current = std::fs::read_to_string(&main).unwrap_or_default();
    let next = with_block(&current);
    if next != current {
        std::fs::write(&main, next).map_err(|e| format!("write {}: {e}", main.display()))?;
    }
    Ok(())
}

#[derive(Default)]
pub struct Apo {
    dir: Option<PathBuf>,
    last_watch: Option<Instant>,
    /// Endpoint ids we already asked admin rights for; one UAC prompt each.
    asked: Vec<String>,
    status: Option<String>,
}

impl Backend for Apo {
    fn apply(&mut self, settings: &Settings, enabled: bool) -> Result<(), String> {
        if self.dir.is_none() {
            self.dir = config_dir();
        }
        let Some(dir) = &self.dir else {
            return if enabled { Err("Equalizer APO is not installed (no config folder)".into()) } else { Ok(()) };
        };
        install(dir, &config_text(settings, enabled))
    }

    /// Every few seconds: is Equalizer APO on every active playback device?
    /// A new device (headphones, Bluetooth) gets registered after one UAC prompt.
    #[cfg(windows)]
    fn tick(&mut self, _settings: &Settings, _enabled: bool) -> Result<(), String> {
        if self.last_watch.is_some_and(|t| t.elapsed() < WATCH_EVERY) {
            return Ok(());
        }
        self.last_watch = Some(Instant::now());
        if !super::apo_reg::installed() {
            return Ok(());
        }
        let missing = super::apo_reg::missing();
        if missing.is_empty() {
            self.status = None;
            return Ok(());
        }
        let names: Vec<&str> = missing.iter().map(|e| e.name.as_str()).collect();
        self.status = Some(format!("not yet active on: {}", names.join(", ")));
        if missing.iter().any(|e| !self.asked.contains(&e.id)) {
            self.asked.extend(missing.iter().map(|e| e.id.clone()));
            super::apo_reg::request_register()?;
        }
        Ok(())
    }

    fn status(&self) -> Option<String> {
        self.status.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::Mode;

    #[test]
    fn graphic_text_has_ten_peaks_and_preamps() {
        let mut s = Settings::default();
        s.band_db[0] = 6.0;
        s.boost_db = 6.0;
        s.balance = 0.5;
        let t = config_text(&s, true);
        assert_eq!(t.matches("Filter: ON PK").count(), 10);
        assert!(t.contains("Filter: ON PK Fc 31.25 Hz Gain 6.00 dB Q 1.4142"));
        assert!(t.contains("Filter: ON PK Fc 1000 Hz Gain 0.00 dB Q 1.4142"));
        assert!(t.contains("Channel: L\nPreamp: -0.02 dB"), "{t}"); // 6 dB boost, left halved
        assert!(t.contains("Channel: R\nPreamp: 6.00 dB"), "{t}");
    }

    #[test]
    fn mixer_text_uses_shelves() {
        let mut s = Settings { mode: Mode::Mixer, ..Default::default() };
        s.mixer_db = [-26.0, 0.0, 3.0, 6.0];
        let t = config_text(&s, true);
        assert!(t.contains("Filter: ON LSC Fc 100 Hz Gain -26.00 dB Q 0.7070"));
        assert!(t.contains("Filter: ON PK Fc 2500 Hz Gain 3.00 dB Q 0.7000"));
        assert!(t.contains("Filter: ON HSC Fc 8000 Hz Gain 6.00 dB Q 0.7070"));
        assert_eq!(t.matches("Filter:").count(), 4);
        assert!(t.contains("Preamp: 0.00 dB"));
    }

    #[test]
    fn off_writes_no_filters_and_full_balance_is_minus_60() {
        let t = config_text(&Settings::default(), false);
        assert!(!t.contains("Filter:"));
        let s = Settings { balance: 1.0, ..Default::default() };
        assert!(config_text(&s, true).contains("Preamp: -60.00 dB"));
    }

    #[test]
    fn block_goes_first_and_other_lines_stay() {
        let other = "# tool X\nDevice: all\nStage: post-mix\nInclude: x.txt\n";
        let out = with_block(other);
        assert!(out.starts_with("# just an eq (keep at top)\nDevice: all\nInclude: just-an-eq.txt\n"), "{out}");
        assert!(out.ends_with("# tool X\nStage: post-mix\nInclude: x.txt\n"), "{out}");
        assert_eq!(with_block(&out), out, "idempotent");
        // an old append-style include moves to the top
        let old = "Preamp: -1 dB\nInclude: just-an-eq.txt\n";
        assert_eq!(with_block(old), "# just an eq (keep at top)\nDevice: all\nInclude: just-an-eq.txt\nPreamp: -1 dB\n");
    }

    #[test]
    fn install_writes_filter_file_and_config() {
        let dir = std::env::temp_dir().join(format!("jeq-apo-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("config.txt"), "Preamp: -1 dB").unwrap();
        install(&dir, "a\n").unwrap();
        install(&dir, "b\n").unwrap();
        let main = std::fs::read_to_string(dir.join("config.txt")).unwrap();
        assert_eq!(main, "# just an eq (keep at top)\nDevice: all\nInclude: just-an-eq.txt\nPreamp: -1 dB\n");
        assert_eq!(std::fs::read_to_string(dir.join(FILE)).unwrap(), "b\n");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
