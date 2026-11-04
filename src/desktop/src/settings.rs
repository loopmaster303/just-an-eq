//! Settings with the same JSON schema as the macOS app (`justaneq.settings.v1`):
//! `{"settings":{"balance","boostDB","bandDB":[10],"mode","mixerDB":[4]},"preset"}`.
//! Decoding is tolerant: values are clamped, non-finite values become 0, lists are padded.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Mixer,
    Graphic,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Settings {
    pub balance: f32,
    pub boost_db: f32,
    pub band_db: [f32; 10],
    pub mode: Mode,
    pub mixer_db: [f32; 4],
}

impl Default for Settings {
    fn default() -> Self {
        Settings { balance: 0.0, boost_db: 0.0, band_db: [0.0; 10], mode: Mode::Graphic, mixer_db: [0.0; 4] }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Raw {
    balance: Option<f32>,
    #[serde(rename = "boostDB")]
    boost_db: Option<f32>,
    #[serde(rename = "bandDB")]
    band_db: Option<Vec<f32>>,
    mode: Option<Mode>,
    #[serde(rename = "mixerDB")]
    mixer_db: Option<Vec<f32>>,
}

fn clean(v: Option<f32>, lo: f32, hi: f32) -> f32 {
    match v {
        Some(x) if x.is_finite() => x.clamp(lo, hi),
        _ => 0.0,
    }
}

impl From<Raw> for Settings {
    fn from(r: Raw) -> Self {
        let mut s = Settings { balance: clean(r.balance, -1.0, 1.0), boost_db: clean(r.boost_db, 0.0, 12.0), ..Default::default() };
        let bands = r.band_db.unwrap_or_default();
        for (i, b) in s.band_db.iter_mut().enumerate() {
            *b = clean(bands.get(i).copied(), -12.0, 12.0);
        }
        let mixer = r.mixer_db.unwrap_or_default();
        for (i, m) in s.mixer_db.iter_mut().enumerate() {
            *m = clean(mixer.get(i).copied(), -26.0, 6.0);
        }
        s.mode = r.mode.unwrap_or(Mode::Graphic);
        s
    }
}

impl Serialize for Settings {
    fn serialize<S: serde::Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        Raw {
            balance: Some(self.balance),
            boost_db: Some(self.boost_db),
            band_db: Some(self.band_db.to_vec()),
            mode: Some(self.mode),
            mixer_db: Some(self.mixer_db.to_vec()),
        }
        .serialize(ser)
    }
}

impl<'de> Deserialize<'de> for Settings {
    fn deserialize<D: serde::Deserializer<'de>>(de: D) -> Result<Self, D::Error> {
        Raw::deserialize(de).map(Settings::from)
    }
}

/// What is persisted. Never stores the On/Off state: the EQ always starts Off.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Stored {
    pub settings: Settings,
    pub preset: Option<String>,
}

pub fn path() -> Option<PathBuf> {
    dirs::config_dir().map(|d| d.join("just-an-eq").join("settings.json"))
}

pub fn load() -> Stored {
    path()
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(Stored { settings: Settings::default(), preset: Some("Flat".into()) })
}

pub fn save(stored: &Stored) -> Result<(), String> {
    let p = path().ok_or("no config dir")?;
    if let Some(dir) = p.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_vec_pretty(stored).map_err(|e| e.to_string())?;
    std::fs::write(p, json).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_uses_macos_keys() {
        let mut s = Settings::default();
        s.band_db[3] = 2.5;
        s.mixer_db[0] = -26.0;
        s.mode = Mode::Mixer;
        let json = serde_json::to_string(&Stored { settings: s.clone(), preset: Some("Flat".into()) }).unwrap();
        assert!(json.contains("\"boostDB\"") && json.contains("\"bandDB\"") && json.contains("\"mixerDB\""));
        assert!(json.contains("\"mode\":\"mixer\""));
        let back: Stored = serde_json::from_str(&json).unwrap();
        assert_eq!(back.settings, s);
    }

    #[test]
    fn tolerant_decoding() {
        let json = r#"{"settings":{"balance":7,"boostDB":-3,"bandDB":[99,-99],"mode":"nonsense"}}"#;
        let err = serde_json::from_str::<Stored>(json);
        assert!(err.is_err(), "unknown mode is an error, like Swift falls back");
        let json = r#"{"settings":{"balance":7,"boostDB":-3,"bandDB":[99,-99]},"preset":null}"#;
        let s = serde_json::from_str::<Stored>(json).unwrap().settings;
        assert_eq!(s.balance, 1.0);
        assert_eq!(s.boost_db, 0.0);
        assert_eq!(&s.band_db[..3], &[12.0, -12.0, 0.0]);
        assert_eq!(s.mode, Mode::Graphic);
        assert_eq!(s.mixer_db, [0.0; 4]);
    }
}
