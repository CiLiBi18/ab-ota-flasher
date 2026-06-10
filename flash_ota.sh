#!/usr/bin/env bash
#
# flash_ota.sh — Flash une OTA Android A/B via fastboot
# Dépôt  : https://github.com/CiLiBi18/ab-ota-flasher
# Aide   : ./flash_ota.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"

# ------------------------------------------------------------------ couleurs
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[X]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

# ------------------------------------------------------------------ aide
show_help() {
  cat << 'HELP'

USAGE
  ./flash_ota.sh <ota.zip> [image_perso.img] [OPTIONS]

ARGUMENTS
  ota.zip           Fichier ZIP de l'OTA (doit contenir un payload.bin A/B)
  image_perso.img   (Optionnel) Image à flasher après l'OTA.
                    La partition cible est déduite du nom du fichier :
                      init_boot_magisk.img  →  init_boot
                      boot_patched.img      →  boot
                      vendor_boot_ksu.img   →  vendor_boot
                    Suffixes reconnus : _magisk, _patched, _root, _rooted,
                                        _ksu, _kernelsu, _apatch, _mod

OPTIONS
  --ota-no-flash    Extrait les images sans flasher l'OTA.
                    Si une image perso est fournie, elle est flashée quand même.
  --force-extract   Force la ré-extraction même si les images existent déjà.
  -h, --help        Affiche cette aide.

DÉPENDANCES
  Les outils suivants sont cherchés en priorité dans ./bin/ (peuplé par
  get_deps.sh), puis dans le PATH système :
    fastboot          (Android platform-tools)
    adb               (Android platform-tools)
    payload-dumper-go (https://github.com/ssut/payload-dumper-go)

  Pour les installer automatiquement :
    ./get_deps.sh

DÉROULEMENT
  Phase 1 — fastbootd
    • Annulation des snapshots Virtual A/B résiduels (libère l'espace COW)
    • Flash de toutes les partitions OTA + image perso
    • Partition logique absente/trop petite → recréation dans super
    • Partition physique "Operation not permitted" → mise en file Phase 2

  Phase 2 — bootloader  (uniquement si nécessaire)
    • Flash des partitions refusées par fastbootd (ex: modem sur certains OEM)
    • Utilise --slot=all pour écrire les deux slots
    • Retry sur le slot actif uniquement si --slot=all échoue

  → Refuse le reboot si une partition est en échec définitif (exit 1)

WORKFLOW RECOMMANDÉ AVEC MAGISK
  1. Extraire les images de la nouvelle OTA :
       ./flash_ota.sh OTA.zip --ota-no-flash

  2. Patcher init_boot.img depuis ota_extracted_*/images/ dans l'app Magisk
     (Magisk → Installer → Sélectionner et patcher un fichier)

  3. Flasher l'OTA + l'image patchée :
       ./flash_ota.sh OTA.zip init_boot_magisk.img

  Si l'OTA a déjà été flashée et qu'il faut seulement re-flasher Magisk :
       ./flash_ota.sh OTA.zip init_boot_magisk.img --ota-no-flash

EXEMPLES
  # Flash OTA seul
  ./flash_ota.sh OnePlus11_16.0.5.702.zip

  # Flash OTA + root Magisk (cas le plus courant)
  ./flash_ota.sh OnePlus11_16.0.5.702.zip init_boot_magisk.img

  # Extraction seule (pour patcher init_boot avant de flasher)
  ./flash_ota.sh OnePlus11_16.0.5.702.zip --ota-no-flash

  # Re-flasher Magisk sans re-flasher l'OTA
  ./flash_ota.sh OnePlus11_16.0.5.702.zip init_boot_magisk.img --ota-no-flash

NOTES
  • Les dossiers ota_extracted_* peuvent être supprimés après le flash.
  • Compatible avec tous les appareils Android A/B (partitions super dynamiques).
  • Testé sur OnePlus 11 (OxygenOS 15 → 16) avec Magisk.

HELP
}

# ------------------------------------------------------------------ résolution des outils
# Cherche un outil dans ./bin/ en priorité, puis dans le PATH système.
_tool() {
  if   [[ -x "$BIN_DIR/$1" ]]; then echo "$BIN_DIR/$1"
  elif command -v "$1" >/dev/null 2>&1; then command -v "$1"
  fi
}

# ------------------------------------------------------------------ arguments
OTA_ZIP=""; CUSTOM_IMG=""; OTA_NO_FLASH=0; FORCE_EXTRACT=0

for arg in "$@"; do
  case "$arg" in
    --ota-no-flash|ota-no-flash) OTA_NO_FLASH=1 ;;
    --force-extract)             FORCE_EXTRACT=1 ;;
    *.zip) OTA_ZIP="$arg" ;;
    *.img) CUSTOM_IMG="$arg" ;;
    -h|--help) show_help; exit 0 ;;
    *) die "Argument inconnu : $arg  (utilisez --help pour l'aide)" ;;
  esac
done

[[ -n "$OTA_ZIP" ]] || { show_help; exit 1; }
[[ -f "$OTA_ZIP" ]] || die "Fichier introuvable : $OTA_ZIP"
[[ -z "$CUSTOM_IMG" || -f "$CUSTOM_IMG" ]] || die "Image introuvable : $CUSTOM_IMG"

# ------------------------------------------------------------------ vérification des outils
FASTBOOT="$(_tool fastboot   || true)"
ADB="$(     _tool adb        || true)"
DUMPER="$(  _tool payload-dumper-go || _tool payload_dumper || true)"

[[ -n "$FASTBOOT" ]] || die "fastboot introuvable. Lance './get_deps.sh' pour l'installer."
[[ -n "$DUMPER"   ]] || die "payload-dumper-go introuvable. Lance './get_deps.sh' pour l'installer."

# ------------------------------------------------------------------ constantes
SKIP_PARTS=" userdata metadata "
LOGICAL_PARTS=" system system_ext vendor product odm vendor_dlkm odm_dlkm system_dlkm \
  mi_ext my_bigball my_carrier my_company my_engineering my_heytap my_manifest \
  my_preload my_product my_region my_stock my_version special_preload "

is_skipped() { [[ "$SKIP_PARTS"    == *" $1 "* ]]; }
is_logical() { [[ "$LOGICAL_PARTS" == *" $1 "* ]]; }

partition_from_img() {
  local n; n="$(basename "$1")"; n="${n%.img}"
  n="$(printf '%s' "$n" | sed -E 's/([_-](magisk|patched|root|rooted|ksu|kernelsu|apatch|mod))+$//I')"
  printf '%s' "$n"
}

CURRENT_SLOT=""

# ------------------------------------------------------------------ helpers device
wait_fastboot() {
  log "Attente du device en fastboot…"
  until "$FASTBOOT" devices 2>/dev/null | grep -q .; do sleep 1; done
  ok "Device : $("$FASTBOOT" devices | head -n1)"
}

ensure_fastboot_mode() {
  "$FASTBOOT" devices 2>/dev/null | grep -q . && return
  if [[ -n "$ADB" ]] && "$ADB" get-state >/dev/null 2>&1; then
    log "Reboot bootloader via adb…"; "$ADB" reboot bootloader
  else
    warn "Aucun device détecté — mode bootloader manuel (Vol- + Power)."
  fi
  wait_fastboot
}

enter_fastbootd() {
  local us
  us="$("$FASTBOOT" getvar is-userspace 2>&1 | grep -oP 'is-userspace:\s*\K\w+' || true)"
  if [[ "$us" != "yes" ]]; then
    log "Passage en fastbootd…"; "$FASTBOOT" reboot fastboot; wait_fastboot
  else
    ok "Déjà en fastbootd."
  fi
  CURRENT_SLOT="$("$FASTBOOT" getvar current-slot 2>&1 | grep -oP 'current-slot:\s*\K\w+' || true)"
  [[ -n "$CURRENT_SLOT" ]] && ok "Slot actif : ${CURRENT_SLOT}"
}

# Retourne 0 si le device est bien en bootloader (is-userspace = no), 1 sinon.
enter_bootloader() {
  local us slot
  log "Passage en mode bootloader…"
  "$FASTBOOT" reboot bootloader; wait_fastboot
  us="$("$FASTBOOT" getvar is-userspace 2>&1 | grep -oP 'is-userspace:\s*\K\w+' || true)"
  if [[ "$us" == "yes" ]]; then
    warn "Le device est retombé en fastbootd (bootloader désactivé sur cet appareil ?)."
    return 1
  fi
  slot="$("$FASTBOOT" getvar current-slot 2>&1 | grep -oP 'current-slot:\s*\K\w+' || true)"
  ok "Mode bootloader — slot actif : ${slot:-inconnu}"
  return 0
}

# ------------------------------------------------------------------ Virtual A/B
cancel_snapshot() {
  local status
  status="$("$FASTBOOT" getvar snapshot-update-status 2>&1 | grep -oP 'snapshot-update-status:\s*\K\w+' || true)"
  log "Snapshot Virtual A/B : ${status:-inconnu}"
  if [[ -n "$status" && "$status" != "none" ]]; then
    log "Annulation du snapshot…"
    "$FASTBOOT" snapshot-update cancel && ok "Snapshot annulé." \
      || warn "snapshot-update cancel a échoué (peut être sans conséquence)."
  fi
}

free_cow_space() {
  local p s
  log "Nettoyage des partitions COW résiduelles dans super…"
  for p in $LOGICAL_PARTS; do
    for s in a b; do
      "$FASTBOOT" delete-logical-partition "${p}_${s}-cow" >/dev/null 2>&1 || true
    done
  done
}

# ------------------------------------------------------------------ recréation partition logique
recreate_and_flash_logical() {
  local part="$1" img="$2" size suffixed
  size="$(stat -c%s "$img")"
  suffixed="${part}_${CURRENT_SLOT:-a}"
  warn "    Recréation de '$suffixed' (${size} octets)…"
  "$FASTBOOT" delete-logical-partition "${suffixed}-cow" >/dev/null 2>&1 || true
  "$FASTBOOT" delete-logical-partition "$suffixed"       >/dev/null 2>&1 || true
  if ! "$FASTBOOT" create-logical-partition "$suffixed" "$size" 2>/dev/null; then
    free_cow_space
    cancel_snapshot
    "$FASTBOOT" create-logical-partition "$suffixed" "$size" || return 1
  fi
  "$FASTBOOT" flash "$suffixed" "$img" || return 1
  ok "    '$part' flashée après recréation."
}

# ------------------------------------------------------------------ flash_part
# BOOTLOADER_QUEUE : entrées "part|img|mode"
#   mode=all     → Phase 2 : fastboot flash --slot=all  (partitions OTA)
#   mode=current → Phase 2 : fastboot flash             (image perso, slot actif seulement)
BOOTLOADER_QUEUE=()
FAILED_PARTS=()
FLASH_IDX=0
FLASH_TOTAL=0

# flash_part <partition> <image> [all|current]
flash_part() {
  local part="$1" img="$2" bl_mode="${3:-all}" out
  FLASH_IDX=$((FLASH_IDX + 1))
  log "[${FLASH_IDX}/${FLASH_TOTAL}] flash ${part}  ←  $(basename "$img")"

  # 1) tentative principale en fastbootd
  if out="$("$FASTBOOT" flash "$part" "$img" 2>&1)"; then
    echo "$out" | tail -n1; return 0
  fi
  echo "$out" >&2

  # 2) partition logique absente ou trop petite
  if is_logical "$part" && grep -qE "Not enough space|No such file or directory" <<< "$out"; then
    if recreate_and_flash_logical "$part" "$img"; then
      return 0
    fi
    warn "    '$part' : recréation échouée → erreur définitive."
    FAILED_PARTS+=("$part"); return 0
  fi

  # 3) partition physique protégée → passe bootloader
  if ! is_logical "$part" && grep -q "Operation not permitted" <<< "$out"; then
    warn "    '$part' protégée en fastbootd → planifiée pour la Phase 2 (bootloader)."
    BOOTLOADER_QUEUE+=("${part}|${img}|${bl_mode}"); return 0
  fi

  # 4) autres cas → retry sur le slot explicite
  if [[ -n "${CURRENT_SLOT:-}" ]]; then
    warn "    Retry : fastboot flash ${part}_${CURRENT_SLOT}"
    if "$FASTBOOT" flash "${part}_${CURRENT_SLOT}" "$img"; then
      ok "    '$part' flashée sur le slot ${CURRENT_SLOT}."; return 0
    fi
  fi

  warn "    Échec définitif de '$part'."
  FAILED_PARTS+=("$part")
}

# ------------------------------------------------------------------ extraction
ZIP_NAME="$(basename "$OTA_ZIP")"
WORKDIR="$(pwd)/ota_extracted_${ZIP_NAME%.zip}"
IMG_DIR="$WORKDIR/images"

NB_IMG=$(ls "$IMG_DIR"/*.img 2>/dev/null | wc -l || true)
if [[ $FORCE_EXTRACT -eq 0 && $NB_IMG -gt 0 ]]; then
  ok "$NB_IMG images déjà extraites — extraction sautée (--force-extract pour forcer)."
else
  mkdir -p "$IMG_DIR"
  log "Extraction de payload.bin depuis $ZIP_NAME…"
  unzip -o "$OTA_ZIP" payload.bin -d "$WORKDIR" >/dev/null \
    || die "payload.bin absent du zip (OTA non A/B ?)"
  log "Extraction des images avec $(basename "$DUMPER")…"
  if [[ "$(basename "$DUMPER")" == "payload-dumper-go" ]]; then
    "$DUMPER" -output "$IMG_DIR" "$WORKDIR/payload.bin" >/dev/null
  else
    "$DUMPER" --out "$IMG_DIR" "$WORKDIR/payload.bin" >/dev/null
  fi
  rm -f "$WORKDIR/payload.bin"
  NB_IMG=$(ls "$IMG_DIR"/*.img 2>/dev/null | wc -l)
  (( NB_IMG > 0 )) || die "Aucune image extraite — payload corrompu ?"
  ok "$NB_IMG images extraites dans : $IMG_DIR"
fi

OTA_IMGS=()
for img in "$IMG_DIR"/*.img; do
  part="$(basename "$img" .img)"
  if is_skipped "$part"; then warn "Partition ignorée : $part"; continue; fi
  OTA_IMGS+=("$img")
done

echo
log "Récapitulatif :"
echo "    OTA zip          : $OTA_ZIP"
echo "    Images extraites : $NB_IMG ($IMG_DIR)"
echo "    Flash OTA        : $([[ $OTA_NO_FLASH -eq 1 ]] && echo 'NON (--ota-no-flash)' || echo "OUI (${#OTA_IMGS[@]} partitions)")"
if [[ -n "$CUSTOM_IMG" ]]; then
  CUSTOM_PART="$(partition_from_img "$CUSTOM_IMG")"
  echo "    Image perso      : $(basename "$CUSTOM_IMG") → partition '$CUSTOM_PART'"
fi
echo

if [[ $OTA_NO_FLASH -eq 1 && -z "$CUSTOM_IMG" ]]; then
  ok "Extraction terminée, rien à flasher."; exit 0
fi

read -r -p "Continuer le flash ? [o/N] " rep
[[ "$rep" =~ ^[oOyY]$ ]] || { warn "Abandon."; exit 0; }

ensure_fastboot_mode

# ======================================================== Phase 1 : fastbootd
echo
log "══════════════════════════════════════"
log "  Phase 1 — fastbootd"
log "══════════════════════════════════════"
enter_fastbootd
cancel_snapshot

FLASH_TOTAL=0
[[ $OTA_NO_FLASH -eq 0 ]] && FLASH_TOTAL=${#OTA_IMGS[@]}
[[ -n "$CUSTOM_IMG" ]] && FLASH_TOTAL=$((FLASH_TOTAL + 1))

if [[ $OTA_NO_FLASH -eq 0 ]]; then
  for img in "${OTA_IMGS[@]}"; do
    flash_part "$(basename "$img" .img)" "$img" "all"
  done
fi

if [[ -n "$CUSTOM_IMG" ]]; then
  case "$CUSTOM_PART" in
    magisk*|patched*|"")
      die "Impossible de déduire la partition depuis '$(basename "$CUSTOM_IMG")'. Renomme-le en <partition>_magisk.img (ex: init_boot_magisk.img)." ;;
  esac
  echo
  log "Flash de l'image perso sur '$CUSTOM_PART' (slot actif uniquement)…"
  flash_part "$CUSTOM_PART" "$CUSTOM_IMG" "current"
fi

# ====================================================== Phase 2 : bootloader
if (( ${#BOOTLOADER_QUEUE[@]} > 0 )); then
  echo
  log "══════════════════════════════════════"
  log "  Phase 2 — bootloader (${#BOOTLOADER_QUEUE[@]} partition(s) refusée(s) par fastbootd)"
  log "══════════════════════════════════════"

  if enter_bootloader; then
    bl_idx=0; bl_total=${#BOOTLOADER_QUEUE[@]}
    for entry in "${BOOTLOADER_QUEUE[@]}"; do
      bl_part="${entry%%|*}"; rest="${entry#*|}"; bl_img="${rest%%|*}"; bl_mode="${rest#*|}"
      bl_idx=$((bl_idx + 1))

      if [[ "$bl_mode" == "all" ]]; then
        # Partition OTA : écrire les deux slots pour les garder cohérents
        log "[${bl_idx}/${bl_total}] flash --slot=all ${bl_part}  ←  $(basename "$bl_img")"
        if "$FASTBOOT" flash --slot=all "$bl_part" "$bl_img"; then
          ok "    '$bl_part' flashée sur les deux slots."
        else
          warn "    --slot=all a échoué. Retry sur le slot actif uniquement…"
          if "$FASTBOOT" flash "$bl_part" "$bl_img"; then
            ok "    '$bl_part' flashée sur le slot actif."
          else
            err "    Échec définitif de '$bl_part' même en bootloader."
            FAILED_PARTS+=("$bl_part")
          fi
        fi
      else
        # Image perso : slot actif uniquement
        log "[${bl_idx}/${bl_total}] flash ${bl_part}  ←  $(basename "$bl_img")"
        if "$FASTBOOT" flash "$bl_part" "$bl_img"; then
          ok "    '$bl_part' flashée sur le slot actif."
        else
          err "    Échec définitif de '$bl_part' même en bootloader."
          FAILED_PARTS+=("$bl_part")
        fi
      fi
    done
  else
    err "Impossible d'atteindre le mode bootloader. Partitions non flashées :"
    for entry in "${BOOTLOADER_QUEUE[@]}"; do
      bl_part="${entry%%|*}"
      err "  • $bl_part"
      FAILED_PARTS+=("$bl_part")
    done
  fi
fi

# ================================================================= Résultat
echo
if (( ${#FAILED_PARTS[@]} > 0 )); then
  err "Flash INCOMPLET — partitions en échec définitif :"
  for p in "${FAILED_PARTS[@]}"; do err "  • $p"; done
  err "NE REDÉMARRE PAS. Résous les erreurs ci-dessus d'abord."
  exit 1
fi

ok "Flash terminé sans erreur."
read -r -p "Redémarrer maintenant ? [O/n] " rep
if [[ ! "$rep" =~ ^[nN]$ ]]; then
  "$FASTBOOT" reboot; ok "Redémarrage en cours."
else
  warn "Pense à faire 'fastboot reboot' toi-même."
fi
