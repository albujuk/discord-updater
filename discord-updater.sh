#!/usr/bin/env bash
# Discord auto-updater. Checks discord.com for the latest Linux tarball,
# compares against the installed version, and does an atomic in-place swap
# when newer. Invoked by discord-updater.service on a daily timer.

# Strict mode:
#   -e  exit on any command failure
#   -u  unset variables are an error
#   -o pipefail  a pipeline fails if any stage fails (not just the last)
set -euo pipefail

# Paths. Respect XDG Base Directory spec; fall back to ~/.local/share.
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
DIST_PATH="$DATA_HOME/apps"
INSTALL_DIR="$DIST_PATH/Discord"          # where Discord lives
VERSION_FILE="$INSTALL_DIR/version"       # version stamp written after each install
BIN_DIR="$HOME/.local/bin"                # symlink target so `discord` is on PATH
APPS_DIR="$DATA_HOME/applications"        # XDG .desktop entries (menu integration)
DOWNLOAD_URL="https://discord.com/api/download?platform=linux&format=tar.gz"

# Private temp dir; trap guarantees cleanup even on error/interrupt.
TMP_DIR="$(mktemp -d -t discord-updater.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() { printf '[discord-updater] %s\n' "$*"; }
die() { printf '[discord-updater] error: %s\n' "$*" >&2; exit 1; }

# Even though the service has After=network-online.target, that target can
# resolve before DNS/HTTPS are actually usable (esp. on laptops). Poll the
# real endpoint with a short timeout before trusting the network.
wait_for_network() {
    local i
    for i in 1 2 3 4 5; do
        if curl -fsI -m 5 https://discord.com >/dev/null 2>&1; then
            return 0
        fi
        log "network not ready, retry $i/5"
        sleep 2
    done
    die "no network after 5 attempts"
}

# Trick: the download URL 302-redirects to a versioned tarball like
#   .../discord-0.0.123.tar.gz
# `curl -I -L -w '%{url_effective}'` follows redirects and prints the final
# URL without downloading the body. Then grep the x.y.z out of it.
# Avoids needing a real API call.
resolve_latest_version() {
    local url
    url=$(curl -fsLI -o /dev/null -w '%{url_effective}' -m 15 "$DOWNLOAD_URL") \
        || die "could not resolve latest version URL"
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$url" | head -n1
}

# Read installed version, stripping any stray whitespace/newline.
# `|| true` so missing file isn't a hard error under `set -e`.
current_version() {
    [[ -f "$VERSION_FILE" ]] && tr -d '[:space:]' <"$VERSION_FILE" || true
}

# Refuse to swap files under a running Electron app. It'll segfault or
# corrupt the session. Match by install path AND common process names
# (some launchers exec the binary differently).
discord_running() {
    pgrep -f "$INSTALL_DIR/discord" >/dev/null 2>&1 \
        || pgrep -x discord >/dev/null 2>&1 \
        || pgrep -x Discord >/dev/null 2>&1
}

# Caches and IPC sockets that survive across versions can wedge the new
# install. Wipe them after a successful swap.
cleanup_stale_state() {
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/discord"
    local tmp="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"

    # GPU/HTTP caches, safe to drop. Discord rebuilds them on next start.
    rm -rf "$cfg/Cache" "$cfg/GPUCache" 2>/dev/null || true

    # Known footgun: older Discord packages ran as root and left a
    # root-owned Crashpad dir that breaks subsequent user-mode launches.
    # If we see that, nuke it (we can't chown without sudo).
    local settings="$cfg/Crashpad/settings.dat"
    if [[ -f "$settings" ]] && [[ "$(stat -c '%U' "$settings" 2>/dev/null)" == "root" ]]; then
        rm -rf "$cfg/Crashpad" 2>/dev/null || true
    fi

    # Stale IPC socket left by an unclean shutdown blocks the next launch.
    rm -f "$tmp/discord.sock" 2>/dev/null || true
}

# Rewrite the bundled .desktop file to point at our install paths.
# The upstream file uses placeholders that assume /opt/Discord layout.
install_desktop_file() {
    local src="$INSTALL_DIR/discord.desktop"
    local dst="$APPS_DIR/discord.desktop"
    [[ -f "$src" ]] || { log "no discord.desktop in tarball, skip"; return; }
    mkdir -p "$APPS_DIR"
    # Patch Exec/Icon/Path so menu launchers find the binary and icon
    # regardless of the working directory at launch time.
    sed -E \
        -e "s|^Exec=.*|Exec=$INSTALL_DIR/discord %U|" \
        -e "s|^Icon=.*|Icon=$INSTALL_DIR/discord.png|" \
        -e "s|^Path=.*|Path=$INSTALL_DIR|" \
        "$src" >"$dst"
    chmod 644 "$dst"
    log "desktop file: $dst"
}

# Put a stable `discord` on $PATH (assumes ~/.local/bin is in PATH).
# `ln -sfn` replaces an existing symlink atomically.
install_binary_symlink() {
    [[ -x "$INSTALL_DIR/discord" ]] || { log "no discord binary, skip symlink"; return; }
    mkdir -p "$BIN_DIR"
    ln -sfn "$INSTALL_DIR/discord" "$BIN_DIR/discord"
    log "symlink: $BIN_DIR/discord -> $INSTALL_DIR/discord"
}

# Refresh the mimeinfo cache so the new .desktop entry shows up in menus
# right away. Tool is optional; ignore if missing.
update_desktop_database() {
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
}

# Download, verify, atomically swap, then refresh integration bits.
install_update() {
    local version="$1"
    local archive="$TMP_DIR/discord.tar.gz"

    log "downloading $version"
    # 10-minute timeout for the body download. -f makes curl fail on HTTP errors.
    curl -fSL -o "$archive" -m 600 "$DOWNLOAD_URL" \
        || die "download failed"

    # Defense in depth: an empty file or HTML error page would pass curl's
    # exit code on some mirrors. Validate the archive before trusting it.
    [[ -s "$archive" ]] || die "downloaded archive is empty"
    tar -tzf "$archive" >/dev/null 2>&1 \
        || die "downloaded archive is not a valid tarball"

    log "extracting to staging dir"
    local staging="$TMP_DIR/stage"
    mkdir -p "$staging"
    tar -xzf "$archive" -C "$staging"

    # Tarball must contain a top-level Discord/ directory. If upstream
    # changes the layout, fail loudly instead of installing garbage.
    [[ -d "$staging/Discord" ]] || die "tarball missing Discord/ root"

    # Last-chance check: bail if Discord started during the download window.
    if discord_running; then
        die "Discord is running, refusing to swap install. Quit Discord then re-run."
    fi

    # Atomic swap via rename. mv on the same filesystem is atomic at the
    # directory-entry level, so there's no window where INSTALL_DIR is
    # half-written. If the second mv fails, restore the backup.
    mkdir -p "$DIST_PATH"
    if [[ -d "$INSTALL_DIR" ]]; then
        local backup="$INSTALL_DIR.old.$$"     # $$ = our PID, makes name unique
        mv "$INSTALL_DIR" "$backup"
        if ! mv "$staging/Discord" "$INSTALL_DIR"; then
            mv "$backup" "$INSTALL_DIR"        # rollback
            die "swap failed, restored previous install"
        fi
        rm -rf "$backup"
    else
        mv "$staging/Discord" "$INSTALL_DIR"
    fi

    # Record the installed version so the next run can short-circuit.
    printf '%s\n' "$version" >"$VERSION_FILE"

    install_binary_symlink
    install_desktop_file
    update_desktop_database
    cleanup_stale_state

    log "installed Discord $version"
}

main() {
    wait_for_network

    local latest current
    latest=$(resolve_latest_version)
    [[ -n "$latest" ]] || die "could not parse latest version"
    current=$(current_version)

    # Fast path: already on latest AND binary is present+executable.
    # The -x check catches a corrupted install where the version file
    # is correct but the binary isn't usable.
    if [[ "$latest" == "$current" && -x "$INSTALL_DIR/discord" ]]; then
        log "up to date ($latest)"
        exit 0
    fi

    log "new version: $latest (current: ${current:-none})"
    install_update "$latest"
}

main "$@"
