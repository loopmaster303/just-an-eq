//! A 32x32 RGBA tray icon drawn in code: dark disc with three EQ bars.

pub const SIZE: u32 = 32;

pub fn rgba() -> Vec<u8> {
    let n = SIZE as i32;
    let mut px = vec![0u8; (SIZE * SIZE * 4) as usize];
    let c = (n - 1) as f32 / 2.0;
    let bars = [(8, 20), (14, 12), (20, 24)]; // (x, height) in px
    for y in 0..n {
        for x in 0..n {
            let d = ((x as f32 - c).powi(2) + (y as f32 - c).powi(2)).sqrt();
            let i = ((y * n + x) * 4) as usize;
            if d > c {
                continue;
            }
            let on_bar = bars.iter().any(|&(bx, h)| x >= bx && x < bx + 4 && y >= 26 - h && y < 26);
            let (r, g, b) = if on_bar { (240, 240, 240) } else { (28, 28, 30) };
            px[i..i + 4].copy_from_slice(&[r, g, b, 255]);
        }
    }
    px
}

#[cfg(test)]
mod tests {
    #[test]
    fn icon_has_corners_transparent_and_bars_white() {
        let px = super::rgba();
        assert_eq!(px.len(), 32 * 32 * 4);
        assert_eq!(px[3], 0);
        let i = ((20 * 32) + 9) * 4;
        assert_eq!(&px[i..i + 3], &[240, 240, 240]);
    }
}
