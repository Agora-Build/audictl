use std::ffi::{OsStr, OsString};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use serde_json::Value;

use crate::error::{AudictlError, Result};

#[derive(Clone, Debug)]
pub struct Backend {
    config_home: PathBuf,
}

impl Backend {
    pub fn discover() -> Result<Self> {
        let config_home = match std::env::var_os("XDG_CONFIG_HOME") {
            Some(path) => PathBuf::from(path),
            None => home_dir()?.join(".config"),
        };
        Ok(Self { config_home })
    }

    #[cfg(test)]
    pub fn at(config_home: PathBuf) -> Self {
        Self { config_home }
    }

    pub fn config_home(&self) -> &Path {
        &self.config_home
    }

    pub fn program_path(&self, program: &str) -> Result<PathBuf> {
        let path = std::env::var_os("PATH")
            .ok_or_else(|| AudictlError::Internal("PATH is not set".to_owned()))?;
        std::env::split_paths(&path)
            .map(|directory| directory.join(program))
            .find(|candidate| candidate.is_file())
            .ok_or_else(|| AudictlError::MissingDependency(program.to_owned()))
    }

    pub fn run<I, S>(&self, program: &str, args: I) -> Result<String>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let args: Vec<OsString> = args
            .into_iter()
            .map(|arg| arg.as_ref().to_os_string())
            .collect();
        let output = Command::new(program)
            .args(&args)
            .output()
            .map_err(|error| match error.kind() {
                std::io::ErrorKind::NotFound => AudictlError::MissingDependency(program.to_owned()),
                _ => AudictlError::Internal(format!("could not run {program}: {error}")),
            })?;
        output_result(program, &args, output)
    }

    pub fn pactl_json(&self, kind: &str) -> Result<Value> {
        let raw = self.run("pactl", ["-f", "json", "list", kind])?;
        serde_json::from_str(&raw)
            .map_err(|error| AudictlError::Internal(format!("invalid pactl JSON: {error}")))
    }

    pub fn ensure_pipewire(&self) -> Result<()> {
        let info = self.run("pactl", ["info"])?;
        if info.lines().any(|line| {
            line.starts_with("Server Name:") && line.to_ascii_lowercase().contains("pipewire")
        }) {
            Ok(())
        } else {
            Err(AudictlError::Unsupported(
                "this operation requires PipeWire; native PulseAudio is not supported".to_owned(),
            ))
        }
    }

    pub fn write_if_changed(&self, path: &Path, content: &str) -> Result<bool> {
        if fs::read_to_string(path).ok().as_deref() == Some(content) {
            return Ok(false);
        }
        let parent = path
            .parent()
            .ok_or_else(|| AudictlError::Internal(format!("invalid path: {}", path.display())))?;
        fs::create_dir_all(parent).map_err(|error| {
            AudictlError::Internal(format!("could not create {}: {error}", parent.display()))
        })?;
        fs::write(path, content).map_err(|error| {
            AudictlError::Internal(format!("could not write {}: {error}", path.display()))
        })?;
        Ok(true)
    }

    pub fn remove_if_exists(&self, path: &Path) -> Result<bool> {
        match fs::remove_file(path) {
            Ok(()) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(AudictlError::Internal(format!(
                "could not remove {}: {error}",
                path.display()
            ))),
        }
    }
}

fn output_result(program: &str, args: &[OsString], output: Output) -> Result<String> {
    if output.status.success() {
        return String::from_utf8(output.stdout)
            .map_err(|error| AudictlError::Internal(format!("invalid {program} output: {error}")));
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    let operation = std::iter::once(OsStr::new(program))
        .chain(args.iter().map(OsString::as_os_str))
        .map(|part| part.to_string_lossy())
        .collect::<Vec<_>>()
        .join(" ");
    Err(AudictlError::CommandFailed {
        operation,
        message: if stderr.is_empty() {
            format!("exit status {}", output.status)
        } else {
            stderr
        },
    })
}

pub fn home_dir() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| AudictlError::Internal("HOME is not set".to_owned()))
}

pub fn slug(raw: &str) -> String {
    let mut out = String::new();
    let mut separator = false;
    for character in raw.chars().flat_map(char::to_lowercase) {
        if character.is_ascii_alphanumeric() {
            out.push(character);
            separator = false;
        } else if !out.is_empty() && !separator {
            out.push('_');
            separator = true;
        }
    }
    while out.ends_with('_') {
        out.pop();
    }
    if out.is_empty() {
        "audio".to_owned()
    } else {
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_is_stable_and_safe() {
        assert_eq!(slug("Audictl Audio Bridge"), "audictl_audio_bridge");
        assert_eq!(slug("  Browser---Bridge  "), "browser_bridge");
        assert_eq!(slug("音声"), "audio");
    }
}
