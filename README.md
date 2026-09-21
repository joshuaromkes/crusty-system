# crusty

> **Note:** This codebase was developed with AI assistance. Review and test thoroughly before deploying in production environments.

Single-file Debian/Ubuntu server hardening wizard. One file, no downloads at runtime, no module scripts — `crusty.sh` is the whole product.

## What it does

Interactive-first wizard (whiptail, plain-read fallback, headless flags) that:

1. Creates or reuses a dedicated non-root admin user (never root — a root-only key behind `PermitRootLogin no` is a guaranteed lockout)
2. Installs your SSH public key for that user, **verified before any auth restriction is applied**
3. Hardens sshd: custom port, password auth off, root login off, modern ciphers, pre-flight `sshd -t` + atomic swap + rollback on failure
4. Enables UFW (existing rules preserved — never reset), keeping the old SSH port reachable during port transitions
5. fail2ban sshd jail with the **systemd backend** (no logpath, works on fresh Debian 12 / Ubuntu 24.04), reloaded — never restarted
6. Optional Docker Engine from the official repo with a hardened, **merged** daemon.json
7. Weekly LOCAL maintenance cron: apt update/upgrade/autoremove/autoclean with conffile-safe options, serialized by flock, reboot only when the OS flags it. **It never downloads anything** — updates to crusty itself are re-running the script.

State lives in `/etc/crusty.conf` (0644, no secrets). Re-running crusty **converges**: a second run with the same answers applies zero changes, and it also heals relics from the old V1 multi-script layout (legacy cron files, `/opt/crusty-system`).

## Install (read what you run — two steps)

```bash
curl -fsSLo crusty.sh https://raw.githubusercontent.com/joshuaromkes/crusty-system/main/crusty.sh
less crusty.sh
sudo bash crusty.sh
```

`curl | sudo bash` also works, but you can't read the script first — the two-step form is recommended. Note: a piped script cannot self-elevate; use the two-step form when running as a non-root user.

## Wizard flow

Preflight (OS + environment detection) → collect everything up front (≤9 prompts: admin user, password ×2, sudo, SSH key, port, firewall, modules, docker user, maintenance time) → plan display → final confirm → strictly non-interactive apply with `[+]` progress lines → summary with the connect string.

Log: `/var/log/crusty-install.log`.

## Flags

A flag pre-fills its answer and skips its prompt. `--yes` takes defaults for the rest. **Headless runs (no TTY — `curl | bash`, CI) require `--user` and `--yes`;** `--ssh-key` is required too unless the state file already records a valid key for the user (re-run convenience: a module-flip re-run never re-declares a key). The account stays password-locked (key-only) by design in headless mode — there is no `--password` flag because argv leaks through `ps` and shell history.

```
--user NAME              admin user (refuses root; created if absent, reused if present)
--ssh-key KEY            public key (paste or path to a .pub file), validated;
                         optional on re-runs when the state file records a valid key
--sudo / --no-sudo       add the admin user to the 'sudo' group (interactive
                         default: no in LXC, yes on VM/bare; re-runs pre-fill
                         the previous choice)
--port N                 SSH port, default 22
--firewall / --no-firewall   UFW on top of any detected firewall stack
                         (interactive pre-flight: warns and asks before layering
                         UFW on a non-UFW stack; reviews existing rules and
                         inbound listeners; --no-firewall skips UFW outright)
--docker / --no-docker   Docker module (default: no)
--docker-user NAME       docker group member (default: the admin user; implies --docker)
--fail2ban / --no-fail2ban   default: yes
--maintenance / --no-maintenance   default: yes
--time HH:MM             maintenance time, default 02:00 Sunday
--tcp-forwarding no|local|yes    flag only (no wizard prompt), default no
--dry-run                show the plan, zero changes
--yes                    skip the final confirmation
--uninstall              remove exactly what crusty owns (shows the plan first)
--help
```

## Environment matrix

| Environment | Detection | Behavior |
|---|---|---|
| PVE **host** | `/etc/pve/.node_name` or `pveversion` | **Hard refusal, before any mutation** — hardening breaks PVE cluster root SSH. See [pve.proxmox.com/wiki/Security](https://pve.proxmox.com/wiki/Security) |
| LXC (privileged / unprivileged) | cgroup/container markers + `/proc/self/uid_map` | Fully supported. UFW works in unprivileged LXCs (per-netns netfilter, userns NET_ADMIN) and protects the container itself; if the apply still fails for lack of capability, UFW/fail2ban roll back, warn, and the skip is recorded in `/etc/crusty.conf` — never fatal. sudo prompt defaults to no (the PVE console is the admin path) |
| PVE VM | `systemd-detect-virt` (kvm/qemu/...) | Fully supported |
| Bare metal | `systemd-detect-virt` none | Fully supported |

LXC notes:

- **Docker in LXC** requires `features: nesting=1` (+ `keyctl=1` for unprivileged) in the pct config — set on the PVE host side, crusty can't fix it and prints the requirement.
- **A container firewall protects the container, not the host.** The PVE/datacenter boundary is the real firewall; crusty prints this caveat on every container run.
- `sudo` defaults to no inside containers (PVE console is the admin path); pass it interactively or with `--sudo` / `--no-sudo`.

## Weekly maintenance cron

`/etc/cron.d/crusty-maintenance` (0644) runs every Sunday at the configured time:

- `flock`-serialized, all output appended to `/var/log/crusty-maintenance.log`
- `DEBIAN_FRONTEND=noninteractive` + `--force-confdef/--force-confold` so a conffile prompt can never stall the headless run
- Sequential steps (an update failure still attempts upgrade/autoremove/autoclean)
- Reboots only when `/var/run/reboot-required` exists, with a 5-minute grace warning
- **Never downloads anything** — no network fetches in cron, ever

> `%` WARNING: cron turns the first unescaped `%` into a newline and truncates the command (man 5 crontab). The crusty cron line is deliberately `%`-free (it uses `date -Is`). CI guards against regressions — never "fix" the date format to `+%F` style.

## Docker + UFW truth

Any port published with `-p` is reachable from the network **even with `ufw default deny incoming`** — Docker's iptables rules run before UFW's. Mitigate by publishing to loopback (`-p 127.0.0.1:8080:80`) or filtering via the DOCKER-USER chain.

## Docker image pruning (manual, if you want it)

Crusty deliberately ships no prune cron (minimal-cron ethos). If you reintroduce one: prune **images only** — `docker image prune -af --filter "until=168h"`. NEVER `docker system prune` and NEVER `--volumes` — volume deletion has destroyed data of stopped-but-kept stacks.

## Uninstall

```bash
sudo bash crusty.sh --uninstall
```

Shows the removal plan and asks for confirmation (or `--yes`). Removes exactly what crusty owns: the maintenance cron, the state file, the fail2ban jail (only if crusty wrote it), crusty's UFW port rule, restores the pre-crusty sshd_config from the oldest backup, removes group memberships crusty added, and deletes the admin user + home **only if crusty created it and the uid still matches**. Pre-existing users are never touched. V1 relics are cleaned up too. Backups under `/root/crusty-backups-*` are kept.

## Development

```bash
bash -n crusty.sh          # syntax check
shellcheck crusty.sh       # must be clean (CI enforces both)
```

Conventions: `set -Eeuo pipefail` from line 1; rigid section order (primitives → arg parse → preflight → ask → plan → apply → verify); functions < 60 lines; no bare `read` (all prompts are TTY-gated and read `/dev/tty`); ASCII-only output markers; no secrets in argv, logs, or the state file.

## Contributing

PRs welcome: test on a fresh Debian/Ubuntu VM (or a disposable LXC), keep `bash -n` + `shellcheck` clean, never weaken the tagged lockout-safety patterns (C1/C2/C3/H1/H4/H5/H10/M3/M5/M6/M7/G6), and keep the cron line `%`-free.

## License

MIT