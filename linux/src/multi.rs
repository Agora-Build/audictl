use std::fs;

use serde::{Deserialize, Serialize};

use crate::backend::{Backend, slug};
use crate::device::{self, DeviceKind, SelectorMode};
use crate::error::{AudictlError, Result};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubDevice {
    pub uid: String,
    pub name: Option<String>,
    pub drift_compensation: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MultiOutput {
    pub id: u32,
    pub uid: String,
    pub name: String,
    pub is_multi_output: bool,
    pub is_private: bool,
    pub clock_device_uid: Option<String>,
    pub sub_devices: Vec<SubDevice>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Manifest {
    name: String,
    uid: String,
    primary: String,
    devices: Vec<SubDevice>,
}

#[derive(Debug, Serialize)]
pub struct Destroyed {
    pub uid: Option<String>,
    pub existed: bool,
}

pub fn create(
    backend: &Backend,
    name: &str,
    device_queries: &str,
    primary_query: Option<&str>,
    mode: SelectorMode,
) -> Result<(MultiOutput, bool)> {
    backend.ensure_pipewire()?;
    validate_name(name)?;
    let all_devices = device::list(backend)?;
    let queries: Vec<_> = device_queries
        .split(',')
        .map(str::trim)
        .filter(|query| !query.is_empty())
        .collect();
    if queries.len() < 2 {
        return Err(AudictlError::Unsupported(
            "multi create requires at least two output devices".to_owned(),
        ));
    }
    let mut outputs = queries
        .iter()
        .map(|query| device::resolve(&all_devices, query, DeviceKind::Output, mode))
        .collect::<Result<Vec<_>>>()?;
    let distinct = outputs
        .iter()
        .map(|device| device.uid.as_str())
        .collect::<std::collections::BTreeSet<_>>();
    if distinct.len() != outputs.len() {
        return Err(AudictlError::Unsupported(
            "multi create requires distinct output devices".to_owned(),
        ));
    }
    let primary = if let Some(query) = primary_query {
        device::resolve(&all_devices, query, DeviceKind::Output, mode)?
    } else {
        outputs[0].clone()
    };
    if let Some(index) = outputs.iter().position(|device| device.uid == primary.uid) {
        outputs.swap(0, index);
    } else {
        return Err(AudictlError::Unsupported(format!(
            "primary device '{}' is not in --devices",
            primary.name
        )));
    }

    let uid = format!("audictl_multi_{}", slug(name));
    if let Some(existing) = all_devices.iter().find(|device| device.uid == uid) {
        let manifest = load_manifest(backend, &uid).ok_or_else(|| {
            AudictlError::Unsupported(format!(
                "'{}' already exists but is not managed by audictl",
                existing.name
            ))
        })?;
        let requested_uids = outputs
            .iter()
            .map(|device| device.uid.as_str())
            .collect::<Vec<_>>();
        let existing_uids = manifest
            .devices
            .iter()
            .map(|device| device.uid.as_str())
            .collect::<Vec<_>>();
        if manifest.name != name
            || manifest.primary != primary.uid
            || existing_uids != requested_uids
        {
            return Err(AudictlError::Unsupported(format!(
                "multi-output '{}' already exists with a different composition; destroy it first",
                existing.name
            )));
        }
        return Ok((from_manifest(existing.id, manifest), false));
    }

    let manifest = Manifest {
        name: name.to_owned(),
        uid: uid.clone(),
        primary: primary.uid.clone(),
        devices: outputs
            .iter()
            .map(|device| as_subdevice(device, device.uid != primary.uid))
            .collect(),
    };
    save_manifest(backend, &manifest)?;
    write_unit(backend, &manifest)?;
    let unit = unit_name(&uid);
    backend.run("systemctl", ["--user", "daemon-reload"])?;
    if let Err(error) = backend.run("systemctl", ["--user", "enable", "--now", &unit]) {
        let _ = backend.run("systemctl", ["--user", "disable", "--now", &unit]);
        let _ = backend.remove_if_exists(&unit_path(backend, &uid));
        let _ = backend.remove_if_exists(&manifest_path(backend, &uid));
        let _ = backend.run("systemctl", ["--user", "daemon-reload"]);
        return Err(error);
    }

    let refreshed = device::list(backend)?;
    let created = refreshed
        .iter()
        .find(|device| device.uid == uid)
        .ok_or_else(|| AudictlError::Internal(format!("multi-output '{name}' was not created")))?;
    Ok((from_manifest(created.id, manifest), true))
}

pub fn destroy(backend: &Backend, query: &str, if_exists: bool) -> Result<(Destroyed, bool)> {
    backend.ensure_pipewire()?;
    let devices: Vec<_> = device::list(backend)?
        .into_iter()
        .filter(|device| device.is_multi_output)
        .collect();
    let selected = match device::resolve(&devices, query, DeviceKind::Output, SelectorMode::Auto) {
        Ok(device) => device,
        Err(AudictlError::DeviceNotFound { .. }) if if_exists => {
            return Ok((
                Destroyed {
                    uid: None,
                    existed: false,
                },
                false,
            ));
        }
        Err(error) => return Err(error),
    };
    let unit = unit_name(&selected.uid);
    let _ = backend.run("systemctl", ["--user", "disable", "--now", &unit]);
    unload_module(backend, &selected.uid)?;
    backend.remove_if_exists(&unit_path(backend, &selected.uid))?;
    backend.remove_if_exists(&manifest_path(backend, &selected.uid))?;
    backend.run("systemctl", ["--user", "daemon-reload"])?;
    Ok((
        Destroyed {
            uid: Some(selected.uid),
            existed: true,
        },
        true,
    ))
}

pub fn human(output: &MultiOutput) -> String {
    let mut lines = vec![format!("{} (id {}, multi-output)", output.name, output.id)];
    lines.push(format!("  uid: {}", output.uid));
    for device in &output.sub_devices {
        let primary = if output.clock_device_uid.as_deref() == Some(&device.uid) {
            " [primary]"
        } else {
            ""
        };
        lines.push(format!(
            "  - {}{} ({})",
            device.name.as_deref().unwrap_or(&device.uid),
            primary,
            device.uid
        ));
    }
    lines.join("\n")
}

fn as_subdevice(device: &device::DeviceInfo, drift_compensation: bool) -> SubDevice {
    SubDevice {
        uid: device.uid.clone(),
        name: Some(device.name.clone()),
        drift_compensation,
    }
}

fn from_manifest(id: u32, manifest: Manifest) -> MultiOutput {
    MultiOutput {
        id,
        uid: manifest.uid,
        name: manifest.name,
        is_multi_output: true,
        is_private: false,
        clock_device_uid: Some(manifest.primary),
        sub_devices: manifest.devices,
    }
}

fn unit_name(uid: &str) -> String {
    format!("{uid}.service")
}

fn unit_path(backend: &Backend, uid: &str) -> std::path::PathBuf {
    backend
        .config_home()
        .join("systemd/user")
        .join(unit_name(uid))
}

fn manifest_path(backend: &Backend, uid: &str) -> std::path::PathBuf {
    backend
        .config_home()
        .join("audictl/multi")
        .join(format!("{uid}.json"))
}

fn save_manifest(backend: &Backend, manifest: &Manifest) -> Result<()> {
    let content = serde_json::to_string_pretty(manifest)
        .map_err(|error| AudictlError::Internal(format!("could not encode manifest: {error}")))?;
    backend.write_if_changed(&manifest_path(backend, &manifest.uid), &(content + "\n"))?;
    Ok(())
}

fn load_manifest(backend: &Backend, uid: &str) -> Option<Manifest> {
    let raw = fs::read_to_string(manifest_path(backend, uid)).ok()?;
    serde_json::from_str(&raw).ok()
}

fn write_unit(backend: &Backend, manifest: &Manifest) -> Result<()> {
    let slaves = manifest
        .devices
        .iter()
        .map(|device| device.uid.as_str())
        .collect::<Vec<_>>()
        .join(",");
    let content = format!(
        "[Unit]\nDescription=Audictl multi-output {}\nAfter=pipewire-pulse.service\nRequires=pipewire-pulse.service\nPartOf=pipewire-pulse.service\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart={} load-module module-combine-sink sink_name={} slaves={} sink_properties=device.description={}\n\n[Install]\nWantedBy=default.target\n",
        manifest.name,
        backend.program_path("pactl")?.display(),
        manifest.uid,
        slaves,
        pipewire_label(&manifest.name)
    );
    backend.write_if_changed(&unit_path(backend, &manifest.uid), &content)?;
    Ok(())
}

fn unload_module(backend: &Backend, uid: &str) -> Result<()> {
    let modules = backend.run("pactl", ["list", "short", "modules"])?;
    for line in modules.lines() {
        let mut fields = line.splitn(4, '\t');
        let Some(serial) = fields.next() else {
            continue;
        };
        let Some(module_name) = fields.next() else {
            continue;
        };
        let arguments = fields.next().unwrap_or_default();
        if module_name != "module-combine-sink" || !arguments.contains(&format!("sink_name={uid}"))
        {
            continue;
        }
        backend.run("pactl", ["unload-module", serial])?;
    }
    Ok(())
}

fn validate_name(name: &str) -> Result<()> {
    if name.trim().is_empty()
        || name
            .chars()
            .any(|character| character.is_control() || matches!(character, '\'' | '"' | '\\' | '%'))
    {
        return Err(AudictlError::Unsupported(
            "multi-output names must be non-empty and cannot contain quotes, backslashes, percent signs, or control characters"
                .to_owned(),
        ));
    }
    Ok(())
}

fn pipewire_label(name: &str) -> String {
    let mut label = String::new();
    let mut separator = false;
    for character in name.chars() {
        if character.is_ascii_alphanumeric() {
            label.push(character);
            separator = false;
        } else if !label.is_empty() && !separator {
            label.push('-');
            separator = true;
        }
    }
    while label.ends_with('-') {
        label.pop();
    }
    label
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multi_uid_is_stable() {
        assert_eq!(
            format!("audictl_multi_{}", slug("Speakers + Bridge")),
            "audictl_multi_speakers_bridge"
        );
    }
}
