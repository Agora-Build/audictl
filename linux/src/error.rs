use serde::Serialize;
use serde_json::{Value, json};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AudictlError {
    #[error("no device matches '{query}'")]
    DeviceNotFound { query: String },
    #[error("'{query}' matches {count} devices")]
    Ambiguous {
        query: String,
        count: usize,
        candidates: Value,
    },
    #[error("{0}")]
    Unsupported(String),
    #[error("{message}")]
    RequiresDeclarativeConfig { message: String, snippet: String },
    #[error("{}", missing_dependency_message(.0))]
    MissingDependency(String),
    #[error("{operation} failed: {message}")]
    CommandFailed { operation: String, message: String },
    #[error("{0}")]
    Internal(String),
}

impl AudictlError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::DeviceNotFound { .. } => "DEVICE_NOT_FOUND",
            Self::Ambiguous { .. } => "AMBIGUOUS_DEVICE",
            Self::Unsupported(_) => "UNSUPPORTED_OPERATION",
            Self::RequiresDeclarativeConfig { .. } => "REQUIRES_DECLARATIVE_CONFIG",
            Self::MissingDependency(_) => "MISSING_DEPENDENCY",
            Self::CommandFailed { .. } => "BACKEND_ERROR",
            Self::Internal(_) => "INTERNAL",
        }
    }

    pub fn exit_code(&self) -> u8 {
        match self {
            Self::Internal(_) => 1,
            Self::DeviceNotFound { .. } => 2,
            Self::Ambiguous { .. } => 3,
            Self::Unsupported(_) | Self::RequiresDeclarativeConfig { .. } => 4,
            Self::MissingDependency(_) => 5,
            Self::CommandFailed { .. } => 6,
        }
    }

    pub fn details(&self) -> Option<Value> {
        match self {
            Self::DeviceNotFound { query } => Some(json!({ "query": query })),
            Self::Ambiguous {
                query, candidates, ..
            } => Some(json!({ "query": query, "candidates": candidates })),
            Self::RequiresDeclarativeConfig { snippet, .. } => Some(json!({ "snippet": snippet })),
            Self::MissingDependency(command) => {
                let mut details = json!({ "command": command });
                if let Some(hint) = dependency_install_hint(command) {
                    details["installHint"] = json!(hint);
                }
                Some(details)
            }
            Self::CommandFailed { operation, .. } => Some(json!({ "operation": operation })),
            Self::Unsupported(_) | Self::Internal(_) => None,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorEnvelope {
    ok: bool,
    schema_version: u8,
    error: ErrorPayload,
}

#[derive(Serialize)]
struct ErrorPayload {
    code: &'static str,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    details: Option<Value>,
}

impl From<&AudictlError> for ErrorEnvelope {
    fn from(error: &AudictlError) -> Self {
        Self {
            ok: false,
            schema_version: 1,
            error: ErrorPayload {
                code: error.code(),
                message: error.to_string(),
                details: error.details(),
            },
        }
    }
}

pub type Result<T> = std::result::Result<T, AudictlError>;

fn missing_dependency_message(command: &str) -> String {
    let message = format!("required command '{command}' is not installed");
    match dependency_install_hint(command) {
        Some(hint) => format!("{message}. {hint}"),
        None => message,
    }
}

fn dependency_install_hint(command: &str) -> Option<&'static str> {
    match command {
        "pactl" => Some(
            "Install the PulseAudio client tools (NixOS: add pkgs.pulseaudio to systemPackages, \
             or use nix-shell -p pulseaudio --run 'audictl ...'; Debian/Ubuntu: pulseaudio-utils; \
             Arch: libpulse). The PulseAudio daemon is not needed when using PipeWire.",
        ),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pactl_error_explains_platform_packages() {
        let error = AudictlError::MissingDependency("pactl".to_owned());
        let message = error.to_string();

        assert!(message.contains("NixOS: add pkgs.pulseaudio"));
        assert!(message.contains("nix-shell -p pulseaudio"));
        assert!(message.contains("Debian/Ubuntu: pulseaudio-utils"));
        assert!(message.contains("Arch: libpulse"));
        assert!(message.contains("daemon is not needed"));

        let details = error.details().expect("missing dependency details");
        assert_eq!(details["command"], "pactl");
        assert!(details["installHint"].as_str().is_some());
    }

    #[test]
    fn unknown_dependency_keeps_generic_error() {
        let error = AudictlError::MissingDependency("other-tool".to_owned());

        assert_eq!(
            error.to_string(),
            "required command 'other-tool' is not installed"
        );
        assert!(error.details().expect("details")["installHint"].is_null());
    }
}
