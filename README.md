# Discord Updater

A user-level systemd timer that keeps the Linux Discord install fresh.
No root, no package manager, no daemon. Just a daily oneshot script
that downloads the latest tarball from `discord.com`, atomically swaps
the install, and exits.

## Files at a glance

| File | Role |
|------|------|
| `discord-updater.sh` | The actual updater (download, verify, atomic swap). |
| `discord-updater.service` | systemd **service** unit. *How* to run the script. |
| `discord-updater.timer`   | systemd **timer** unit. *When* to run the service. |
| `install.sh` | One-shot bootstrap: copies files into place and enables the timer. |

How they fit together: `install.sh` deploys the script and the two unit
files. The **timer** fires on a schedule and pulls in the **service**,
which executes the **script**.

---

## `discord-updater.service`, the "what to run"

```ini
[Unit]
Description=Discord version check and update
Documentation=https://discord.com
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/share/apps/Discord/discord-updater.sh
Nice=10

[Install]
WantedBy=default.target
```

A **service unit** tells systemd how to launch a process. Key bits:

### `[Unit]` section

- `After=network-online.target nss-lookup.target`: ordering only.
  Don't start until the network stack and DNS resolver are up. Ordering
  does not *pull these targets in*; it just sequences against them if
  they're already in the transaction.
- `Wants=network-online.target`: a soft dependency. Try to bring
  `network-online.target` up if it isn't already active. Soft means: if
  it can't be reached, this unit still runs. (`Requires=` is the hard
  variant.)
- Together these say: "wait for the network, but don't die if it's
  flaky." The script also retries on its own.

### `[Service]` section

- `Type=oneshot`: this is a script that runs to completion and exits,
  not a long-lived daemon. systemd marks the unit "active (running)"
  while the script runs and "inactive (dead)" after it exits cleanly.
  Perfect for an updater.
- `ExecStart=%h/.local/share/apps/Discord/discord-updater.sh`: `%h`
  is a systemd specifier that expands to the user's home directory
  (only meaningful for **user units**, which this is). Final path
  becomes e.g. `/home/<user>/.local/share/apps/Discord/discord-updater.sh`.
- `Nice=10`: lower CPU scheduling priority (range -20 high to 19 low).
  Updates shouldn't fight foreground work for CPU.

### `[Install]` section

- `WantedBy=default.target`: what `systemctl --user enable` would
  hook this into. In practice this matters less here because the
  **timer** is what gets enabled (see `install.sh`), and the timer
  pulls the service in via `Requires=` when it fires.

---

## `discord-updater.timer`, the "when to run"

```ini
[Unit]
Description=Periodic Discord update check
Requires=discord-updater.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=1d
Persistent=true
Unit=discord-updater.service

[Install]
WantedBy=timers.target
```

A **timer unit** is systemd's cron replacement. It triggers a service
unit on a schedule.

### `[Unit]` section

- `Requires=discord-updater.service`: declares the service this timer
  drives. If the service file is missing or fails to load, the timer
  fails too.

### `[Timer]` section

- `OnBootSec=2min`: fire 2 minutes after boot. For **user timers**
  this means 2 minutes after the user manager starts (typically login).
  Gives the network and session time to settle.
- `OnUnitActiveSec=1d`: after each successful run, wait 1 day before
  firing again. The cadence is "once per day from the last run," not
  "every day at midnight."
- `Persistent=true`: if the machine was off when the timer should
  have fired, run it on next boot to catch up. Without this you'd
  silently skip updates if the laptop is asleep during the scheduled
  window.
- `Unit=discord-updater.service`: explicit target service. Optional
  here because the timer shares a stem with the service (systemd would
  infer `discord-updater.service` from `discord-updater.timer`), but
  being explicit is good hygiene.

### `[Install]` section

- `WantedBy=timers.target`: when you `systemctl --user enable
  discord-updater.timer`, it gets pulled in as part of the user's
  `timers.target`, which activates all enabled timers at session start.
  So the timer auto-arms on login.

### Why two files?

Separation of concerns. The service describes *how* to run the job;
the timer describes *when*. You can run the service ad-hoc to force an
immediate update:

```sh
systemctl --user start discord-updater.service
```

That's exactly what `install.sh` does on the last step.

---

## `discord-updater.sh`, the actual updater

A Bash script doing the version check and atomic install. Walking the
interesting parts:

### Strict mode

```bash
set -euo pipefail
```

- `-e`: exit on any command failure.
- `-u`: unset variable use is an error.
- `-o pipefail`: a pipeline fails if any stage fails, not just the
  last one.

### Paths

Respects XDG Base Directory spec:

```bash
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
INSTALL_DIR="$DIST_PATH/Discord"
VERSION_FILE="$INSTALL_DIR/version"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$DATA_HOME/applications"
```

`version` is the version stamp written after each successful install;
the script reads it on the next run to decide whether to do anything.

### Temp dir + trap

```bash
TMP_DIR="$(mktemp -d -t discord-updater.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
```

`mktemp -d` creates a private temp dir. `trap ... EXIT` guarantees
cleanup even on failure or interrupt.

### `wait_for_network`

Even though the service has `After=network-online.target`, that target
can resolve before DNS/HTTPS are actually usable (especially on
laptops). The script polls `discord.com` with a short timeout, 5
retries by 2 seconds, before trusting the network.

### `resolve_latest_version`, the clever bit

```bash
url=$(curl -fsLI -o /dev/null -w '%{url_effective}' -m 15 "$DOWNLOAD_URL")
grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$url" | head -n1
```

Discord's download URL 302-redirects to a versioned tarball like
`.../discord-0.0.123.tar.gz`. `curl -I -L -w '%{url_effective}'`
follows redirects and prints the final URL **without downloading the
body**. Then a regex extracts the `x.y.z` version. No API call needed.

### `discord_running`

Refuses to swap files under a running Electron app, since that segfaults
or corrupts the session. Matches by install path *and* common process
names because different launchers exec the binary differently.

### `cleanup_stale_state`

Wipes caches and IPC sockets that survive across versions and can
wedge the new install:

- `Cache` and `GPUCache`: safe to drop; Discord rebuilds them on next
  start.
- `Crashpad`: only nuked if owned by root. This is a known footgun
  from older Discord packages that ran as root and left a root-owned
  dir that breaks subsequent user-mode launches.
- `/tmp/discord.sock`: stale IPC socket from an unclean shutdown
  blocks the next launch.

### `install_update`, the atomic swap

```bash
mv "$INSTALL_DIR" "$backup"           # rename current to backup
mv "$staging/Discord" "$INSTALL_DIR"  # rename new to current
rm -rf "$backup"
```

Atomic swap via rename. `mv` on the same filesystem is atomic at the
directory-entry level, so there's no window where `INSTALL_DIR` is
half-written. If the second `mv` fails, the script restores the backup.

Before the swap it also:

1. Downloads to a temp file (10-minute timeout).
2. Validates the archive is non-empty and a valid tarball. Defense
   in depth, because an HTML error page from a mirror would pass
   curl's exit code.
3. Extracts to a staging directory.
4. Verifies the tarball has a top-level `Discord/` directory.
5. Re-checks `discord_running` last-chance, in case the user launched
   Discord during the download window.

After the swap it writes the version stamp, refreshes the binary
symlink and `.desktop` entry, runs `update-desktop-database`, and
cleans stale state.

### `.desktop` rewriting

The bundled `.desktop` file uses placeholders that assume a system
install at `/opt/Discord`. The script `sed`-patches `Exec=`, `Icon=`,
and `Path=` to absolute paths under `$INSTALL_DIR` so menu launchers
find the binary and icon regardless of CWD.

---

## `install.sh`, the one-shot bootstrap

```bash
SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/discord-updater.sh"
```

Resolves source paths relative to the installer itself, so you can run
it from anywhere.

```bash
install -m 0755 "$SCRIPT_SRC"  "$INSTALL_DIR/discord-updater.sh"
install -m 0644 "$SERVICE_SRC" "$UNIT_DIR/discord-updater.service"
install -m 0644 "$TIMER_SRC"   "$UNIT_DIR/discord-updater.timer"
```

`install` is `cp` + `chmod` + dir creation in one step. `0755` makes
the script executable; `0644` is standard read-only for data files.

The unit files go in `~/.config/systemd/user/`, the standard XDG path
for **user units**. Runs as you, no root.

```bash
systemctl --user daemon-reload
systemctl --user enable --now discord-updater.timer
systemctl --user start discord-updater.service
```

- `daemon-reload`: tells systemd to re-scan unit files in `$UNIT_DIR`.
  Required after adding or modifying units.
- `enable --now`: creates the `WantedBy=` symlink so the timer
  auto-starts at login, *and* starts it right now.
- `start ...service`: kicks off the first update immediately rather
  than waiting the 2-minute `OnBootSec=` window.

Only the **timer** is enabled. The service is pulled in on demand when
the timer fires.

---

## Mental model of the schedule

```
[boot/login]
   |
   '- 2 min later --> timer fires --> service runs --> script runs
                                              |
                                              '- on success, timer waits 1d
                                                 (Persistent=true: catches up
                                                  if you missed a window)
```

---

## Usage

### Install

```sh
./install.sh
```

That's it. Subsequent updates happen automatically once per day.

### Useful commands

| Command | Purpose |
|---------|---------|
| `systemctl --user list-timers discord-updater.timer` | When does it fire next? |
| `journalctl --user -u discord-updater.service -f` | Live log of runs. |
| `systemctl --user start discord-updater.service` | Run now, don't wait. |
| `systemctl --user disable --now discord-updater.timer` | Stop scheduling updates. |
| `cat ~/.local/share/apps/Discord/version` | Currently installed version. |

### Uninstall

```sh
systemctl --user disable --now discord-updater.timer
rm ~/.config/systemd/user/discord-updater.{service,timer}
rm -rf ~/.local/share/apps/Discord
rm -f ~/.local/bin/discord
rm -f ~/.local/share/applications/discord.desktop
systemctl --user daemon-reload
```

---

## Why this design?

- **User units, not system units.** No root, no sudo, no risk of a
  bad update bricking a shared install. Each user gets their own
  Discord on their own schedule.
- **`oneshot` + timer, not a daemon.** No long-lived process; the
  updater consumes zero resources between runs.
- **Atomic rename-based swap.** Standard pattern for safe in-place
  upgrades. Either you have the old version or the new version,
  never a corrupted half-state.
- **Refuses to update while Discord is running.** Replacing files
  under a running Electron app corrupts the session.
- **`Persistent=true` on the timer.** Laptops are off most of the
  time; without this you'd silently miss days.
- **Defensive download validation.** Empty file? HTML error page? The
  script catches it before nuking your working install.
