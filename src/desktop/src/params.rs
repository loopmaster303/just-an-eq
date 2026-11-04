//! Parameter table mirrored from `src/JustAnEQCore/Equalizer.swift` and `Preset.swift`.
//! Slots 0-9: graphic octave peaks. Slots 10-13: mixer LF, Lo-Mid, Hi-Mid, HF.

use crate::settings::{Mode, Settings};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Shape {
    Peak,
    LowShelf,
    HighShelf,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Band {
    pub freq: f64,
    pub q: f64,
    pub shape: Shape,
}

pub const SLOTS: usize = 14;
pub const GRAPHIC_RANGE: (f32, f32) = (-12.0, 12.0);
pub const MIXER_RANGE: (f32, f32) = (-26.0, 6.0);
pub const MIXER_NAMES: [&str; 4] = ["LF", "LO-MID", "HI-MID", "HF"];
pub const GRAPHIC_LABELS: [&str; 10] = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"];

const GRAPHIC_FREQ: [f64; 10] = [31.25, 62.5, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

pub fn band(slot: usize) -> Band {
    match slot {
        0..=9 => Band { freq: GRAPHIC_FREQ[slot], q: std::f64::consts::SQRT_2, shape: Shape::Peak },
        10 => Band { freq: 100.0, q: 0.707, shape: Shape::LowShelf },
        11 => Band { freq: 400.0, q: 0.7, shape: Shape::Peak },
        12 => Band { freq: 2500.0, q: 0.7, shape: Shape::Peak },
        _ => Band { freq: 8000.0, q: 0.707, shape: Shape::HighShelf },
    }
}

/// Gain per slot in dB; the inactive mode's slots are flat.
pub fn effective_gains(s: &Settings) -> [f32; SLOTS] {
    let mut g = [0.0; SLOTS];
    match s.mode {
        Mode::Graphic => g[..10].copy_from_slice(&s.band_db),
        Mode::Mixer => g[10..].copy_from_slice(&s.mixer_db),
    }
    g
}

/// Linear left/right gains from boost and balance, as in `EQState.configure`.
pub fn channel_gains(s: &Settings) -> (f32, f32) {
    let boost = 10f32.powf(s.boost_db.clamp(0.0, 12.0) / 20.0);
    let balance = s.balance.clamp(-1.0, 1.0);
    (boost * (1.0 - balance.max(0.0)), boost * (1.0 + balance.min(0.0)))
}

pub const PRESETS: [(&str, [f32; 10]); 3] = [
    ("Flat", [0.0; 10]),
    ("Bass Focus", [4.0, 4.0, 3.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
    ("Mids-Treble Focus", [0.0, 0.0, 0.0, 0.0, 1.0, 3.0, 4.0, 4.0, 3.0, 2.0]),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slots_match_swift_table() {
        assert_eq!(band(0).freq, 31.25);
        assert_eq!(band(9).freq, 16000.0);
        assert_eq!(band(10).shape, Shape::LowShelf);
        assert_eq!(band(13).shape, Shape::HighShelf);
        assert_eq!(band(11).q, 0.7);
    }

    #[test]
    fn inactive_mode_is_flat() {
        let mut s = Settings::default();
        s.band_db[0] = 5.0;
        s.mixer_db[0] = -10.0;
        s.mode = Mode::Graphic;
        assert_eq!(effective_gains(&s)[0], 5.0);
        assert_eq!(effective_gains(&s)[10], 0.0);
        s.mode = Mode::Mixer;
        assert_eq!(effective_gains(&s)[0], 0.0);
        assert_eq!(effective_gains(&s)[10], -10.0);
    }

    #[test]
    fn balance_attenuates_one_side() {
        let mut s = Settings::default();
        s.balance = 0.5;
        let (l, r) = channel_gains(&s);
        assert!((l - 0.5).abs() < 1e-6 && (r - 1.0).abs() < 1e-6);
        s.boost_db = 6.0;
        s.balance = -1.0;
        let (l, r) = channel_gains(&s);
        assert!((l - 1.9953).abs() < 1e-3 && r.abs() < 1e-6);
    }
}
