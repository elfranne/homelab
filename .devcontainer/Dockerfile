# Authoring environment for this repo — see README.md, "Development container".
#
# Debian Trixie on purpose: the same release the NAS runs, so the incus client and
# the linters here match what steps 0–2 actually target. Nothing in this image ever
# runs on the box itself.
FROM mcr.microsoft.com/devcontainers/base:trixie

# Distro packages only — no upstream tarballs, no `latest` URLs — so a rebuild in six
# months yields the image these docs describe. python3-yaml is here rather than in a
# venv because the distrobuilder definitions only ever need to be parsed and schema
# checked, and the `python` feature below is pinned to the same os-provided interpreter.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      incus-client \
      jq \
      python3-yaml \
      ripgrep \
      shellcheck \
      shfmt \
      yamllint \
 && rm -rf /var/lib/apt/lists/*
