# AGENTS.md — PROPOSED V2 CONTENT
#
# NOTE FROM THE V2 BUILD (kanban task t_da70841a): the harness protects
# AGENTS.md from unattended agent writes, so this file carries the proposed
# replacement. A human should review it and copy it over AGENTS.md.

# crusty-system

Single-file Debian/Ubuntu server hardening wizard.

## Stack
- **Language:** Bash (Debian/Ubuntu only — Alpine support was dropped in V2)
- **No build tools, no runtime dependencies, no runtime downloads**

## Conventions
- `crusty.sh` is the whole product — self-contained and idempotent (re-run converges; second run with same answers = zero applied changes)
- Security-first; lockout-safety patterns are ported verbatim and TAGGED in comments: C1 (key-for-non-root + verify-before-restrictions), C2 (sshd pre-flight/atomic/rollback), C3 (port-transition UFW choreography), H1 (fail2ban reload-never-restart), H4 (sshd_config.d neutralization), H5 (KbdInteractive probe), H10 (key validator), M3 (daemon.json jq-merge), M5/M6/M7, G6 (fail2ban systemd backend). Do not re-derive these — the tags are the spec.
- `set -Eeuo pipefail` from line 1; ERR/EXIT/INT/TERM/HUP traps; no bare `read` anywhere (TTY-gated, reads /dev/tty)
- Whiptail primary UI with plain-read fallback; ASCII markers `[+] [!] [x] [i]`, no emoji, no colors
- Functions < 60 lines, rigid section order (primitives → arg parse → preflight → ask → plan+confirm → apply → verify)
- **CRON RULE (never break): the maintenance cron line must contain ZERO `%` characters** — cron truncates the command at the first unescaped %. `date -Is` is used for this reason. A runtime self-check + CI grep guard enforce it.
- PVE hosts are hard-refused before any mutation; LXC/VM/bare share ONE uniform apply path — UFW/fail2ban fail soft at apply time in containers (rollback + skip recorded in /etc/crusty.conf)
- State file /etc/crusty.conf: KEY=VALUE, 0644, no secrets, rewritten from scratch each successful run; "created/added by crusty" facts are sticky across re-runs (uid-guarded)
- Secrets: passwords only via chpasswd stdin, never argv, never logged

## Files
- `crusty.sh` — the whole product (wizard, hardening, maintenance, uninstall)
- `README.md` — product docs (wizard flow, flags, env matrix, cron details)
- `.github/workflows/shellcheck.yml` — CI

## Key Commands
```bash
# Syntax + lint (both must be clean before commit)
bash -n crusty.sh
shellcheck crusty.sh

# Safe preview on a box (zero mutations)
sudo bash crusty.sh --dry-run --yes --user NAME --ssh-key "ssh-ed25519 AAAA..."

# Cron %-free guard (CI also runs this)
grep 'root flock' crusty.sh | grep '%' && echo 'FAIL: % in the cron command line' || echo OK
```