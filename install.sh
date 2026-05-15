#!/usr/bin/env bash
# One-shot installer. Run once after cloning the repo.
# Drops the updater script into ~/.local/share/apps/Discord/, registers
# the user systemd service + timer, then kicks off the first update.
# No root needed; everything lives under $HOME.

set -euo pipefail

# Where the updater script will live (matches ExecStart= in the .service).
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
INSTALL_DIR="$DATA_HOME/apps/Discord"

# Standard XDG path for user systemd units. systemd --user scans this dir.
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# Resolve sibling files relative to THIS script, so the installer works
# no matter what the caller's $PWD is.
SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/discord-updater.sh"
SERVICE_SRC="$(cd "$(dirname "$0")" && pwd)/discord-updater.service"
TIMER_SRC="$(cd "$(dirname "$0")" && pwd)/discord-updater.timer"

# Bail early with a clear error if any source file is missing.
for f in "$SCRIPT_SRC" "$SERVICE_SRC" "$TIMER_SRC"; do
    [[ -f "$f" ]] || { echo "missing: $f" >&2; exit 1; }
done

mkdir -p "$INSTALL_DIR" "$UNIT_DIR"

# `install` = cp + chmod + mkdir in one syscall-light command.
#   0755 = rwx for owner, rx for group/other (executable script)
#   0644 = rw for owner, r for group/other (data file, unit files)
install -m 0755 "$SCRIPT_SRC"  "$INSTALL_DIR/discord-updater.sh"
install -m 0644 "$SERVICE_SRC" "$UNIT_DIR/discord-updater.service"
install -m 0644 "$TIMER_SRC"   "$UNIT_DIR/discord-updater.timer"

# Tell systemd to re-scan unit files in $UNIT_DIR. Required after adding
# or modifying unit files; otherwise systemctl won't see them.
systemctl --user daemon-reload

# enable  = create the WantedBy= symlink so the timer auto-starts at login
# --now   = also start it right now, so we don't have to log out/in
# Only the TIMER is enabled. The service is pulled in on demand when the
# timer fires (via the timer's Requires=).
systemctl --user enable --now discord-updater.timer

# Don't wait the 2-minute OnBootSec= window for the first update. Run
# the service directly so the user sees results immediately.
echo "installed. running first update now..."
systemctl --user start discord-updater.service
# `|| true` because oneshot services exit "inactive (dead)" on success,
# which `status` reports with a non-zero return code. We don't want that
# to abort the installer.
systemctl --user status --no-pager discord-updater.service || true

# Show the user how to inspect things going forward.
echo
echo "logs: journalctl --user -u discord-updater.service -f"
echo "timer: systemctl --user list-timers discord-updater.timer"
