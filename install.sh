#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
GITHUB_REPO="${GITHUB_REPO:-terminal-use/sb0-cli}"
BINARY_NAME="sb0"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
REQUESTED_VERSION="${SB0_VERSION:-}"
HTTP_CLIENT=""
AUTH_ARGS=()
DATA_DIR=""

default_data_dir() {
    local home="${HOME:-}"
    if [ -z "$home" ]; then
        echo "/tmp/sb0"
        return
    fi

    case "$(uname -s)" in
        Darwin*) echo "$home/Library/Application Support/sb0" ;;
        *)       echo "$home/.local/share/sb0" ;;
    esac
}

log_info() {
    echo -e "${GREEN}==>${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}Warning:${NC} $1" >&2
}

log_error() {
    echo -e "${RED}Error:${NC} $1" >&2
}

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Options:
  -v, --version <version>  Install a specific sb0 release tag (with or without leading v)
  -h, --help               Show this help message

Environment overrides:
  GITHUB_REPO     Repository to download from (default: terminal-use/sb0-cli)
  GITHUB_TOKEN    Personal access token for private releases
  INSTALL_DIR     Installation directory (default: ~/.local/bin)
  SB0_VERSION     Same as --version
  SB0_DATA_DIR    Base directory for sb0 data (default: platform specific)
  SB0_WHEELS_DIR  Override wheel storage directory (default: $SB0_DATA_DIR/wheels)
  SB0_TEMPLATE_DIR Override template storage directory (default: $SB0_DATA_DIR/templates)
EOF
}

setup_http_client() {
    if command -v curl >/dev/null 2>&1; then
        HTTP_CLIENT="curl"
    elif command -v wget >/dev/null 2>&1; then
        HTTP_CLIENT="wget"
    else
        log_error "Neither curl nor wget found. Please install one of them."
        exit 1
    fi

    AUTH_ARGS=()
    if [ -n "$GITHUB_TOKEN" ]; then
        if [ "$HTTP_CLIENT" = "curl" ]; then
            AUTH_ARGS=(-H "Authorization: token $GITHUB_TOKEN")
        else
            AUTH_ARGS=(--header="Authorization: token $GITHUB_TOKEN")
        fi
    fi
}

http_fetch() {
    local url="$1"
    if [ "$HTTP_CLIENT" = "curl" ]; then
        if [ "${#AUTH_ARGS[@]}" -gt 0 ]; then
            curl -fsSL "${AUTH_ARGS[@]}" "$url"
        else
            curl -fsSL "$url"
        fi
    else
        if [ "${#AUTH_ARGS[@]}" -gt 0 ]; then
            wget -qO- "${AUTH_ARGS[@]}" "$url"
        else
            wget -qO- "$url"
        fi
    fi
}

http_download() {
    local url="$1"
    local output="$2"
    if [ "$HTTP_CLIENT" = "curl" ]; then
        if [ "${#AUTH_ARGS[@]}" -gt 0 ]; then
            curl -fsSL "${AUTH_ARGS[@]}" -o "$output" "$url"
        else
            curl -fsSL -o "$output" "$url"
        fi
    else
        if [ "${#AUTH_ARGS[@]}" -gt 0 ]; then
            wget -q "${AUTH_ARGS[@]}" -O "$output" "$url"
        else
            wget -q -O "$output" "$url"
        fi
    fi
}

detect_platform() {
    local os=""
    local arch=""

    case "$(uname -s)" in
        Linux*)  os="linux";;
        Darwin*) os="macos";;
        *)       log_error "Unsupported operating system: $(uname -s)"; exit 1;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)  arch="x64";;
        aarch64|arm64) arch="arm64";;
        *)             log_error "Unsupported architecture: $(uname -m)"; exit 1;;
    esac

    echo "${os}-${arch}"
}

validate_version() {
    local version="$1"
    if ! [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z._-]+)?$ ]]; then
        log_error "Invalid version format: $version"
        exit 1
    fi
}

normalize_version() {
    local version="$1"
    if [[ "$version" != v* ]]; then
        version="v$version"
    fi
    echo "$version"
}

get_latest_version() {
    local response=""
    local release_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    if ! response=$(http_fetch "$release_url"); then
        log_error "Failed to get latest release version"
        if [ -z "$GITHUB_TOKEN" ]; then
            log_error "If this is a private repository, set GITHUB_TOKEN environment variable"
        fi
        exit 1
    fi

    local version
    version=$(printf '%s\n' "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | cut -d'"' -f4)

    if [ -z "$version" ]; then
        log_error "Failed to parse release version"
        exit 1
    fi

    validate_version "$version"
    echo "$version"
}

download_binary() {
    local version="$1"
    local platform="$2"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local download_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${BINARY_NAME}-${platform}"

    log_info "Downloading ${BINARY_NAME} ${version} for ${platform}..."
    if ! http_download "$download_url" "${tmp_dir}/${BINARY_NAME}"; then
        log_error "Failed to download binary"
        if [ -z "$GITHUB_TOKEN" ]; then
            log_error "If this is a private repository, set GITHUB_TOKEN environment variable"
        fi
        rm -rf "$tmp_dir"
        exit 1
    fi

    echo "$tmp_dir"
}

download_wheels_archive() {
    local version="$1"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local version_plain="${version#v}"
    local archive_name="sb0-wheels-${version_plain}.tar.gz"
    local download_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${archive_name}"

    log_info "Downloading embedded wheels (${archive_name})..."
    if ! http_download "$download_url" "${tmp_dir}/${archive_name}"; then
        log_error "Failed to download wheels archive"
        if [ -z "$GITHUB_TOKEN" ]; then
            log_error "If this is a private repository, set GITHUB_TOKEN environment variable"
        fi
        rm -rf "$tmp_dir"
        exit 1
    fi

    echo "$tmp_dir"
}

install_wheels() {
    local tmp_dir="$1"
    local version="$2"
    local version_plain="${version#v}"
    local archive_name="sb0-wheels-${version_plain}.tar.gz"
    local target_base="${SB0_WHEELS_DIR:-$DATA_DIR/wheels}"
    local target_dir="${target_base}/${version_plain}"

    log_info "Installing embedded wheels to $target_dir"
    rm -rf "$target_dir"
    mkdir -p "$target_dir"

    if ! tar -xzf "${tmp_dir}/${archive_name}" -C "$target_dir"; then
        log_error "Failed to extract wheels archive"
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
}

download_templates_archive() {
    local version="$1"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local version_plain="${version#v}"
    local archive_name="sb0-templates-${version_plain}.tar.gz"
    local download_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${archive_name}"

    log_info "Downloading templates (${archive_name})..."
    if ! http_download "$download_url" "${tmp_dir}/${archive_name}"; then
        log_error "Failed to download templates archive"
        if [ -z "$GITHUB_TOKEN" ]; then
            log_error "If this is a private repository, set GITHUB_TOKEN environment variable"
        fi
        rm -rf "$tmp_dir"
        exit 1
    fi

    echo "$tmp_dir"
}

install_templates() {
    local tmp_dir="$1"
    local version="$2"
    local version_plain="${version#v}"
    local archive_name="sb0-templates-${version_plain}.tar.gz"
    local target_base="${SB0_TEMPLATE_DIR:-$DATA_DIR/templates}"
    local target_dir="${target_base}/${version_plain}"

    log_info "Installing templates to $target_dir"
    rm -rf "$target_dir"
    mkdir -p "$target_dir"

    if ! tar -xzf "${tmp_dir}/${archive_name}" -C "$target_dir"; then
        log_error "Failed to extract templates archive"
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
}

write_assets_version() {
    local version="$1"
    local version_plain="${version#v}"
    local version_file="$DATA_DIR/assets-version"
    mkdir -p "$DATA_DIR"
    printf "%s" "$version_plain" > "$version_file"
}

install_binary() {
    local tmp_dir="$1"

    if [ ! -d "$INSTALL_DIR" ]; then
        log_info "Creating install directory: $INSTALL_DIR"
        mkdir -p "$INSTALL_DIR"
    fi

    log_info "Installing to $INSTALL_DIR/$BINARY_NAME"
    mv "${tmp_dir}/${BINARY_NAME}" "$INSTALL_DIR/$BINARY_NAME"
    chmod +x "$INSTALL_DIR/$BINARY_NAME"
    rm -rf "$tmp_dir"
}

check_path() {
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        log_warn "$INSTALL_DIR is not in your PATH"
        echo ""
        echo "Add the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
        echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
        echo ""
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--version)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing value for $1"
                    usage
                    exit 1
                fi
                REQUESTED_VERSION="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    log_info "Installing sb0..."

    setup_http_client

    DATA_DIR="${SB0_DATA_DIR:-$(default_data_dir)}"
    mkdir -p "$DATA_DIR"

    local platform
    platform=$(detect_platform)
    log_info "Detected platform: $platform"

    local version
    if [ -n "$REQUESTED_VERSION" ]; then
        version=$(normalize_version "$REQUESTED_VERSION")
        validate_version "$version"
    else
        version=$(get_latest_version)
    fi
    log_info "Using version: $version"

    local tmp_dir
    tmp_dir=$(download_binary "$version" "$platform")

    install_binary "$tmp_dir"

    local wheels_tmp_dir
    wheels_tmp_dir=$(download_wheels_archive "$version")
    install_wheels "$wheels_tmp_dir" "$version"

    local templates_tmp_dir
    templates_tmp_dir=$(download_templates_archive "$version")
    install_templates "$templates_tmp_dir" "$version"
    write_assets_version "$version"
    check_path

    log_info "Successfully installed sb0!"
    log_info "Run 'sb0 --help' to get started"
}

main "$@"
