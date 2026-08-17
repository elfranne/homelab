#!/usr/bin/env bash
#
# postCreateCommand for the homelab dev container. Runs once, as `vscode`, after the
# container is created and the features have been installed. Idempotent — a rebuild
# re-runs it and it must be a no-op the second time.
set -Eeuo pipefail

log() { printf '\033[36m[..]\033[0m %s\n' "$*"; }
ok() { printf '\033[32m[OK]\033[0m %s\n' "$*"; }

# Podman creates named volumes owned by root, and unlike Docker Desktop the Dev
# Containers extension does not reliably fix the ownership afterwards. Claude Code
# cannot write credentials into a root-owned ~/.claude and the resulting login
# failure is opaque, so take ownership before anything else runs.
for dir in "$HOME/.claude" /commandhistory; do
  if [ -d "$dir" ] && [ ! -w "$dir" ]; then
    log "taking ownership of $dir"
    sudo chown -R "$(id -u):$(id -g)" "$dir"
  fi
done
ok "volumes writable"

# uv is the one thing worth installing globally here: it makes every *future* Python
# tool ephemeral (`uv run --with <pkg>`), so no other package ever has to be baked
# into the image or dropped into a venv. Safe to install globally because the whole
# container is disposable.
if ! command -v uv >/dev/null 2>&1; then
  log "installing uv"
  curl -fsSL https://astral.sh/uv/install.sh | sh
fi

# `command -v` returning non-zero is the normal case for an absent tool, so guard it
# — an unguarded failure here would abort the whole script under `set -e`.
version_of() {
  local cmd=$1 out
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'MISSING'
    return 0
  fi
  # Capture first, then match — deliberately not a pipeline. `grep -m1` exits on the
  # first hit, which hands SIGPIPE to a still-writing producer like `incus version`,
  # and `pipefail` would report the whole pipeline as failed despite the match.
  out=$("$@" 2>&1) || true
  # First line carrying a version number, not simply the first line — shellcheck
  # leads with a blank line and a banner before it says anything useful.
  grep -m1 -E '[0-9]+\.[0-9]+' <<<"$out" || printf 'unknown'
}

printf '\n  %-12s %s\n' "tool" "version"
printf '  %-12s %s\n' "----" "-------"
printf '  %-12s %s\n' bash "$(version_of bash --version)"
printf '  %-12s %s\n' shellcheck "$(version_of shellcheck --version)"
printf '  %-12s %s\n' shfmt "$(version_of shfmt --version)"
printf '  %-12s %s\n' yamllint "$(version_of yamllint --version)"
printf '  %-12s %s\n' python3 "$(version_of python3 --version)"
printf '  %-12s %s\n' node "$(version_of node --version)"
printf '  %-12s %s\n' gh "$(version_of gh --version)"
printf '  %-12s %s\n' incus "$(version_of incus version)"
printf '  %-12s %s\n' claude "$(version_of claude --version)"
printf '  %-12s %s\n' uv "$(version_of "$HOME/.local/bin/uv" --version)"
printf '\n'

ok "dev container ready — run 'claude' to sign in on first use"
