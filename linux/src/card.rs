use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::backend::{Backend, slug};
use crate::error::{AudictlError, Result};
use crate::virtual_audio::Visibility;

pub const OFF_PROFILE: &str = "off";

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CardInfo {
    pub id: u32,
    pub uid: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manufacturer: Option<String>,
    pub transport: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub alsa_card: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub alsa_id: Option<String>,
    pub active_profile: String,
    pub profiles: Vec<CardProfile>,
    pub pipewire_visibility: Visibility,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CardProfile {
    pub name: String,
    pub description: String,
    pub priority: u64,
    pub available: bool,
}

#[derive(Debug, Serialize)]
pub struct CardList {
    pub cards: Vec<CardInfo>,
}

#[derive(Debug, Serialize)]
pub struct CardMutation {
    pub card: CardInfo,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    uid: String,
    previous_profile: String,
}

pub fn list(backend: &Backend) -> Result<Vec<CardInfo>> {
    let mut cards = parse_cards(&backend.pactl_json("cards")?)?;
    cards.sort_by(|left, right| {
        left.name
            .to_ascii_lowercase()
            .cmp(&right.name.to_ascii_lowercase())
            .then_with(|| left.uid.cmp(&right.uid))
    });
    Ok(cards)
}

fn parse_cards(value: &Value) -> Result<Vec<CardInfo>> {
    let nodes = value
        .as_array()
        .ok_or_else(|| AudictlError::Internal("pactl returned a non-array card list".to_owned()))?;
    let mut cards = Vec::new();
    for node in nodes {
        let uid = string(node, "name").unwrap_or_default();
        let properties = node.get("properties").and_then(Value::as_object);
        let property = |key: &str| {
            properties
                .and_then(|map| map.get(key))
                .and_then(Value::as_str)
                .map(str::to_owned)
        };
        let active_profile = string(node, "active_profile").unwrap_or_default();
        let mut profiles: Vec<CardProfile> = node
            .get("profiles")
            .and_then(Value::as_object)
            .map(|map| {
                map.iter()
                    .map(|(name, profile)| CardProfile {
                        name: name.clone(),
                        description: string(profile, "description").unwrap_or_else(|| name.clone()),
                        priority: profile.get("priority").and_then(Value::as_u64).unwrap_or(0),
                        available: profile_available(profile.get("available")),
                    })
                    .collect()
            })
            .unwrap_or_default();
        profiles.sort_by_key(|profile| std::cmp::Reverse(profile.priority));
        cards.push(CardInfo {
            id: node.get("index").and_then(Value::as_u64).unwrap_or(0) as u32,
            uid: uid.clone(),
            name: property("device.description").unwrap_or_else(|| uid.clone()),
            manufacturer: property("device.vendor.name"),
            transport: property("device.bus")
                .or_else(|| property("device.api"))
                .unwrap_or_else(|| "unknown".to_owned()),
            alsa_card: property("alsa.card").and_then(|index| index.parse().ok()),
            alsa_id: property("alsa.id"),
            pipewire_visibility: if active_profile == OFF_PROFILE {
                Visibility::Hidden
            } else {
                Visibility::Exposed
            },
            active_profile,
            profiles,
        });
    }
    Ok(cards)
}

fn profile_available(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(available)) => *available,
        Some(Value::String(availability)) => availability != "no",
        _ => true,
    }
}

pub fn resolve(backend: &Backend, query: &str) -> Result<CardInfo> {
    let cards = list(backend)?;
    let exact_id = || {
        query
            .parse::<u32>()
            .ok()
            .and_then(|id| cards.iter().find(|card| card.id == id))
    };
    let exact_uid = || cards.iter().find(|card| card.uid == query);
    let exact_alsa_id = || {
        cards
            .iter()
            .find(|card| card.alsa_id.as_deref() == Some(query))
    };
    let exact_name = || {
        cards
            .iter()
            .find(|card| card.name.eq_ignore_ascii_case(query))
    };
    if let Some(card) = exact_id()
        .or_else(exact_uid)
        .or_else(exact_alsa_id)
        .or_else(exact_name)
    {
        return Ok(card.clone());
    }

    let lowered = query.to_ascii_lowercase();
    let matches: Vec<&CardInfo> = cards
        .iter()
        .filter(|card| card.name.to_ascii_lowercase().contains(&lowered))
        .collect();
    match matches.as_slice() {
        [card] => Ok((*card).clone()),
        [] => Err(AudictlError::DeviceNotFound {
            query: query.to_owned(),
        }),
        _ => Err(AudictlError::Ambiguous {
            query: query.to_owned(),
            count: matches.len(),
            candidates: Value::Array(
                matches
                    .into_iter()
                    .map(|card| {
                        serde_json::json!({ "id": card.id, "uid": card.uid, "name": card.name })
                    })
                    .collect(),
            ),
        }),
    }
}

pub fn hide(backend: &Backend, query: &str) -> Result<(CardMutation, bool)> {
    backend.ensure_pipewire()?;
    let card = resolve(backend, query)?;
    if card.active_profile == OFF_PROFILE {
        return Ok((CardMutation { card }, false));
    }
    save_manifest(
        backend,
        &Manifest {
            uid: card.uid.clone(),
            previous_profile: card.active_profile.clone(),
        },
    )?;
    backend.run("pactl", ["set-card-profile", &card.uid, OFF_PROFILE])?;
    let card = resolve(backend, &card.uid)?;
    if card.active_profile != OFF_PROFILE {
        return Err(AudictlError::Internal(format!(
            "{} is still exposed after hide",
            card.uid
        )));
    }
    Ok((CardMutation { card }, true))
}

pub fn show(backend: &Backend, query: &str) -> Result<(CardMutation, bool)> {
    backend.ensure_pipewire()?;
    let card = resolve(backend, query)?;
    if card.active_profile != OFF_PROFILE {
        return Ok((CardMutation { card }, false));
    }
    let target = restore_profile(backend, &card)
        .ok_or_else(|| {
            AudictlError::Unsupported(format!("{} has no available profile to restore", card.uid))
        })?
        .to_owned();
    backend.run("pactl", ["set-card-profile", &card.uid, &target])?;
    let card = resolve(backend, &card.uid)?;
    if card.active_profile == OFF_PROFILE {
        return Err(AudictlError::Internal(format!(
            "{} is still hidden after show",
            card.uid
        )));
    }
    backend.remove_if_exists(&manifest_path(backend, &card.uid))?;
    Ok((CardMutation { card }, true))
}

fn restore_profile<'a>(backend: &Backend, card: &'a CardInfo) -> Option<&'a str> {
    let remembered = load_manifest(backend, &card.uid);
    let remembered = remembered.as_ref().and_then(|manifest| {
        card.profiles
            .iter()
            .find(|profile| profile.name == manifest.previous_profile && profile.available)
    });
    remembered
        .or_else(|| best_profile(&card.profiles))
        .map(|profile| profile.name.as_str())
}

fn best_profile(profiles: &[CardProfile]) -> Option<&CardProfile> {
    profiles
        .iter()
        .filter(|profile| profile.name != OFF_PROFILE && profile.available)
        .max_by_key(|profile| profile.priority)
}

pub fn human_list(cards: &[CardInfo]) -> String {
    if cards.is_empty() {
        return "no sound cards found".to_owned();
    }
    let mut lines = vec![format!(
        "{:<4}  {:<28}  {:<8}  {:<36}  {}",
        "ID", "NAME", "ALSA", "PROFILE", "PIPEWIRE"
    )];
    for card in cards {
        lines.push(format!(
            "{:<4}  {:<28}  {:<8}  {:<36}  {}",
            card.id,
            card.name,
            card.alsa_id.as_deref().unwrap_or("-"),
            card.profiles
                .iter()
                .find(|profile| profile.name == card.active_profile)
                .map(|profile| profile.description.as_str())
                .unwrap_or(card.active_profile.as_str()),
            match card.pipewire_visibility {
                Visibility::Hidden => "hidden",
                _ => "exposed",
            }
        ));
    }
    lines.join("\n")
}

pub fn human_mutation(mutation: &CardMutation) -> String {
    let card = &mutation.card;
    let mut text = format!(
        "{} ({})\n  profile:   {}\n  PipeWire:  {}",
        card.name,
        card.uid,
        card.active_profile,
        match card.pipewire_visibility {
            Visibility::Hidden => "hidden",
            _ => "exposed",
        }
    );
    if card.pipewire_visibility == Visibility::Hidden {
        let device = card
            .alsa_id
            .clone()
            .or_else(|| card.alsa_card.map(|index| index.to_string()));
        if let Some(device) = device {
            text.push_str(&format!(
                "\n  ALSA:      plughw:{device},0 is free for direct access"
            ));
        }
    }
    text
}

fn manifest_path(backend: &Backend, uid: &str) -> std::path::PathBuf {
    backend
        .config_home()
        .join("audictl/cards")
        .join(format!("{}.json", slug(uid)))
}

fn save_manifest(backend: &Backend, manifest: &Manifest) -> Result<()> {
    let content = serde_json::to_string_pretty(manifest)
        .map_err(|error| AudictlError::Internal(format!("could not encode manifest: {error}")))?;
    backend.write_if_changed(&manifest_path(backend, &manifest.uid), &(content + "\n"))?;
    Ok(())
}

fn load_manifest(backend: &Backend, uid: &str) -> Option<Manifest> {
    let raw = std::fs::read_to_string(manifest_path(backend, uid)).ok()?;
    let manifest: Manifest = serde_json::from_str(&raw).ok()?;
    (manifest.uid == uid).then_some(manifest)
}

fn string(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn sample() -> Value {
        json!([{
            "index": 48,
            "name": "alsa_card.usb-BurrBrown_from_Texas_Instruments_USB_AUDIO_CODEC-00",
            "properties": {
                "device.description": "PCM2900C Audio CODEC",
                "device.vendor.name": "Texas Instruments",
                "device.bus": "usb",
                "alsa.card": "0",
                "alsa.id": "CODEC"
            },
            "profiles": {
                "off": { "description": "Off", "priority": 0, "available": true },
                "output:analog-stereo+input:analog-stereo": {
                    "description": "Analog Stereo Duplex", "priority": 6565, "available": true
                },
                "pro-audio": { "description": "Pro Audio", "priority": 1, "available": true }
            },
            "active_profile": "output:analog-stereo+input:analog-stereo"
        }])
    }

    #[test]
    fn parses_pactl_card_json() {
        let cards = parse_cards(&sample()).unwrap();
        assert_eq!(cards.len(), 1);
        let card = &cards[0];
        assert_eq!(card.id, 48);
        assert_eq!(card.name, "PCM2900C Audio CODEC");
        assert_eq!(card.alsa_card, Some(0));
        assert_eq!(card.alsa_id.as_deref(), Some("CODEC"));
        assert_eq!(card.transport, "usb");
        assert_eq!(card.pipewire_visibility, Visibility::Exposed);
        assert_eq!(
            card.profiles[0].name,
            "output:analog-stereo+input:analog-stereo"
        );
    }

    #[test]
    fn off_profile_reports_hidden() {
        let mut value = sample();
        value[0]["active_profile"] = json!("off");
        let cards = parse_cards(&value).unwrap();
        assert_eq!(cards[0].pipewire_visibility, Visibility::Hidden);
    }

    #[test]
    fn best_profile_skips_off_and_unavailable() {
        let mut value = sample();
        value[0]["profiles"]["output:analog-stereo+input:analog-stereo"]["available"] =
            json!(false);
        let cards = parse_cards(&value).unwrap();
        assert_eq!(best_profile(&cards[0].profiles).unwrap().name, "pro-audio");
    }

    #[test]
    fn availability_accepts_pulseaudio_strings() {
        assert!(profile_available(Some(&json!("yes"))));
        assert!(profile_available(Some(&json!("unknown"))));
        assert!(!profile_available(Some(&json!("no"))));
        assert!(profile_available(None));
    }
}
