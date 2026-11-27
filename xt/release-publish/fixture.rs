#[allow(dead_code)]
#[path = "pause.rs"]
mod pause;

fn main() -> std::process::ExitCode {
    let origin = std::env::var("PAUSE_FIXTURE").expect("local server address");
    pause::run(&format!("{origin}/api/upload"), &origin, &origin, "=http")
}
