use std::env;
use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::{Command, ExitCode, Output, Stdio};

type Result<T> = std::result::Result<T, String>;

fn tool(executable: &str) -> Command {
    let mut command = Command::new(executable);
    command.env_clear().env("PATH", "/usr/bin:/bin");
    command
}

fn execute(command: &mut Command, input: &[u8]) -> Result<Output> {
    let executable = command.get_program().to_string_lossy().into_owned();
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Cannot start {executable}: {e}"))?;
    let write = child.stdin.take().unwrap().write_all(input);
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!("{executable} failed ({})", output.status));
    }
    write.map_err(|e| format!("Cannot write to {executable}: {e}"))?;
    Ok(output)
}

fn sha256(bytes: &[u8]) -> Result<String> {
    let output = execute(
        tool("/usr/bin/openssl").args(["dgst", "-sha256", "-binary"]),
        bytes,
    )?;
    if output.stdout.len() != 32 {
        return Err("Unexpected SHA-256 output".into());
    }
    Ok(output
        .stdout
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

struct Archive {
    filename: String,
    digest: String,
    bytes: Vec<u8>,
}

impl Archive {
    fn read(path: &str, expected: &str) -> Result<Self> {
        let path = Path::new(path);
        let filename = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("");
        let version = filename
            .strip_prefix("Test-Mutation-")
            .and_then(|s| s.strip_suffix(".tar.gz"))
            .unwrap_or("");
        let components: Vec<_> = version.split('.').collect();
        if !(2..=3).contains(&components.len())
            || components
                .iter()
                .any(|n| n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit()))
        {
            return Err("Expected a stable Test-Mutation distribution archive".into());
        }
        let bytes = fs::read(path).map_err(|e| format!("Cannot read candidate: {e}"))?;
        if bytes.is_empty() {
            return Err("The candidate archive is empty".into());
        }
        let digest = sha256(&bytes)?;
        if digest != expected {
            return Err("Local archive SHA-256 differs from the approved digest".into());
        }
        Ok(Self {
            filename: filename.to_owned(),
            digest,
            bytes,
        })
    }
}

struct Response {
    status: u16,
    body: Vec<u8>,
}

impl Response {
    fn has_json(&self, condition: &str) -> bool {
        let filter = format!("length == 1 and (.[0] | {condition})");
        execute(
            tool("/usr/bin/jq").args(["--slurp", "--exit-status", &filter]),
            &self.body,
        )
        .is_ok()
    }
}

fn request(protocol: &str, url: &str) -> Result<Response> {
    let mut curl = tool("/usr/bin/curl");
    curl.args([
        "--disable",
        "--proto",
        protocol,
        "--silent",
        "--show-error",
        "--connect-timeout",
        "10",
        "--max-time",
        "60",
        "--write-out",
        "\n%{http_code}",
        "--url",
        url,
    ]);
    let mut body = execute(&mut curl, &[])?.stdout;
    let end = body
        .iter()
        .rposition(|byte| *byte == b'\n')
        .ok_or("Missing HTTP status")?;
    let status = std::str::from_utf8(&body[end + 1..])
        .ok()
        .and_then(|s| s.parse().ok())
        .ok_or("Invalid HTTP status")?;
    body.truncate(end);
    Ok(Response { status, body })
}

enum Outcome {
    Complete(String),
    Missing,
}

fn reconcile(cpan: &str, protocol: &str, archive: &Archive) -> Result<Outcome> {
    let url = format!("{cpan}/authors/id/Y/YA/YASUNOBU/{}", archive.filename);
    let response = request(protocol, &url)?;
    match response.status {
        404 => Ok(Outcome::Missing),
        200 if response.body.len() == archive.bytes.len()
            && sha256(&response.body)? == archive.digest =>
        {
            Ok(Outcome::Complete(format!(
                "Verified {} {url}",
                archive.digest
            )))
        }
        200 => Err(format!(
            "Published archive at {url} differs from the candidate"
        )),
        status => Err(format!("Archive lookup returned HTTP {status}")),
    }
}

fn token() -> Result<String> {
    let input = env::var("PAUSE_TOKEN").unwrap_or_default();
    let fields: Vec<_> = input.split(':').collect();
    let hex = |value: &str, length| {
        value.len() == length
            && value
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    };
    if matches!(fields.as_slice(), ["YASUNOBU", id, secret] if hex(id, 32) && hex(secret, 64)) {
        Ok(input)
    } else {
        Err("PAUSE_TOKEN must contain the complete upload token issued to YASUNOBU".into())
    }
}

fn permissions(metacpan: &str, protocol: &str) -> Result<String> {
    let author = request(protocol, &format!("{metacpan}/author/YASUNOBU"))?;
    if author.status != 200 || !author.has_json(r#".pauseid == "YASUNOBU""#) {
        return Err("Cannot confirm PAUSE account YASUNOBU in MetaCPAN".into());
    }
    let permission = request(protocol, &format!("{metacpan}/permission/Test::Mutation"))?;
    match permission.status {
        404 if permission.has_json(r#".code == 404 and .message == "Not found""#) => {
            Ok("Test::Mutation is unclaimed in the public permission index".into())
        }
        200 if permission.has_json(r#".module_name == "Test::Mutation" and
            (.owner == "YASUNOBU" or (.co_maintainers | type == "array" and any(.[]; . == "YASUNOBU")))"#) => {
            Ok("YASUNOBU holds indexing permission for Test::Mutation".into())
        }
        status => Err(format!("Cannot confirm indexing permission for Test::Mutation (HTTP {status})")),
    }
}

pub(crate) fn run(_pause: &str, cpan: &str, metacpan: &str, protocol: &str) -> ExitCode {
    let args: Vec<_> = env::args().skip(1).collect();
    let outcome = match args.as_slice() {
        [command] if command == "preflight" => token().and_then(|_| permissions(metacpan, protocol)).map(|permission| {
            Outcome::Complete(format!("{permission}. Token format verified locally; PAUSE authentication remains unverified."))
        }),
        [command, path, digest] if command == "reconcile" => {
            Archive::read(path, digest).and_then(|archive| reconcile(cpan, protocol, &archive))
        }
        _ => Err("Usage: pause preflight | pause reconcile ARCHIVE SHA256".into()),
    };
    match outcome {
        Ok(Outcome::Complete(message)) => {
            println!("{message}");
            ExitCode::SUCCESS
        }
        Ok(Outcome::Missing) => {
            eprintln!("The author archive is not visible on CPAN");
            ExitCode::from(3)
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

fn main() -> ExitCode {
    run(
        "https://pause.perl.org/api/upload",
        "https://cpan.metacpan.org",
        "https://fastapi.metacpan.org/v1",
        "=https",
    )
}
