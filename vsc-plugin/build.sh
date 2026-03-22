#!/usr/bin/env bash
# Build mcrepo VS Code extension and produce mcrepo.vsix
# Runs inside a Lima VM if node/npm is not available on the host.
#
# Usage:
#   ./build.sh                 # auto-detect: local node or Lima VM
#   ./build.sh --local         # force local build
#   ./build.sh --lima <name>   # force Lima VM build (name defaults to first running VM)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_VSIX="$SCRIPT_DIR/mcrepo.vsix"
BUILD_CMDS='cd /tmp/_mcrepo_vsc_build && npm install && npm run compile && npx vsce package --no-dependencies && cp mcrepo-multi-context-*.vsix /tmp/_mcrepo_vsc_build/mcrepo.vsix'

# --- helpers ----------------------------------------------------------------

build_local() {
  echo "Building VS Code extension locally..."
  cd "$SCRIPT_DIR"
  npm install
  npm run compile
  npx vsce package --no-dependencies
  # rename versioned file to fixed name
  cp mcrepo-multi-context-*.vsix "$OUT_VSIX"
  # remove versioned copy
  rm -f mcrepo-multi-context-*.vsix 2>/dev/null || true
  echo "Done: $OUT_VSIX"
}

build_lima() {
  local vm="$1"
  echo "Building VS Code extension in Lima VM '$vm'..."

  # Copy source into VM temp dir
  limactl shell "$vm" -- bash -c "rm -rf /tmp/_mcrepo_vsc_build && mkdir -p /tmp/_mcrepo_vsc_build" 2>&1

  rsync -a \
    --exclude node_modules \
    --exclude out \
    --exclude '*.vsix' \
    -e "ssh -p $(limactl list --format '{{if eq .Name "'"$vm"'"}}{{.SSHLocalPort}}{{end}}' 2>/dev/null || echo 22) \
        -o IdentityFile=/Users/$(whoami)/.lima/_config/user \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o NoHostAuthenticationForLocalhost=yes \
        -o PreferredAuthentications=publickey \
        -o IdentitiesOnly=yes" \
    "$SCRIPT_DIR/" \
    "$(whoami)@127.0.0.1:/tmp/_mcrepo_vsc_build/" 2>&1

  limactl shell "$vm" -- bash -c "$BUILD_CMDS" 2>&1

  # Copy result back
  local port
  port=$(limactl list --format '{{if eq .Name "'"$vm"'"}}{{.SSHLocalPort}}{{end}}' 2>/dev/null || echo 22)
  rsync -a \
    -e "ssh -p $port \
        -o IdentityFile=/Users/$(whoami)/.lima/_config/user \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o NoHostAuthenticationForLocalhost=yes \
        -o PreferredAuthentications=publickey \
        -o IdentitiesOnly=yes" \
    "$(whoami)@127.0.0.1:/tmp/_mcrepo_vsc_build/mcrepo.vsix" \
    "$OUT_VSIX" 2>&1

  echo "Done: $OUT_VSIX"
}

pick_lima_vm() {
  limactl list --format '{{if eq .Status "Running"}}{{.Name}}{{end}}' 2>/dev/null | head -1
}

# --- main -------------------------------------------------------------------

MODE="auto"
LIMA_VM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) MODE="local"; shift ;;
    --lima)  MODE="lima"; LIMA_VM="${2:-}"; shift; [[ -n "${2:-}" ]] && shift || true ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

case "$MODE" in
  local)
    build_local
    ;;
  lima)
    if [[ -z "$LIMA_VM" ]]; then
      LIMA_VM=$(pick_lima_vm)
      if [[ -z "$LIMA_VM" ]]; then
        echo "No running Lima VM found. Start one or pass --lima <name>."
        exit 1
      fi
    fi
    build_lima "$LIMA_VM"
    ;;
  auto)
    if command -v node &>/dev/null && command -v npm &>/dev/null; then
      build_local
    else
      LIMA_VM=$(pick_lima_vm)
      if [[ -n "$LIMA_VM" ]]; then
        echo "node/npm not found locally, using Lima VM '$LIMA_VM'."
        build_lima "$LIMA_VM"
      else
        echo "node/npm not found and no running Lima VM available."
        echo "Install node/npm or start a Lima VM, then re-run this script."
        exit 1
      fi
    fi
    ;;
esac
