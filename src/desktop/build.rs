//! Bundles the Equalizer APO installer into the Windows build when
//! `windows/EqualizerAPO-x64-1.4.2.exe` is present (download it from
//! https://sourceforge.net/projects/equalizerapo/). Without it the build
//! still works, but `--install` cannot set up Equalizer APO.

use std::path::Path;

fn main() {
    let src = Path::new("windows/EqualizerAPO-x64-1.4.2.exe");
    let out = Path::new(&std::env::var("OUT_DIR").unwrap()).join("EqualizerAPO64.exe");
    println!("cargo:rerun-if-changed={}", src.display());
    if src.exists() {
        std::fs::copy(src, &out).expect("copy Equalizer APO installer");
    } else {
        std::fs::write(&out, b"").expect("write placeholder");
        println!("cargo:warning=windows/EqualizerAPO-x64-1.4.2.exe missing: --install will not set up Equalizer APO");
    }
}
