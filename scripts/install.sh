#!/usr/bin/env bash
#
# Install audictl — manage macOS audio devices from the command line.
#
# Quick install (works in regions where GitHub is not available):
#   curl -fsSL https://dl.agora.build/audictl/install.sh | bash
#
# Options (via env vars):
#   AUDICTL_VERSION=0.1.0    Pin a specific version (default: latest)
#   AUDICTL_BASE_URL=...     Override download base URL
#   AUDICTL_INSTALL_DIR=...  Override install directory
#
set -euo pipefail

BASE_URL="${AUDICTL_BASE_URL:-https://dl.agora.build/audictl/releases}"

# ── Helpers ──────────────────────────────────────────────────────────

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "  $*"; }

# ── Detect platform ──────────────────────────────────────────────────

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$os" in
    darwin) os="darwin" ;;
    *)      die "audictl drives CoreAudio and only runs on macOS (got: $os)" ;;
  esac

  case "$arch" in
    x86_64|amd64)   arch="x86_64" ;;
    aarch64|arm64)  arch="aarch64" ;;
    *)              die "Unsupported architecture: $arch (supported: x86_64, aarch64)" ;;
  esac

  echo "${os}-${arch}"
}

# ── Resolve version ─────────────────────────────────────────────────

resolve_version() {
  if [ -n "${AUDICTL_VERSION:-}" ]; then
    echo "$AUDICTL_VERSION"
    return
  fi

  local url="${BASE_URL}/latest"
  local version
  version="$(curl -fsSL "$url" 2>/dev/null)" \
    || die "Failed to fetch latest version from $url"
  version="$(echo "$version" | tr -d '[:space:]')"
  [ -n "$version" ] || die "Empty version returned from $url"
  echo "$version"
}

# ── Pick install directory ───────────────────────────────────────────

pick_install_dir() {
  if [ -n "${AUDICTL_INSTALL_DIR:-}" ]; then
    mkdir -p "$AUDICTL_INSTALL_DIR"
    echo "$AUDICTL_INSTALL_DIR"
    return
  fi

  if [ -w "/usr/local/bin" ]; then
    echo "/usr/local/bin"
  else
    local dir="${HOME}/.local/bin"
    mkdir -p "$dir"
    echo "$dir"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
  echo "Installing audictl..."

  local platform version install_dir
  platform="$(detect_platform)"
  version="$(resolve_version)"
  install_dir="$(pick_install_dir)"

  local archive="audictl-v${version}-${platform}.tar.gz"
  local url="${BASE_URL}/v${version}/${archive}"

  info "Version:  ${version}"
  info "Platform: ${platform}"
  info "From:     ${url}"
  info "To:       ${install_dir}/audictl"

  # Download + extract to temp dir
  tmpdir="$(mktemp -d)"  # global so EXIT trap can see it
  trap 'rm -rf "$tmpdir"' EXIT

  curl -fSL --progress-bar "$url" -o "${tmpdir}/${archive}" \
    || die "Download failed: ${url}"

  tar -xzf "${tmpdir}/${archive}" -C "$tmpdir" \
    || die "Failed to extract ${archive}"

  # Install
  chmod +x "${tmpdir}/audictl"
  mv "${tmpdir}/audictl" "${install_dir}/audictl" \
    || die "Failed to install to ${install_dir}/audictl (try: sudo or set AUDICTL_INSTALL_DIR)"

  # Verify
  if command -v audictl >/dev/null 2>&1; then
    local installed_version
    installed_version="$(audictl --version 2>/dev/null | head -1)"
    echo ""
    echo "Installed: audictl ${installed_version}"
  else
    echo ""
    echo "Installed to ${install_dir}/audictl"
    # Check if install_dir is in PATH
    case ":${PATH}:" in
      *":${install_dir}:"*) ;;
      *)
        echo ""
        echo "Add to your PATH:"
        echo "  export PATH=\"${install_dir}:\$PATH\""
        echo ""
        echo "Or add to your shell profile (~/.zshrc):"
        echo "  echo 'export PATH=\"${install_dir}:\$PATH\"' >> ~/.zshrc"
        ;;
    esac
  fi
}

main "$@"
