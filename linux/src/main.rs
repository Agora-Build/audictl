use clap::{Args, Parser, Subcommand, ValueEnum, error::ErrorKind};
use serde::Serialize;

use audictl_linux::backend::Backend;
use audictl_linux::device::{self, DeviceInfo, DeviceKind, DeviceList, SelectorMode};
use audictl_linux::error::Result;
use audictl_linux::{card, multi, output, virtual_audio};

const VERSION: &str = match option_env!("AUDICTL_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};

#[derive(Parser)]
#[command(
    name = "audictl",
    version = VERSION,
    about = "Manage Linux audio devices from the command line."
)]
struct Cli {
    #[arg(long, global = true, help = "Emit a JSON envelope on stdout.")]
    json: bool,

    #[arg(
        long,
        global = true,
        help = "Suppress output; communicate via exit code only."
    )]
    quiet: bool,

    #[arg(
        long,
        global = true,
        default_value_t = 5.0,
        help = "Seconds to wait for asynchronous operations."
    )]
    _timeout: f64,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// List audio devices exposed by the active audio server.
    List(ListArgs),
    /// Show full details for one audio device.
    Info {
        device: String,
        #[command(flatten)]
        selector: SelectorArgs,
    },
    /// Get or set the default input or output.
    Default {
        #[command(subcommand)]
        command: DefaultCommand,
    },
    /// Discover, install, expose, and hide ALSA virtual audio bridges.
    Virtual {
        #[command(subcommand)]
        command: VirtualCommand,
    },
    /// Hide whole sound cards from PipeWire, or expose them again.
    Card {
        #[command(subcommand)]
        command: CardCommand,
    },
    /// Create and destroy mirrored multi-output devices.
    Multi {
        #[command(subcommand)]
        command: MultiCommand,
    },
}

#[derive(Args)]
struct ListArgs {
    #[arg(long, conflicts_with = "output")]
    input: bool,
    #[arg(long, conflicts_with = "input")]
    output: bool,
    #[arg(long)]
    multi: bool,
}

#[derive(Args, Clone, Copy)]
#[group(multiple = false)]
struct SelectorArgs {
    #[arg(long)]
    by_uid: bool,
    #[arg(long)]
    by_id: bool,
    #[arg(long)]
    by_name: bool,
}

impl SelectorArgs {
    fn mode(self) -> SelectorMode {
        if self.by_uid {
            SelectorMode::Uid
        } else if self.by_id {
            SelectorMode::Id
        } else if self.by_name {
            SelectorMode::Name
        } else {
            SelectorMode::Auto
        }
    }
}

#[derive(Subcommand)]
enum DefaultCommand {
    /// Show the default device for a role.
    Get { role: Role },
    /// Set the default device for a role.
    Set {
        role: Role,
        device: String,
        #[command(flatten)]
        selector: SelectorArgs,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum Role {
    Input,
    Output,
    System,
}

impl Role {
    fn kind(self) -> DeviceKind {
        match self {
            Self::Input => DeviceKind::Input,
            Self::Output | Self::System => DeviceKind::Output,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Input => "input",
            Self::Output => "output",
            Self::System => "system",
        }
    }
}

#[derive(Subcommand)]
enum VirtualCommand {
    /// List ALSA virtual drivers, including ones hidden from PipeWire.
    List,
    /// Install snd_aloop, or report an existing virtual driver.
    Install {
        #[arg(long)]
        name: Option<String>,
    },
    /// Expose safe input/output endpoints to PipeWire.
    Show { device: String },
    /// Hide managed endpoints from PipeWire while keeping ALSA available.
    Hide { device: String },
}

#[derive(Subcommand)]
enum CardCommand {
    /// List sound cards known to PipeWire, including hidden ones.
    List,
    /// Restore a hidden card's PipeWire profile, re-exposing its endpoints.
    Show { device: String },
    /// Turn a card's PipeWire profile off so ALSA clients get direct access.
    Hide { device: String },
}

#[derive(Subcommand)]
enum MultiCommand {
    /// Create a persistent PipeWire combined sink.
    Create {
        #[arg(long)]
        name: String,
        #[arg(long)]
        devices: String,
        #[arg(long)]
        primary: Option<String>,
        #[command(flatten)]
        selector: SelectorArgs,
    },
    /// Destroy a managed PipeWire combined sink.
    Destroy {
        device: String,
        #[arg(long)]
        if_exists: bool,
    },
}

#[derive(Serialize)]
struct DefaultDevice {
    role: String,
    device: DeviceInfo,
}

fn main() {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::DisplayHelp | ErrorKind::DisplayVersion
            ) =>
        {
            error.exit()
        }
        Err(error) => {
            let _ = error.print();
            std::process::exit(64);
        }
    };
    let json = cli.json;
    let quiet = cli.quiet;
    if let Err(error) = execute(cli) {
        if !quiet {
            output::failure(&error, json);
        }
        std::process::exit(error.exit_code().into());
    }
}

fn execute(cli: Cli) -> Result<()> {
    let backend = Backend::discover()?;
    match cli.command {
        Command::List(args) => {
            let mut devices = device::list(&backend)?;
            devices.retain(|device| {
                (!args.input || device.input.channels > 0)
                    && (!args.output || device.output.channels > 0)
                    && (!args.multi || device.is_multi_output)
            });
            emit(
                cli.json,
                cli.quiet,
                &DeviceList {
                    devices: devices.clone(),
                },
                None,
                device::human_list(&devices),
            );
        }
        Command::Info {
            device: query,
            selector,
        } => {
            let devices = device::list(&backend)?;
            let selected = device::resolve(&devices, &query, DeviceKind::Any, selector.mode())?;
            emit(
                cli.json,
                cli.quiet,
                &selected,
                None,
                device::human_info(&selected),
            );
        }
        Command::Default { command } => match command {
            DefaultCommand::Get { role } => {
                let selected = get_default(&backend, role)?;
                let dto = DefaultDevice {
                    role: role.name().to_owned(),
                    device: selected,
                };
                let human = format!(
                    "{} (id {}, {})",
                    dto.device.name, dto.device.id, dto.device.uid
                );
                emit(cli.json, cli.quiet, &dto, None, human);
            }
            DefaultCommand::Set {
                role,
                device: query,
                selector,
            } => {
                let devices = device::list(&backend)?;
                let selected = device::resolve(&devices, &query, role.kind(), selector.mode())?;
                let current = get_default(&backend, role)?;
                let changed = current.uid != selected.uid;
                if changed {
                    let command = match role {
                        Role::Input => "set-default-source",
                        Role::Output | Role::System => "set-default-sink",
                    };
                    backend.run("pactl", [command, &selected.uid])?;
                }
                let dto = DefaultDevice {
                    role: role.name().to_owned(),
                    device: selected,
                };
                let verb = if changed { "is now" } else { "already" };
                let human = format!("default {} {verb} {}", dto.role, dto.device.name);
                emit(cli.json, cli.quiet, &dto, Some(changed), human);
            }
        },
        Command::Virtual { command } => match command {
            VirtualCommand::List => {
                let devices = virtual_audio::list(&backend)?;
                emit(
                    cli.json,
                    cli.quiet,
                    &virtual_audio::VirtualList {
                        devices: devices.clone(),
                    },
                    None,
                    virtual_audio::human_list(&devices),
                );
            }
            VirtualCommand::Install { name } => {
                let (mutation, changed) = virtual_audio::install(&backend, name.as_deref())?;
                let prefix = if mutation.adopted_existing_driver {
                    "existing virtual audio driver found:\n\n".to_owned()
                } else {
                    "installed virtual audio driver:\n\n".to_owned()
                };
                emit(
                    cli.json,
                    cli.quiet,
                    &mutation,
                    Some(changed),
                    prefix + &virtual_audio::human_mutation(&mutation),
                );
            }
            VirtualCommand::Show { device } => {
                let (mutation, changed) = virtual_audio::show(&backend, &device)?;
                emit(
                    cli.json,
                    cli.quiet,
                    &mutation,
                    Some(changed),
                    virtual_audio::human_mutation(&mutation),
                );
            }
            VirtualCommand::Hide { device } => {
                let (mutation, changed) = virtual_audio::hide(&backend, &device)?;
                emit(
                    cli.json,
                    cli.quiet,
                    &mutation,
                    Some(changed),
                    virtual_audio::human_mutation(&mutation),
                );
            }
        },
        Command::Card { command } => match command {
            CardCommand::List => {
                let cards = card::list(&backend)?;
                emit(
                    cli.json,
                    cli.quiet,
                    &card::CardList {
                        cards: cards.clone(),
                    },
                    None,
                    card::human_list(&cards),
                );
            }
            CardCommand::Show { device } => {
                let (mutation, changed) = card::show(&backend, &device)?;
                emit(
                    cli.json,
                    cli.quiet,
                    &mutation,
                    Some(changed),
                    card::human_mutation(&mutation),
                );
            }
            CardCommand::Hide { device } => {
                let (mutation, changed) = card::hide(&backend, &device)?;
                emit(
                    cli.json,
                    cli.quiet,
                    &mutation,
                    Some(changed),
                    card::human_mutation(&mutation),
                );
            }
        },
        Command::Multi { command } => match command {
            MultiCommand::Create {
                name,
                devices,
                primary,
                selector,
            } => {
                let (multi, changed) = multi::create(
                    &backend,
                    &name,
                    &devices,
                    primary.as_deref(),
                    selector.mode(),
                )?;
                let human = multi::human(&multi);
                emit(cli.json, cli.quiet, &multi, Some(changed), human);
            }
            MultiCommand::Destroy { device, if_exists } => {
                let (destroyed, changed) = multi::destroy(&backend, &device, if_exists)?;
                let human = if destroyed.existed {
                    format!("destroyed {}", destroyed.uid.as_deref().unwrap_or(&device))
                } else {
                    "no such device; nothing to do".to_owned()
                };
                emit(cli.json, cli.quiet, &destroyed, Some(changed), human);
            }
        },
    }
    Ok(())
}

fn get_default(backend: &Backend, role: Role) -> Result<DeviceInfo> {
    let command = match role {
        Role::Input => "get-default-source",
        Role::Output | Role::System => "get-default-sink",
    };
    let uid = backend.run("pactl", [command])?;
    let devices = device::list(backend)?;
    device::resolve(&devices, uid.trim(), role.kind(), SelectorMode::Uid)
}

fn emit<T: Serialize>(json: bool, quiet: bool, data: &T, changed: Option<bool>, human: String) {
    if !quiet {
        output::success(data, changed, json, human);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parses(arguments: &[&str]) -> bool {
        Cli::try_parse_from(std::iter::once("audictl").chain(arguments.iter().copied())).is_ok()
    }

    #[test]
    fn linux_commands_parse() {
        assert!(parses(&["list", "--output", "--json"]));
        assert!(parses(&["info", "speakers", "--by-name"]));
        assert!(parses(&["default", "get", "output"]));
        assert!(parses(&["default", "set", "output", "speakers"]));
        assert!(parses(&["virtual", "list"]));
        assert!(parses(&[
            "virtual",
            "install",
            "--name",
            "Browser Audio Bridge"
        ]));
        assert!(parses(&["virtual", "show", "AudictlBridge"]));
        assert!(parses(&["virtual", "hide", "AudictlBridge"]));
        assert!(parses(&["card", "list", "--json"]));
        assert!(parses(&["card", "hide", "CODEC"]));
        assert!(parses(&["card", "show", "CODEC"]));
        assert!(parses(&[
            "multi",
            "create",
            "--name",
            "Everywhere",
            "--devices",
            "speakers,bridge"
        ]));
        assert!(parses(&["multi", "destroy", "Everywhere", "--if-exists"]));
    }

    #[test]
    fn conflicting_selector_flags_are_rejected() {
        assert!(!parses(&[
            "default",
            "set",
            "output",
            "speakers",
            "--by-name",
            "--by-uid"
        ]));
    }
}
