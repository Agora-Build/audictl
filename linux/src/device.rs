use std::collections::BTreeMap;
use std::fs;

use serde::Serialize;
use serde_json::{Value, json};

use crate::backend::Backend;
use crate::error::{AudictlError, Result};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Direction {
    pub channels: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub volume: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub muted: Option<bool>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub id: u32,
    pub uid: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manufacturer: Option<String>,
    pub transport: String,
    pub input: Direction,
    pub output: Direction,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sample_rate: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub available_sample_rates: Option<Vec<f64>>,
    pub is_default_input: bool,
    pub is_default_output: bool,
    pub is_default_system: bool,
    pub is_aggregate: bool,
    pub is_multi_output: bool,
    pub is_alive: bool,
    pub is_running: bool,
}

#[derive(Debug, Serialize)]
pub struct DeviceList {
    pub devices: Vec<DeviceInfo>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeviceKind {
    Input,
    Output,
    Any,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SelectorMode {
    Auto,
    Uid,
    Id,
    Name,
}

pub fn list(backend: &Backend) -> Result<Vec<DeviceInfo>> {
    let default_input = backend
        .run("pactl", ["get-default-source"])
        .unwrap_or_default()
        .trim()
        .to_owned();
    let default_output = backend
        .run("pactl", ["get-default-sink"])
        .unwrap_or_default()
        .trim()
        .to_owned();

    let mut devices = Vec::new();
    parse_nodes(
        backend.pactl_json("sinks")?,
        DeviceKind::Output,
        &default_input,
        &default_output,
        &mut devices,
    )?;
    for device in &mut devices {
        if device.is_multi_output {
            let manifest = backend
                .config_home()
                .join("audictl/multi")
                .join(format!("{}.json", device.uid));
            if let Ok(raw) = fs::read_to_string(manifest)
                && let Ok(value) = serde_json::from_str::<Value>(&raw)
                && let Some(name) = value.get("name").and_then(Value::as_str)
            {
                device.name = name.to_owned();
            }
        }
    }
    parse_nodes(
        backend.pactl_json("sources")?,
        DeviceKind::Input,
        &default_input,
        &default_output,
        &mut devices,
    )?;
    devices.sort_by(|left, right| {
        left.name
            .to_ascii_lowercase()
            .cmp(&right.name.to_ascii_lowercase())
            .then_with(|| left.uid.cmp(&right.uid))
    });
    Ok(devices)
}

fn parse_nodes(
    value: Value,
    kind: DeviceKind,
    default_input: &str,
    default_output: &str,
    devices: &mut Vec<DeviceInfo>,
) -> Result<()> {
    let nodes = value.as_array().ok_or_else(|| {
        AudictlError::Internal("pactl returned a non-array device list".to_owned())
    })?;
    for node in nodes {
        let uid = string(node, "name").unwrap_or_default();
        if kind == DeviceKind::Input && uid.ends_with(".monitor") {
            continue;
        }
        let properties = node.get("properties").and_then(Value::as_object);
        let property = |key: &str| {
            properties
                .and_then(|map| map.get(key))
                .and_then(Value::as_str)
                .map(str::to_owned)
        };
        let channels = parse_channels(string(node, "sample_specification").as_deref());
        let volume = average_volume(node.get("volume"));
        let muted = node.get("mute").and_then(Value::as_bool);
        let empty = Direction {
            channels: 0,
            volume: None,
            muted: None,
        };
        let direction = Direction {
            channels,
            volume,
            muted,
        };
        let is_multi = uid.starts_with("audictl_multi_");
        let transport = if is_multi {
            "virtual".to_owned()
        } else {
            property("device.bus")
                .or_else(|| property("device.api"))
                .unwrap_or_else(|| {
                    if property("node.virtual").as_deref() == Some("true") {
                        "virtual".to_owned()
                    } else {
                        "unknown".to_owned()
                    }
                })
        };
        let is_running = string(node, "state").as_deref() == Some("RUNNING");
        devices.push(DeviceInfo {
            id: node.get("index").and_then(Value::as_u64).unwrap_or(0) as u32,
            uid: uid.clone(),
            name: string(node, "description").unwrap_or_else(|| uid.clone()),
            manufacturer: property("device.vendor.name"),
            transport,
            input: if kind == DeviceKind::Input {
                direction.clone()
            } else {
                empty.clone()
            },
            output: if kind == DeviceKind::Output {
                direction
            } else {
                empty
            },
            sample_rate: parse_rate(string(node, "sample_specification").as_deref()),
            available_sample_rates: None,
            is_default_input: kind == DeviceKind::Input && uid == default_input,
            is_default_output: kind == DeviceKind::Output && uid == default_output,
            is_default_system: kind == DeviceKind::Output && uid == default_output,
            is_aggregate: false,
            is_multi_output: is_multi,
            is_alive: true,
            is_running,
        });
    }
    Ok(())
}

pub fn resolve(
    devices: &[DeviceInfo],
    query: &str,
    kind: DeviceKind,
    mode: SelectorMode,
) -> Result<DeviceInfo> {
    let eligible: Vec<&DeviceInfo> = devices
        .iter()
        .filter(|device| match kind {
            DeviceKind::Input => device.input.channels > 0,
            DeviceKind::Output => device.output.channels > 0,
            DeviceKind::Any => true,
        })
        .collect();

    let exact_id = || {
        query
            .parse::<u32>()
            .ok()
            .and_then(|id| eligible.iter().find(|device| device.id == id).copied())
    };
    let exact_uid = || eligible.iter().find(|device| device.uid == query).copied();
    let exact_name = || {
        eligible
            .iter()
            .find(|device| device.name.eq_ignore_ascii_case(query))
            .copied()
    };

    let exact = match mode {
        SelectorMode::Id => exact_id(),
        SelectorMode::Uid => exact_uid(),
        SelectorMode::Name => exact_name(),
        SelectorMode::Auto => exact_id().or_else(exact_uid).or_else(exact_name),
    };
    if let Some(device) = exact {
        return Ok(device.clone());
    }
    if mode != SelectorMode::Auto && mode != SelectorMode::Name {
        return Err(AudictlError::DeviceNotFound {
            query: query.to_owned(),
        });
    }

    let lowered = query.to_ascii_lowercase();
    let matches: Vec<&DeviceInfo> = eligible
        .into_iter()
        .filter(|device| device.name.to_ascii_lowercase().contains(&lowered))
        .collect();
    match matches.as_slice() {
        [device] => Ok((*device).clone()),
        [] => Err(AudictlError::DeviceNotFound {
            query: query.to_owned(),
        }),
        _ => Err(AudictlError::Ambiguous {
            query: query.to_owned(),
            count: matches.len(),
            candidates: Value::Array(
                matches
                    .into_iter()
                    .map(
                        |device| json!({ "id": device.id, "uid": device.uid, "name": device.name }),
                    )
                    .collect(),
            ),
        }),
    }
}

pub fn human_list(devices: &[DeviceInfo]) -> String {
    let mut rows = vec![vec![
        "ID".to_owned(),
        "NAME".to_owned(),
        "IN".to_owned(),
        "OUT".to_owned(),
        "RATE".to_owned(),
        "TRANSPORT".to_owned(),
        "FLAGS".to_owned(),
    ]];
    for device in devices {
        let mut flags = Vec::new();
        if device.is_default_input {
            flags.push("default-in");
        }
        if device.is_default_output {
            flags.push("default-out");
        }
        if device.is_multi_output {
            flags.push("multi");
        }
        rows.push(vec![
            device.id.to_string(),
            device.name.clone(),
            device.input.channels.to_string(),
            device.output.channels.to_string(),
            device
                .sample_rate
                .map(|rate| format!("{} Hz", rate as u32))
                .unwrap_or_else(|| "-".to_owned()),
            device.transport.clone(),
            flags.join(","),
        ]);
    }
    table(rows)
}

pub fn human_info(device: &DeviceInfo) -> String {
    format!(
        "{} (id {})\n  uid:       {}\n  transport: {}\n  input:     {} ch\n  output:    {} ch\n  rate:      {}",
        device.name,
        device.id,
        device.uid,
        device.transport,
        device.input.channels,
        device.output.channels,
        device
            .sample_rate
            .map(|rate| format!("{} Hz", rate as u32))
            .unwrap_or_else(|| "unknown".to_owned())
    )
}

fn table(rows: Vec<Vec<String>>) -> String {
    let mut widths = BTreeMap::new();
    for row in &rows {
        for (index, value) in row.iter().enumerate() {
            widths
                .entry(index)
                .and_modify(|width: &mut usize| *width = (*width).max(value.len()))
                .or_insert(value.len());
        }
    }
    rows.into_iter()
        .map(|row| {
            row.into_iter()
                .enumerate()
                .map(|(index, value)| format!("{value:<width$}", width = widths[&index]))
                .collect::<Vec<_>>()
                .join("  ")
                .trim_end()
                .to_owned()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn string(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn parse_channels(specification: Option<&str>) -> u32 {
    specification
        .and_then(|specification| {
            specification
                .split_whitespace()
                .find_map(|part| part.strip_suffix("ch"))
        })
        .and_then(|channels| channels.parse().ok())
        .unwrap_or(0)
}

fn parse_rate(specification: Option<&str>) -> Option<f64> {
    specification
        .and_then(|specification| {
            specification
                .split_whitespace()
                .find_map(|part| part.strip_suffix("Hz"))
        })
        .and_then(|rate| rate.parse().ok())
}

fn average_volume(volume: Option<&Value>) -> Option<f64> {
    let channels = volume?.as_object()?;
    let values: Vec<f64> = channels
        .values()
        .filter_map(|channel| channel.get("value").and_then(Value::as_f64))
        .collect();
    if values.is_empty() {
        None
    } else {
        Some(values.iter().sum::<f64>() / values.len() as f64 / 65_536.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(id: u32, uid: &str, name: &str) -> DeviceInfo {
        DeviceInfo {
            id,
            uid: uid.to_owned(),
            name: name.to_owned(),
            manufacturer: None,
            transport: "virtual".to_owned(),
            input: Direction {
                channels: 0,
                volume: None,
                muted: None,
            },
            output: Direction {
                channels: 2,
                volume: None,
                muted: None,
            },
            sample_rate: Some(48_000.0),
            available_sample_rates: None,
            is_default_input: false,
            is_default_output: false,
            is_default_system: false,
            is_aggregate: false,
            is_multi_output: false,
            is_alive: true,
            is_running: false,
        }
    }

    #[test]
    fn resolution_matches_existing_contract() {
        let devices = vec![
            device(1, "speaker.internal", "Built-in Speakers"),
            device(2, "speaker.usb", "USB Speakers"),
        ];
        assert_eq!(
            resolve(&devices, "2", DeviceKind::Output, SelectorMode::Auto)
                .unwrap()
                .uid,
            "speaker.usb"
        );
        assert_eq!(
            resolve(
                &devices,
                "speaker.internal",
                DeviceKind::Output,
                SelectorMode::Auto
            )
            .unwrap()
            .id,
            1
        );
        assert_eq!(
            resolve(&devices, "built-in", DeviceKind::Output, SelectorMode::Auto)
                .unwrap()
                .id,
            1
        );
        assert!(matches!(
            resolve(&devices, "speakers", DeviceKind::Output, SelectorMode::Auto),
            Err(AudictlError::Ambiguous { .. })
        ));
    }

    #[test]
    fn parses_pipewire_sample_specification() {
        assert_eq!(parse_channels(Some("float32le 4ch 48000Hz")), 4);
        assert_eq!(parse_rate(Some("float32le 4ch 48000Hz")), Some(48_000.0));
    }
}
