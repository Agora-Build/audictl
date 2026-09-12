use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::backend::{Backend, slug};
use crate::error::{AudictlError, Result};

pub const DEFAULT_NAME: &str = "Audictl Audio Bridge";
pub const DEFAULT_ALSA_ID: &str = "AudictlBridge";

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VirtualDevice {
    pub id: String,
    pub index: u32,
    pub name: String,
    pub driver: String,
    pub alsa_playback: String,
    pub alsa_pipewire_side: String,
    pub pipewire_visibility: Visibility,
    pub input_endpoint: String,
    pub output_endpoint: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Visibility {
    Hidden,
    Exposed,
    Partial,
}

#[derive(Debug, Serialize)]
pub struct VirtualList {
    pub devices: Vec<VirtualDevice>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VirtualMutation {
    pub device: VirtualDevice,
    pub adopted_existing_driver: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct Manifest {
    id: String,
    name: String,
}

pub fn list(backend: &Backend) -> Result<Vec<VirtualDevice>> {
    list_from(backend, Path::new("/proc/asound/cards"))
}

fn list_from(backend: &Backend, cards_path: &Path) -> Result<Vec<VirtualDevice>> {
    let cards = match fs::read_to_string(cards_path) {
        Ok(cards) => cards,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => {
            return Err(AudictlError::Internal(format!(
                "could not read {}: {error}",
                cards_path.display()
            )));
        }
    };
    let modules = backend
        .pactl_json("modules")
        .unwrap_or(Value::Array(Vec::new()));
    let sources = backend
        .pactl_json("sources")
        .unwrap_or(Value::Array(Vec::new()));
    let sinks = backend
        .pactl_json("sinks")
        .unwrap_or(Value::Array(Vec::new()));
    let mut devices = parse_cards(&cards)
        .into_iter()
        .map(|(index, id)| {
            let name = load_manifest(backend, &id)
                .map(|manifest| manifest.name)
                .unwrap_or_else(|| default_friendly_name(&id));
            let target = format!("plughw:{id},1");
            let source = module_endpoint(&modules, "module-alsa-source", "source_name", &target)
                .or_else(|| node_for_card(&sources, &id));
            let sink = module_endpoint(&modules, "module-alsa-sink", "sink_name", &target)
                .or_else(|| node_for_card(&sinks, &id));
            let pipewire_visibility = match (source.is_some(), sink.is_some()) {
                (false, false) => Visibility::Hidden,
                (true, true) => Visibility::Exposed,
                _ => Visibility::Partial,
            };
            VirtualDevice {
                id: id.clone(),
                index,
                name: name.clone(),
                driver: "snd_aloop".to_owned(),
                alsa_playback: format!("plughw:{id},0"),
                alsa_pipewire_side: format!("plughw:{id},1"),
                pipewire_visibility,
                input_endpoint: source
                    .as_deref()
                    .and_then(|endpoint| node_description(&sources, endpoint))
                    .unwrap_or_else(|| endpoint_label(&name, "Input")),
                output_endpoint: sink
                    .as_deref()
                    .and_then(|endpoint| node_description(&sinks, endpoint))
                    .unwrap_or_else(|| endpoint_label(&name, "Output")),
            }
        })
        .collect::<Vec<_>>();
    devices.sort_by_key(|device| device.index);
    Ok(devices)
}

pub fn resolve(backend: &Backend, query: &str) -> Result<VirtualDevice> {
    let devices = list(backend)?;
    let exact = devices
        .iter()
        .find(|device| device.id == query || device.name.eq_ignore_ascii_case(query));
    if let Some(device) = exact {
        return Ok(device.clone());
    }
    let lowered = query.to_ascii_lowercase();
    let matches: Vec<_> = devices
        .iter()
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
            candidates: serde_json::to_value(matches).unwrap_or_default(),
        }),
    }
}

pub fn install(backend: &Backend, requested_name: Option<&str>) -> Result<(VirtualMutation, bool)> {
    let existing = list(backend)?;
    let selected = requested_name.and_then(|name| {
        existing
            .iter()
            .find(|device| device.id == name || device.name.eq_ignore_ascii_case(name))
    });
    if let Some(device) = selected.or_else(|| (existing.len() == 1).then(|| &existing[0])) {
        return Ok((
            VirtualMutation {
                device: device.clone(),
                adopted_existing_driver: true,
            },
            false,
        ));
    }
    if existing.len() > 1 {
        return Err(AudictlError::Ambiguous {
            query: requested_name.unwrap_or("virtual audio driver").to_owned(),
            count: existing.len(),
            candidates: serde_json::to_value(existing).unwrap_or_default(),
        });
    }

    let name = requested_name.unwrap_or(DEFAULT_NAME).trim();
    validate_display_name(name)?;
    let id = if requested_name.is_some() {
        alsa_id(name)
    } else {
        DEFAULT_ALSA_ID.to_owned()
    };
    if is_nixos() {
        let snippet = format!(
            "Add this to configuration.nix and rebuild:\n\nboot.kernelModules = [ \"snd_aloop\" ];\nboot.extraModprobeConfig = ''\n  options snd_aloop id={id}\n'';"
        );
        return Err(AudictlError::RequiresDeclarativeConfig {
            message: "NixOS requires declarative snd_aloop configuration".to_owned(),
            snippet,
        });
    }

    backend.ensure_pipewire()?;
    if backend.run("modinfo", ["snd_aloop"]).is_err() {
        return Err(AudictlError::Unsupported(missing_driver_guidance()));
    }
    ensure_wireplumber_rule(backend)?;
    install_system_file(backend, "/etc/modules-load.d/audictl.conf", "snd_aloop\n")?;
    install_system_file(
        backend,
        "/etc/modprobe.d/audictl.conf",
        &format!("options snd_aloop id={id}\n"),
    )?;
    backend.run("sudo", ["modprobe", "snd_aloop", &format!("id={id}")])?;
    save_manifest(
        backend,
        &Manifest {
            id: id.clone(),
            name: name.to_owned(),
        },
    )?;

    let device = resolve(backend, &id)?;
    Ok((
        VirtualMutation {
            device,
            adopted_existing_driver: false,
        },
        true,
    ))
}

pub fn show(backend: &Backend, query: &str) -> Result<(VirtualMutation, bool)> {
    backend.ensure_pipewire()?;
    let mut device = resolve(backend, query)?;
    if ensure_wireplumber_rule(backend)? {
        device = resolve(backend, &device.id)?;
    }
    let was_exposed = device.pipewire_visibility == Visibility::Exposed;
    if was_exposed {
        return Ok((
            VirtualMutation {
                device,
                adopted_existing_driver: true,
            },
            false,
        ));
    }
    if device.pipewire_visibility == Visibility::Partial {
        unload_modules(backend, &device.id)?;
    }
    write_endpoint_units(backend, &device)?;

    let units = unit_names(&device.id);
    backend.run("systemctl", ["--user", "daemon-reload"])?;
    if let Err(error) = backend.run("systemctl", ["--user", "enable", "--now", &units.source]) {
        let _ = backend.run("systemctl", ["--user", "disable", "--now", &units.source]);
        return Err(error);
    }
    if let Err(error) = backend.run("systemctl", ["--user", "enable", "--now", &units.sink]) {
        for unit in [&units.source, &units.sink] {
            let _ = backend.run("systemctl", ["--user", "disable", "--now", unit]);
        }
        let _ = unload_modules(backend, &device.id);
        return Err(error);
    }
    device = resolve(backend, &device.id)?;
    if device.pipewire_visibility != Visibility::Exposed {
        for unit in [&units.source, &units.sink] {
            let _ = backend.run("systemctl", ["--user", "disable", "--now", unit]);
        }
        let _ = unload_modules(backend, &device.id);
        return Err(AudictlError::Internal(format!(
            "{} did not expose both PipeWire endpoints",
            device.id
        )));
    }
    Ok((
        VirtualMutation {
            device,
            adopted_existing_driver: true,
        },
        !was_exposed,
    ))
}

pub fn hide(backend: &Backend, query: &str) -> Result<(VirtualMutation, bool)> {
    backend.ensure_pipewire()?;
    let mut device = resolve(backend, query)?;
    let was_visible = device.pipewire_visibility != Visibility::Hidden;
    let units = unit_names(&device.id);
    for unit in [&units.source, &units.sink] {
        let _ = backend.run("systemctl", ["--user", "disable", "--now", unit]);
    }
    unload_modules(backend, &device.id)?;
    device = resolve(backend, &device.id)?;
    if device.pipewire_visibility != Visibility::Hidden {
        return Err(AudictlError::Internal(format!(
            "{} still has PipeWire endpoints after hide",
            device.id
        )));
    }
    Ok((
        VirtualMutation {
            device,
            adopted_existing_driver: true,
        },
        was_visible,
    ))
}

pub fn human_list(devices: &[VirtualDevice]) -> String {
    if devices.is_empty() {
        return "no ALSA virtual audio drivers found".to_owned();
    }
    let mut lines = vec![format!(
        "{:<4}  {:<16}  {:<28}  {}",
        "CARD", "ALSA ID", "NAME", "PIPEWIRE"
    )];
    for device in devices {
        lines.push(format!(
            "{:<4}  {:<16}  {:<28}  {}",
            device.index,
            device.id,
            device.name,
            match device.pipewire_visibility {
                Visibility::Hidden => "hidden",
                Visibility::Exposed => "exposed",
                Visibility::Partial => "partial",
            }
        ));
    }
    lines.join("\n")
}

pub fn human_mutation(mutation: &VirtualMutation) -> String {
    let device = &mutation.device;
    format!(
        "{} ({})\n  ALSA:      {}\n  PipeWire:  {}\n  Input:     {}\n  Output:    {}",
        device.name,
        device.id,
        device.alsa_playback,
        match device.pipewire_visibility {
            Visibility::Hidden => "hidden",
            Visibility::Exposed => "exposed",
            Visibility::Partial => "partial",
        },
        device.input_endpoint,
        device.output_endpoint
    )
}

fn parse_cards(cards: &str) -> Vec<(u32, String)> {
    cards
        .lines()
        .filter(|line| line.contains(": Loopback"))
        .filter_map(|line| {
            let open = line.find('[')?;
            let close = line[open + 1..].find(']')? + open + 1;
            let index = line[..open].trim().parse().ok()?;
            let id = line[open + 1..close].trim().to_owned();
            Some((index, id))
        })
        .collect()
}

fn default_friendly_name(id: &str) -> String {
    if id == DEFAULT_ALSA_ID {
        DEFAULT_NAME.to_owned()
    } else {
        id.to_owned()
    }
}

fn alsa_id(name: &str) -> String {
    let id = name
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(15)
        .collect::<String>();
    if id.is_empty() {
        DEFAULT_ALSA_ID.to_owned()
    } else {
        id
    }
}

struct EndpointNames {
    source: String,
    sink: String,
}

fn endpoint_names(id: &str) -> EndpointNames {
    let id = slug(id);
    EndpointNames {
        source: format!("audictl_{id}_input"),
        sink: format!("audictl_{id}_output"),
    }
}

struct UnitNames {
    source: String,
    sink: String,
}

fn unit_names(id: &str) -> UnitNames {
    let id = slug(id);
    UnitNames {
        source: format!("audictl-virtual-{id}-input.service"),
        sink: format!("audictl-virtual-{id}-output.service"),
    }
}

fn module_endpoint(
    modules: &Value,
    module_name: &str,
    endpoint_key: &str,
    target: &str,
) -> Option<String> {
    modules.as_array()?.iter().find_map(|module| {
        if module.get("name").and_then(Value::as_str) != Some(module_name) {
            return None;
        }
        let argument = module.get("argument").and_then(Value::as_str)?;
        (argument_value(argument, "device") == Some(target))
            .then(|| argument_value(argument, endpoint_key).map(str::to_owned))
            .flatten()
    })
}

fn argument_value<'a>(arguments: &'a str, key: &str) -> Option<&'a str> {
    arguments
        .split_whitespace()
        .find_map(|argument| argument.strip_prefix(&format!("{key}=")))
}

fn node_description(nodes: &Value, name: &str) -> Option<String> {
    nodes.as_array()?.iter().find_map(|node| {
        (node.get("name").and_then(Value::as_str) == Some(name))
            .then(|| {
                node.get("description")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .flatten()
    })
}

fn node_for_card(nodes: &Value, id: &str) -> Option<String> {
    nodes.as_array()?.iter().find_map(|node| {
        let properties = node.get("properties")?;
        let path = properties
            .get("api.alsa.path")
            .or_else(|| properties.get("device"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        let alsa_id = properties.get("alsa.id").and_then(Value::as_str);
        (alsa_id == Some(id) || path.contains(&format!(":{id},")))
            .then(|| node.get("name").and_then(Value::as_str).map(str::to_owned))
            .flatten()
    })
}

fn unload_modules(backend: &Backend, id: &str) -> Result<()> {
    let target = format!("plughw:{id},1");
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
        if !matches!(module_name, "module-alsa-source" | "module-alsa-sink")
            || argument_value(arguments, "device") != Some(&target)
        {
            continue;
        }
        backend.run("pactl", ["unload-module", serial])?;
    }
    Ok(())
}

fn ensure_wireplumber_rule(backend: &Backend) -> Result<bool> {
    let modern_path = backend
        .config_home()
        .join("wireplumber/wireplumber.conf.d/90-audictl-virtual.conf");
    let modern = "monitor.alsa.rules = [\n  {\n    matches = [\n      { device.name = \"~alsa_card.platform-snd_aloop.*\" }\n    ]\n    actions = {\n      update-props = { device.disabled = true }\n    }\n  }\n]\n";
    let legacy_path = backend
        .config_home()
        .join("wireplumber/main.lua.d/90-audictl-virtual.lua");
    let legacy = "table.insert(alsa_monitor.rules, {\n  matches = {\n    { { \"device.name\", \"matches\", \"alsa_card.platform-snd_aloop.*\" } },\n  },\n  apply_properties = { [\"device.disabled\"] = true },\n})\n";
    let modern_changed = backend.write_if_changed(&modern_path, modern)?;
    let legacy_changed = backend.write_if_changed(&legacy_path, legacy)?;
    let changed = modern_changed || legacy_changed;
    if changed {
        backend.run("systemctl", ["--user", "restart", "wireplumber.service"])?;
    }
    Ok(changed)
}

fn write_endpoint_units(backend: &Backend, device: &VirtualDevice) -> Result<()> {
    let names = endpoint_names(&device.id);
    let units = unit_names(&device.id);
    let unit_dir = backend.config_home().join("systemd/user");
    let pactl = backend.program_path("pactl")?;
    let source_args = format!(
        "device={} source_name={} source_properties=device.description={} channels=1 channel_map=mono rate=44100 format=s16le",
        device.alsa_pipewire_side,
        names.source,
        endpoint_label(&device.name, "Input")
    );
    let sink_args = format!(
        "device={} sink_name={} sink_properties=device.description={} channels=1 channel_map=mono rate=44100 format=s16le",
        device.alsa_pipewire_side,
        names.sink,
        endpoint_label(&device.name, "Output")
    );
    backend.write_if_changed(
        &unit_dir.join(&units.source),
        &endpoint_unit(
            pactl.to_string_lossy().as_ref(),
            "source",
            "module-alsa-source",
            &source_args,
        ),
    )?;
    backend.write_if_changed(
        &unit_dir.join(&units.sink),
        &endpoint_unit(
            pactl.to_string_lossy().as_ref(),
            "output",
            "module-alsa-sink",
            &sink_args,
        ),
    )?;
    Ok(())
}

fn endpoint_unit(pactl: &str, kind: &str, module: &str, arguments: &str) -> String {
    format!(
        "[Unit]\nDescription=Expose Audictl virtual audio {kind}\nAfter=pipewire-pulse.service\nRequires=pipewire-pulse.service\nPartOf=pipewire-pulse.service\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart={pactl} load-module {module} {arguments}\n\n[Install]\nWantedBy=default.target\n"
    )
}

fn endpoint_label(name: &str, direction: &str) -> String {
    let words = name.split_whitespace().collect::<Vec<_>>().join("-");
    format!("{words}-{direction}")
}

fn manifest_path(backend: &Backend, id: &str) -> PathBuf {
    backend
        .config_home()
        .join("audictl/virtual")
        .join(format!("{}.json", slug(id)))
}

fn save_manifest(backend: &Backend, manifest: &Manifest) -> Result<()> {
    let content = serde_json::to_string_pretty(manifest)
        .map_err(|error| AudictlError::Internal(format!("could not encode manifest: {error}")))?;
    backend.write_if_changed(&manifest_path(backend, &manifest.id), &(content + "\n"))?;
    Ok(())
}

fn load_manifest(backend: &Backend, id: &str) -> Option<Manifest> {
    let raw = fs::read_to_string(manifest_path(backend, id)).ok()?;
    let manifest: Manifest = serde_json::from_str(&raw).ok()?;
    (manifest.id == id).then_some(manifest)
}

fn install_system_file(backend: &Backend, destination: &str, content: &str) -> Result<()> {
    let temporary = std::env::temp_dir().join(format!(
        "audictl-{}-{}",
        std::process::id(),
        slug(destination)
    ));
    fs::write(&temporary, content).map_err(|error| {
        AudictlError::Internal(format!("could not write {}: {error}", temporary.display()))
    })?;
    let result = backend.run(
        "sudo",
        [
            "install",
            "-m",
            "0644",
            temporary.to_string_lossy().as_ref(),
            destination,
        ],
    );
    let _ = fs::remove_file(temporary);
    result.map(|_| ())
}

fn is_nixos() -> bool {
    Path::new("/etc/NIXOS").exists()
        || fs::read_to_string("/etc/os-release")
            .is_ok_and(|release| release.lines().any(|line| line == "ID=nixos"))
}

fn validate_display_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name
            .chars()
            .any(|character| character.is_control() || matches!(character, '\'' | '"' | '\\' | '%'))
    {
        return Err(AudictlError::Unsupported(
            "device names must be non-empty and cannot contain quotes, backslashes, percent signs, or control characters"
                .to_owned(),
        ));
    }
    Ok(())
}

fn missing_driver_guidance() -> String {
    let release = fs::read_to_string("/etc/os-release").unwrap_or_default();
    if release.contains("ID_LIKE=arch") || release.lines().any(|line| line == "ID=arch") {
        "snd_aloop is unavailable for the running kernel; install the matching Arch kernel package and reboot"
            .to_owned()
    } else if release.contains("ID_LIKE=debian")
        || release
            .lines()
            .any(|line| matches!(line, "ID=ubuntu" | "ID=debian"))
    {
        "snd_aloop is unavailable; on Ubuntu install linux-modules-extra for the running kernel, then retry"
            .to_owned()
    } else {
        "snd_aloop is unavailable; install the loopback module for the running kernel, then retry"
            .to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_only_loopback_cards() {
        let cards = " 0 [VirtualAudio   ]: Loopback - Loopback\n                      Loopback 1\n 1 [Audio          ]: AppleT2x4 - Apple T2 Audio\n";
        assert_eq!(parse_cards(cards), vec![(0, "VirtualAudio".to_owned())]);
    }

    #[test]
    fn custom_name_produces_valid_stable_alsa_id() {
        assert_eq!(alsa_id("Browser Audio Bridge"), "BrowserAudioBri");
        assert_eq!(alsa_id("---"), DEFAULT_ALSA_ID);
    }

    #[test]
    fn generated_units_use_generic_endpoint_names() {
        let unit = endpoint_unit(
            "/usr/bin/pactl",
            "source",
            "module-alsa-source",
            "source_name=audictl_bridge_input",
        );
        assert!(unit.contains("audictl_bridge_input"));
        assert!(!unit.to_ascii_lowercase().contains("dialf"));
        assert!(!unit.to_ascii_lowercase().contains("agent"));
    }

    #[test]
    fn endpoint_labels_are_generic_and_shell_safe() {
        assert_eq!(
            endpoint_label(DEFAULT_NAME, "Input"),
            "Audictl-Audio-Bridge-Input"
        );
        assert_eq!(
            endpoint_label("Browser Audio Bridge", "Output"),
            "Browser-Audio-Bridge-Output"
        );
    }

    #[test]
    fn recognizes_automatically_enumerated_card_nodes() {
        let nodes = serde_json::json!([{
            "name": "alsa_output.platform-snd_aloop.0",
            "properties": { "alsa.id": "VirtualAudio" }
        }]);
        assert_eq!(
            node_for_card(&nodes, "VirtualAudio").as_deref(),
            Some("alsa_output.platform-snd_aloop.0")
        );
    }
}
