use serde::Serialize;

use crate::error::{AudictlError, ErrorEnvelope};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SuccessEnvelope<T> {
    ok: bool,
    schema_version: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    changed: Option<bool>,
    data: T,
}

pub fn success<T: Serialize>(data: &T, changed: Option<bool>, json: bool, human: String) {
    if json {
        println!(
            "{}",
            serde_json::to_string(&SuccessEnvelope {
                ok: true,
                schema_version: 1,
                changed,
                data,
            })
            .expect("serializable output")
        );
    } else {
        println!("{human}");
    }
}

pub fn failure(error: &AudictlError, json: bool) {
    if json {
        println!(
            "{}",
            serde_json::to_string(&ErrorEnvelope::from(error)).expect("serializable error")
        );
    } else {
        eprintln!("error: {error}");
        if let AudictlError::RequiresDeclarativeConfig { snippet, .. } = error {
            eprintln!("\n{snippet}");
        }
    }
}
