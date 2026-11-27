use std::env;
use std::ffi::OsStr;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

type Result<T> = std::result::Result<T, String>;
const REPO: &str = "P4suta/Test-Mutation";
const BOT: &str = "github-actions[bot]";

fn required(name: &str) -> Result<String> {
    env::var(name).map_err(|_| format!("missing {name}"))
}

fn digest(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f'))
}

fn perl_version(tag: &str) -> Option<String> {
    let components: Vec<_> = tag.strip_prefix('v')?.split('.').collect();
    let [major, minor, patch] = components.as_slice() else {
        return None;
    };
    let number = |s: &str| {
        let parsed = s.parse::<u32>().ok()?;
        (s == parsed.to_string()).then_some(parsed)
    };
    let (major, minor, patch) = (number(major)?, number(minor)?, number(patch)?);
    if minor > 999 || patch > 999 {
        return None;
    }
    let mut decimal = format!("{major}.{minor:03}");
    if patch != 0 {
        decimal.push_str(&format!("{patch:03}"));
    }
    Some(decimal)
}

fn output(program: &str, args: &[&str]) -> Result<String> {
    let result = Command::new(program)
        .args(args)
        .output()
        .map_err(|e| format!("{program}: {e}"))?;
    if !result.status.success() {
        return Err(format!(
            "{program} {} failed ({})",
            args.first().unwrap_or(&""),
            result.status
        ));
    }
    String::from_utf8(result.stdout).map_err(|_| format!("{program} returned invalid text"))
}

fn sha256(path: &Path) -> Result<String> {
    let name = path.to_str().ok_or("invalid archive path")?;
    let result = output("shasum", &["-a", "256", "--", name])?;
    let value = result.split_whitespace().next().unwrap_or("");
    if digest(value, 64) {
        Ok(value.to_owned())
    } else {
        Err("invalid SHA-256 output".into())
    }
}

struct Candidate {
    sha: String,
    tag: String,
    id: String,
    archive: String,
    checksum: String,
    candidate_dir: PathBuf,
    staging_dir: PathBuf,
}

struct Asset {
    id: u64,
    digest: String,
}

struct Release {
    draft: bool,
    archive: Option<Asset>,
    receipt: Option<Asset>,
}

impl Candidate {
    fn from_env() -> Result<Self> {
        let sha = required("CPAN_SOURCE_SHA")?;
        let tag = required("CPAN_TAG")?;
        let id = required("CPAN_RELEASE_ID")?;
        let version = required("CPAN_VERSION")?;
        let checksum = required("CPAN_ARCHIVE_SHA256")?;
        if required("GITHUB_REPOSITORY")? != REPO || !digest(&sha, 40) || !digest(&checksum, 64) {
            return Err("invalid release repository, source or checksum".into());
        }
        if id
            .parse::<u64>()
            .ok()
            .filter(|n| *n != 0)
            .map(|n| n.to_string())
            .as_deref()
            != Some(&id)
            || perl_version(&tag).as_deref() != Some(&version)
        {
            return Err("release ID, tag and Perl version must identify a stable release".into());
        }
        Ok(Self {
            sha,
            tag,
            id,
            checksum,
            archive: format!("Test-Mutation-{version}.tar.gz"),
            candidate_dir: required("CPAN_CANDIDATE_DIR")?.into(),
            staging_dir: required("CPAN_STAGING_DIR")?.into(),
        })
    }

    fn receipt(&self) -> String {
        format!("{}.sha256", self.archive)
    }

    fn read_release(&self) -> Result<Release> {
        let base = format!("repos/{REPO}/releases/{}", self.id);
        let response = output(
            "gh",
            &[
                "api",
                &base,
                "--jq",
                "[.tag_name,.target_commitish,.draft,.id]|@tsv",
            ],
        )?;
        let parts: Vec<_> = response.trim_end().split('\t').collect();
        let [tag, source, state, id] = parts.as_slice() else {
            return Err("invalid GitHub release".into());
        };
        if *tag != self.tag
            || *source != self.sha
            || *id != self.id
            || !matches!(*state, "true" | "false")
        {
            return Err("the draft does not match the selected release".into());
        }
        let tagged = output(
            "gh",
            &[
                "api",
                &format!("repos/{REPO}/git/ref/tags/{}", self.tag),
                "--jq",
                "[.object.type,.object.sha]|@tsv",
            ],
        )?;
        if tagged.trim_end().split_once('\t') != Some(("commit", self.sha.as_str())) {
            return Err("the release tag points to another commit".into());
        }
        let mut release = Release {
            draft: *state == "true",
            archive: None,
            receipt: None,
        };
        let assets = output(
            "gh",
            &[
                "api",
                &format!("{base}/assets"),
                "--paginate",
                "--jq",
                ".[]|[.id,.name,.digest,.label,.uploader.login,.state]|@tsv",
            ],
        )?;
        let receipt = self.receipt();
        for row in assets.lines() {
            let fields: Vec<_> = row.split('\t').collect();
            let [id, name, hash, label, login, uploaded] = fields.as_slice() else {
                return Err("invalid GitHub asset".into());
            };
            let hash = hash.strip_prefix("sha256:").filter(|v| digest(v, 64));
            let Some(hash) = hash else {
                return Err("asset has no verified SHA-256".into());
            };
            if *label != self.sha || *login != BOT || *uploaded != "uploaded" {
                return Err(format!("unexpected origin of {name}"));
            }
            let destination = if *name == self.archive {
                &mut release.archive
            } else if *name == receipt {
                &mut release.receipt
            } else {
                return Err(format!("unexpected release asset {name}"));
            };
            if destination.is_some() {
                return Err(format!("duplicate release asset {name}"));
            }
            *destination = Some(Asset {
                id: id.parse().map_err(|_| "invalid asset ID")?,
                digest: hash.to_owned(),
            });
        }
        if release.receipt.is_none()
            && release
                .archive
                .as_ref()
                .is_some_and(|asset| asset.digest != self.checksum)
        {
            return Err("the unreserved archive differs from the verified candidate".into());
        }
        Ok(release)
    }

    fn upload(&self, path: &Path) -> Result<()> {
        let asset = format!(
            "{}#{}",
            path.to_str().ok_or("invalid asset path")?,
            self.sha
        );
        output(
            "gh",
            &["release", "upload", &self.tag, &asset, "--repo", REPO],
        )
        .map(|_| ())
    }

    fn download(&self, asset: &Asset, path: &Path) -> Result<()> {
        let fd = File::create(path).map_err(|e| e.to_string())?;
        let status = Command::new("gh")
            .args([
                "api",
                &format!("repos/{REPO}/releases/assets/{}", asset.id),
                "-H",
                "Accept: application/octet-stream",
            ])
            .stdout(Stdio::from(fd))
            .status()
            .map_err(|e| e.to_string())?;
        if status.success() {
            Ok(())
        } else {
            Err("cannot download the original release asset".into())
        }
    }

    fn check_receipt(&self, release: &Release, hash: &str) -> Result<()> {
        let receipt = self.staging_dir.join(self.receipt());
        fs::write(&receipt, format!("{hash}  {}\n", self.archive)).map_err(|e| e.to_string())?;
        if let Some(asset) = &release.receipt {
            if asset.digest != sha256(&receipt)? {
                return Err("the uploaded checksum names different bytes".into());
            }
        } else if !release.draft {
            return Err("the public release lacks its checksum".into());
        }
        Ok(())
    }

    fn stage(&self) -> Result<()> {
        let candidate = self.candidate_dir.join(&self.archive);
        if sha256(&candidate)? != self.checksum {
            return Err("candidate archive checksum mismatch".into());
        }
        let mut release = self.read_release()?;
        if release.archive.is_none() {
            if !release.draft || release.receipt.is_some() {
                return Err("release contains an incomplete upload".into());
            }
            self.upload(&candidate)?;
            release = self.read_release()?;
            if release.archive.as_ref().map(|a| &a.digest) != Some(&self.checksum) {
                return Err("GitHub did not retain the verified bytes".into());
            }
        }
        let archive = release.archive.as_ref().ok_or("missing release archive")?;
        fs::create_dir_all(&self.staging_dir).map_err(|e| e.to_string())?;
        let staged = self.staging_dir.join(&self.archive);
        if archive.digest == self.checksum {
            fs::copy(candidate, &staged).map_err(|e| e.to_string())?;
        } else {
            self.download(archive, &staged)?;
        }
        if sha256(&staged)? != archive.digest {
            return Err("staged archive differs from its original bytes".into());
        }
        self.check_receipt(&release, &archive.digest)?;
        println!("sha256={}", archive.digest);
        println!(
            "action={}",
            if release.receipt.is_some() {
                "reconcile"
            } else {
                "prepare"
            }
        );
        Ok(())
    }

    fn submission(&self, finish: bool) -> Result<()> {
        let release = self.read_release()?;
        let archive = release
            .archive
            .as_ref()
            .ok_or("cannot submit without a verified draft archive")?;
        let staged = self.staging_dir.join(&self.archive);
        if sha256(&staged)? != archive.digest {
            return Err("staged bytes do not match the attached archive".into());
        }
        self.check_receipt(&release, &archive.digest)?;
        if !finish {
            if release.receipt.is_some() {
                println!("action=reconcile");
                return Ok(());
            }
            self.upload(&self.staging_dir.join(self.receipt()))?;
            let reserved = self.read_release()?;
            if reserved.receipt.is_none() || !reserved.draft {
                return Err("upload reservation is missing".into());
            }
            if reserved.archive.as_ref().map(|a| &a.digest) != Some(&archive.digest) {
                return Err("the attached archive changed during reservation".into());
            }
            self.check_receipt(&reserved, &archive.digest)?;
            println!("action=submit");
            return Ok(());
        }
        if release.receipt.is_none() {
            return Err("cannot publish without a reserved submission".into());
        }
        let status = Command::new("pause")
            .args([
                OsStr::new("reconcile"),
                staged.as_os_str(),
                OsStr::new(&archive.digest),
            ])
            .status()
            .map_err(|e| e.to_string())?;
        if !status.success() {
            return Err("the registry has not confirmed the original bytes".into());
        }
        if release.draft {
            output(
                "gh",
                &[
                    "release",
                    "edit",
                    &self.tag,
                    "--draft=false",
                    "--repo",
                    REPO,
                ],
            )?;
            if self.read_release()?.draft {
                return Err("GitHub did not publish the release".into());
            }
        }
        Ok(())
    }
}

fn run() -> Result<()> {
    let candidate = Candidate::from_env()?;
    match env::args().nth(1).as_deref() {
        Some("stage") => candidate.stage(),
        Some("claim") => candidate.submission(false),
        Some("finish") => candidate.submission(true),
        _ => Err("expected stage, claim or finish".into()),
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("draft: {error}");
            ExitCode::FAILURE
        }
    }
}
