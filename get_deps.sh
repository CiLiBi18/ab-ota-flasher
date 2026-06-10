#!/usr/bin/env bash
#
# get_deps.sh — Télécharge fastboot, adb et payload-dumper-go dans ./bin/
#
# Usage : ./get_deps.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${BLUE}[*]${NC} $*"; }
ok()  { echo -e "${GREEN}[OK]${NC} $*"; }
die() { echo -e "${RED}[X]${NC} $*" >&2; exit 1; }

command -v curl  >/dev/null || die "curl introuvable. Installe-le avec : sudo apt install curl"
command -v unzip >/dev/null || die "unzip introuvable. Installe-le avec : sudo apt install unzip"

mkdir -p "$BIN_DIR"

# ---- Détection OS / architecture ----------------------------------------
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)   ARCH_GO="amd64" ; ARCH_LABEL="x86_64" ;;
  aarch64|arm64)  ARCH_GO="arm64" ; ARCH_LABEL="arm64"  ;;
  *) die "Architecture non supportée : $ARCH" ;;
esac

case "$OS" in
  linux)  PT_OS="linux"  ; GO_OS="linux"   ;;
  darwin) PT_OS="darwin" ; GO_OS="darwin"  ;;
  *) die "OS non supporté : $OS" ;;
esac

# ---- Android Platform Tools (fastboot + adb) ----------------------------
PT_URL="https://dl.google.com/android/repository/platform-tools-latest-${PT_OS}.zip"
PT_ZIP="$(mktemp /tmp/platform-tools-XXXXXX.zip)"

log "Téléchargement de platform-tools (fastboot + adb) pour ${OS}/${ARCH_LABEL}…"
curl -fL --progress-bar "$PT_URL" -o "$PT_ZIP"

log "Extraction de fastboot et adb…"
unzip -jo "$PT_ZIP" platform-tools/fastboot platform-tools/adb -d "$BIN_DIR"
chmod +x "$BIN_DIR/fastboot" "$BIN_DIR/adb"
rm -f "$PT_ZIP"

ok "fastboot : $BIN_DIR/fastboot  ($("$BIN_DIR/fastboot" --version 2>&1 | head -n1))"
ok "adb      : $BIN_DIR/adb       ($("$BIN_DIR/adb" version 2>&1 | head -n1))"

# ---- payload-dumper-go ---------------------------------------------------
log "Récupération de la dernière version de payload-dumper-go…"

PDGO_API="https://api.github.com/repos/ssut/payload-dumper-go/releases/latest"
PDGO_TAG="$(curl -fsSL "$PDGO_API" | grep '"tag_name"' | cut -d'"' -f4)"
[[ -n "$PDGO_TAG" ]] || die "Impossible de récupérer la dernière version de payload-dumper-go."
PDGO_VER="${PDGO_TAG#v}"

PDGO_FILE="payload-dumper-go_${PDGO_VER}_${GO_OS}_${ARCH_GO}.tar.gz"
PDGO_URL="https://github.com/ssut/payload-dumper-go/releases/download/${PDGO_TAG}/${PDGO_FILE}"
PDGO_TGZ="$(mktemp /tmp/payload-dumper-go-XXXXXX.tar.gz)"

log "Téléchargement de payload-dumper-go ${PDGO_TAG} pour ${GO_OS}/${ARCH_GO}…"
curl -fL --progress-bar "$PDGO_URL" -o "$PDGO_TGZ"

log "Extraction…"
tar xzf "$PDGO_TGZ" -C "$BIN_DIR" payload-dumper-go
chmod +x "$BIN_DIR/payload-dumper-go"
rm -f "$PDGO_TGZ"

ok "payload-dumper-go : $BIN_DIR/payload-dumper-go  ($("$BIN_DIR/payload-dumper-go" -h 2>&1 | head -n1 || true))"

echo
ok "Toutes les dépendances sont installées dans $BIN_DIR"
echo "    Tu peux maintenant utiliser ./flash_ota.sh normalement."
