//! Linux: a PipeWire filter-chain sink does the DSP. The app writes a drop-in,
//! runs `pipewire -c filter-chain.conf` as a child (the sink lives as long as the
//! child), makes the sink the default and sets the biquad gains through
//! `pw-cli s <node> Props`. The filter's output is pinned to the real device.

use super::Backend;
use crate::params::{self, Shape, SLOTS};
use crate::settings::Settings;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

pub const SINK: &str = "just_an_eq.desktop";
pub const OUT: &str = "just_an_eq.desktop.out";
const DROPIN: &str = "just-an-eq.conf";

fn node_name(side: char, slot: usize) -> String {
    format!("{side}{slot}")
}

pub fn config_text(target: &str) -> String {
    let mut nodes = String::new();
    let mut links = String::new();
    for side in ['l', 'r'] {
        for slot in 0..SLOTS {
            let b = params::band(slot);
            let label = match b.shape {
                Shape::Peak => "bq_peaking",
                Shape::LowShelf => "bq_lowshelf",
                Shape::HighShelf => "bq_highshelf",
            };
            nodes.push_str(&format!(
                "          {{ type = builtin name = {} label = {label} control = {{ \"Freq\" = {:.2} \"Q\" = {:.4} \"Gain\" = 0.0 }} }}\n",
                node_name(side, slot),
                b.freq,
                b.q
            ));
            if slot + 1 < SLOTS {
                links.push_str(&format!(
                    "          {{ output = \"{}:Out\" input = \"{}:In\" }}\n",
                    node_name(side, slot),
                    node_name(side, slot + 1)
                ));
            }
        }
        nodes.push_str(&format!(
            "          {{ type = builtin name = {side}g label = mixer control = {{ \"Gain 1\" = 1.0 }} }}\n"
        ));
        links.push_str(&format!(
            "          {{ output = \"{}:Out\" input = \"{side}g:In 1\" }}\n",
            node_name(side, SLOTS - 1)
        ));
    }
    format!(
        "# written by just an eq; loaded only by its own `pipewire -c filter-chain.conf` child\n\
context.modules = [\n\
  {{ name = libpipewire-module-filter-chain\n\
    args = {{\n\
      node.description = \"just an eq\"\n\
      media.name       = \"just an eq\"\n\
      filter.graph = {{\n\
        nodes = [\n{nodes}        ]\n\
        links = [\n{links}        ]\n\
        inputs  = [ \"l0:In\" \"r0:In\" ]\n\
        outputs = [ \"lg:Out\" \"rg:Out\" ]\n\
      }}\n\
      audio.channels = 2\n\
      audio.position = [ FL FR ]\n\
      capture.props  = {{ node.name = \"{SINK}\" media.class = Audio/Sink }}\n\
      playback.props = {{ node.name = \"{OUT}\" node.passive = true target.object = \"{target}\" }}\n\
    }}\n\
  }}\n\
]\n"
    )
}

pub fn params_text(s: &Settings) -> String {
    let gains = params::effective_gains(s);
    let (left, right) = params::channel_gains(s);
    let mut p = String::from("{ params = [");
    for side in ['l', 'r'] {
        for (slot, g) in gains.iter().enumerate() {
            p.push_str(&format!(" \"{}:Gain\" {g:.2}", node_name(side, slot)));
        }
    }
    p.push_str(&format!(" \"lg:Gain 1\" {left:.4} \"rg:Gain 1\" {right:.4} ] }}"));
    p
}

fn run(cmd: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(cmd).args(args).output().map_err(|e| format!("{cmd}: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!("{cmd} {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()))
    }
}

fn find_node(name: &str) -> Option<u32> {
    let dump = run("pw-dump", &[]).ok()?;
    let objects: Vec<serde_json::Value> = serde_json::from_str(&dump).ok()?;
    objects
        .iter()
        .find(|o| o["info"]["props"]["node.name"].as_str() == Some(name))
        .and_then(|o| o["id"].as_u64())
        .map(|id| id as u32)
}

fn default_sink_name() -> Option<String> {
    let text = run("wpctl", &["inspect", "@DEFAULT_AUDIO_SINK@"]).ok()?;
    text.lines()
        .map(|l| l.trim().trim_start_matches('*').trim())
        .find_map(|l| l.strip_prefix("node.name = \""))
        .map(|rest| rest.trim_end_matches('"').to_string())
}

/// The graph takes control changes only after audio has flowed once.
fn warm_up() {
    let child = Command::new("pw-cat")
        .args(["--playback", "--raw", "--format", "s16", "--rate", "48000", "--channels", "2", "--target", SINK, "/dev/zero"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    if let Ok(mut c) = child {
        std::thread::sleep(Duration::from_millis(300));
        let _ = c.kill();
        let _ = c.wait();
    }
}

fn dropin_path() -> Result<PathBuf, String> {
    let dir = dirs::config_dir().ok_or("no config dir")?.join("pipewire").join("filter-chain.conf.d");
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    Ok(dir.join(DROPIN))
}

#[derive(Default)]
pub struct PipeWire {
    child: Option<Child>,
    node: Option<u32>,
    /// The hardware sink the filter plays to; restored as default when switching Off.
    target: Option<String>,
    last_tick: Option<Instant>,
}

impl PipeWire {
    fn start(&mut self) -> Result<(), String> {
        if self.child.is_some() {
            return Ok(());
        }
        let target = default_sink_name().ok_or("no output device")?;
        if target == SINK {
            return Err("the EQ sink is already the default; pick a real output first".into());
        }
        std::fs::write(dropin_path()?, config_text(&target)).map_err(|e| e.to_string())?;
        let mut cmd = Command::new("pipewire");
        cmd.args(["-c", "filter-chain.conf"]).stdout(Stdio::null()).stderr(Stdio::null());
        // Take the sink down with us if the app dies.
        unsafe {
            use std::os::unix::process::CommandExt;
            cmd.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
        let child = cmd.spawn().map_err(|e| format!("pipewire: {e}"))?;
        self.child = Some(child);
        let deadline = Instant::now() + Duration::from_secs(3);
        while self.node.is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(100));
            self.node = find_node(SINK);
        }
        let Some(node) = self.node else {
            self.stop();
            return Err("the EQ sink did not appear".into());
        };
        warm_up();
        run("wpctl", &["set-default", &node.to_string()])?;
        self.target = Some(target);
        Ok(())
    }

    fn stop(&mut self) {
        if let Some(name) = self.target.take() {
            if let Some(id) = find_node(&name) {
                let _ = run("wpctl", &["set-default", &id.to_string()]);
            }
        }
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.node = None;
        if let Ok(p) = dropin_path() {
            let _ = std::fs::remove_file(p);
        }
    }

    fn set_params(&self, settings: &Settings) -> Result<(), String> {
        let node = self.node.ok_or("EQ sink is not running")?;
        run("pw-cli", &["s", &node.to_string(), "Props", &params_text(settings)]).map(|_| ())
    }
}

impl Backend for PipeWire {
    fn apply(&mut self, settings: &Settings, enabled: bool) -> Result<(), String> {
        if !enabled {
            self.stop();
            return Ok(());
        }
        self.start()?;
        self.set_params(settings)
    }

    /// Follow the user's output choice: if they picked another hardware device
    /// while On, move the filter's output there and make the EQ default again.
    fn tick(&mut self, _settings: &Settings, enabled: bool) -> Result<(), String> {
        if !enabled || self.child.is_none() {
            return Ok(());
        }
        if self.last_tick.is_some_and(|t| t.elapsed() < Duration::from_secs(2)) {
            return Ok(());
        }
        self.last_tick = Some(Instant::now());
        if let Some(child) = self.child.as_mut() {
            if child.try_wait().ok().flatten().is_some() {
                self.stop();
                return Err("the EQ sink stopped".into());
            }
        }
        let Some(current) = default_sink_name() else { return Ok(()) };
        if current == SINK || self.target.as_deref() == Some(&current) {
            return Ok(());
        }
        let stream = find_node(OUT).ok_or("EQ output stream missing")?;
        run("pw-metadata", &[&stream.to_string(), "target.object", &current])?;
        if let Some(node) = self.node {
            run("wpctl", &["set-default", &node.to_string()])?;
        }
        self.target = Some(current);
        Ok(())
    }

}

impl Drop for PipeWire {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::Mode;

    #[test]
    fn config_has_two_channels_of_fourteen_biquads() {
        let t = config_text("alsa_output.test");
        assert_eq!(t.matches("label = bq_").count(), 28);
        assert_eq!(t.matches("label = mixer").count(), 2);
        assert!(t.contains("name = l10 label = bq_lowshelf control = { \"Freq\" = 100.00 \"Q\" = 0.7070"));
        assert!(t.contains("name = r13 label = bq_highshelf control = { \"Freq\" = 8000.00"));
        assert!(t.contains("{ output = \"l13:Out\" input = \"lg:In 1\" }"));
        assert!(t.contains("target.object = \"alsa_output.test\""));
        assert!(t.contains("inputs  = [ \"l0:In\" \"r0:In\" ]"));
    }

    #[test]
    fn params_cover_both_sides_and_gains() {
        let mut s = Settings { mode: Mode::Mixer, ..Default::default() };
        s.mixer_db[0] = -26.0;
        s.boost_db = 6.0;
        let p = params_text(&s);
        assert!(p.starts_with("{ params = ["));
        assert!(p.contains("\"l10:Gain\" -26.00") && p.contains("\"r10:Gain\" -26.00"));
        assert!(p.contains("\"l0:Gain\" 0.00"));
        assert!(p.contains("\"lg:Gain 1\" 1.9953 \"rg:Gain 1\" 1.9953 ] }"));
    }

    /// Needs a running PipeWire with WirePlumber. `cargo test -- --ignored pipewire`.
    #[test]
    #[ignore]
    fn pipewire_end_to_end() {
        let before = default_sink_name().expect("a default sink");
        let mut pw = PipeWire::default();
        let mut s = Settings::default();
        s.band_db[0] = 7.5;
        pw.apply(&s, true).expect("start and set params");
        assert_eq!(default_sink_name().as_deref(), Some(SINK));
        let node = pw.node.unwrap();
        let dump = run("pw-dump", &[&node.to_string()]).unwrap();
        assert!(dump.contains("\"l0:Gain\",\n              7.5") || dump.contains("\"l0:Gain\", 7.5") || dump.contains("7.500000"), "{dump}");
        pw.apply(&s, false).unwrap();
        assert!(find_node(SINK).is_none());
        assert_eq!(default_sink_name(), Some(before));
    }
}
