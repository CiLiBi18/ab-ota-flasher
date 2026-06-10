#!/usr/bin/env bash
#
# flash_ota.sh — Flash an Android A/B OTA update via fastboot
# Repo   : https://github.com/CiLiBi18/ab-ota-flasher
# Help   : ./flash_ota.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"

# ------------------------------------------------------------------ colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[X]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

# ------------------------------------------------------------------ help
show_help() {
  cat << 'HELP'

USAGE
  ./flash_ota.sh <ota.zip> [custom_image.img] [OPTIONS]

ARGUMENTS
  ota.zip             OTA zip file (must contain an A/B payload.bin)
  custom_image.img    (Optional) Image to flash after the OTA.
                      The target partition is inferred from the filename:
                        init_boot_magisk.img  →  init_boot
                        boot_patched.img      →  boot
                        vendor_boot_ksu.img   →  vendor_boot
                      Recognized suffixes: _magisk, _patched, _root, _rooted,
                                           _ksu, _kernelsu, _apatch, _mod

OPTIONS
  --ota-no-flash    Extract images without flashing the OTA.
                    If a custom image is provided, it will still be flashed.
  --force-extract   Force re-extraction even if images already exist.
  -h, --help        Show this help message.

DEPENDENCIES
  The following tools are searched in ./bin/ first (populated by get_deps.sh),
  then in the system PATH:
    fastboot          (Android platform-tools)
    adb               (Android platform-tools)
    payload-dumper-go (https://github.com/ssut/payload-dumper-go)

  To install them automatically:
    ./get_deps.sh

FLASHING FLOW
  Phase 1 — fastbootd
    • Cancel any pending Virtual A/B snapshot (frees COW space)
    • Flash all OTA partitions + custom image
    • Logical partition missing/too small → recreate in super
    • Physical partition "Operation not permitted" → queue for Phase 2

  Phase 2 — bootloader  (only if needed)
    • Flash partitions rejected by fastbootd (e.g. modem on some OEMs)
    • Uses --slot=all to write both slots
    • Retries on active slot only if --slot=all fails

  → Refuses to reboot if any partition permanently failed (exit 1)

RECOMMENDED WORKFLOW WITH MAGISK
  1. Extract images from the new OTA:
       ./flash_ota.sh OTA.zip --ota-no-flash

  2. Patch init_boot.img from ota_extracted_*/images/ in the Magisk app
     (Magisk → Install → Select and Patch a File)

  3. Flash the OTA + patched image:
       ./flash_ota.sh OTA.zip init_boot_magisk.img

  If the OTA was already flashed and you only need to re-flash Magisk:
       ./flash_ota.sh OTA.zip init_boot_magisk.img --ota-no-flash

EXAMPLES
  # Flash OTA only
  ./flash_ota.sh OnePlus11_16.0.5.702.zip

  # Flash OTA + Magisk root (most common case)
  ./flash_ota.sh OnePlus11_16.0.5.702.zip init_boot_magisk.img

  # Extract only (to patch init_boot before flashing)
  ./flash_ota.sh OnePlus11_16.0.5.702.zip --ota-no-flash

  # Re-flash Magisk without re-flashing the OTA
  ./flash_ota.sh OnePlus11_16.0.5.702.zip init_boot_magisk.img --ota-no-flash

NOTES
  • ota_extracted_* directories can be deleted after flashing.
  • Compatible with all A/B Android devices (dynamic super partitions).
  • Tested on OnePlus 11 (OxygenOS 14 → 16) with Magisk.

HELP
}

# ------------------------------------------------------------------ tool resolution
# Looks for a tool in ./bin/ first, then falls back to system PATH.
_tool() {
  if   [[ -x "$BIN_DIR/$1" ]]; then echo "$BIN_DIR/$1"
  elif command -v "$1" >/dev/null 2>&1; then command -v "$1"
  fi
}

# ------------------------------------------------------------------ argument parsing
OTA_ZIP=""; CUSTOM_IMG=""; OTA_NO_FLASH=0; FORCE_EXTRACT=0

for arg in "$@"; do
  case "$arg" in
    --ota-no-flash|ota-no-flash) OTA_NO_FLASH=1 ;;
    --force-extract)             FORCE_EXTRACT=1 ;;
    *.zip) OTA_ZIP="$arg" ;;
    *.img) CUSTOM_IMG="$arg" ;;
    -h|--help) show_help; exit 0 ;;
    *) die "Unknown argument: $arg  (use --help for usage)" ;;
  esac
done

[[ -n "$OTA_ZIP" ]] || { show_help; exit 1; }
[[ -f "$OTA_ZIP" ]] || die "File not found: $OTA_ZIP"
[[ -z "$CUSTOM_IMG" || -f "$CUSTOM_IMG" ]] || die "Image not found: $CUSTOM_IMG"

# ------------------------------------------------------------------ tool check
FASTBOOT="$(_tool fastboot   || true)"
ADB="$(     _tool adb        || true)"
DUMPER="$(  _tool payload-dumper-go || _tool payload_dumper || true)"

[[ -n "$FASTBOOT" ]] || die "fastboot not found. Run './get_deps.sh' to install it."
[[ -n "$DUMPER"   ]] || die "payload-dumper-go not found. Run './get_deps.sh' to install it."

# ------------------------------------------------------------------ constants
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

# ------------------------------------------------------------------ device helpers
wait_fastboot() {
  log "Waiting for device in fastboot mode..."
  until "$FASTBOOT" devices 2>/dev/null | grep -q .; do sleep 1; done
  ok "Device: $("$FASTBOOT" devices | head -n1)"
}

ensure_fastboot_mode() {
  "$FASTBOOT" devices 2>/dev/null | grep -q . && return
  if [[ -n "$ADB" ]] && "$ADB" get-state >/dev/null 2>&1; then
    log "Rebooting to bootloader via adb..."; "$ADB" reboot bootloader
  else
    warn "No device detected — enter bootloader manually (Vol- + Power)."
  fi
  wait_fastboot
}

enter_fastbootd() {
  local us
  us="$("$FASTBOOT" getvar is-userspace 2>&1 | grep -oP 'is-userspace:\s*\K\w+' || true)"
  if [[ "$us" != "yes" ]]; then
    log "Switching to fastbootd..."; "$FASTBOOT" reboot fastboot; wait_fastboot
  else
    ok "Already in fastbootd."
  fi
  CURRENT_SLOT="$("$FASTBOOT" getvar current-slot 2>&1 | grep -oP 'current-slot:\s*\K\w+' || true)"
  [[ -n "$CURRENT_SLOT" ]] && ok "Active slot: ${CURRENT_SLOT}"
}

# Returns 0 if device is in bootloader mode (is-userspace = no), 1 otherwise.
enter_bootloader() {
  local us slot
  log "Switching to bootloader mode..."
  "$FASTBOOT" reboot bootloader; wait_fastboot
  us="$("$FASTBOOT" getvar is-userspace 2>&1 | grep -oP 'is-userspace:\s*\K\w+' || true)"
  if [[ "$us" == "yes" ]]; then
    warn "Device fell back to fastbootd (bootloader disabled on this device?)."
    return 1
  fi
  slot="$("$FASTBOOT" getvar current-slot 2>&1 | grep -oP 'current-slot:\s*\K\w+' || true)"
  ok "Bootloader mode — active slot: ${slot:-unknown}"
  return 0
}

# ------------------------------------------------------------------ Virtual A/B
cancel_snapshot() {
  local status
  status="$("$FASTBOOT" getvar snapshot-update-status 2>&1 | grep -oP 'snapshot-update-status:\s*\K\w+' || true)"
  log "Virtual A/B snapshot: ${status:-unknown}"
  if [[ -n "$status" && "$status" != "none" ]]; then
    log "Cancelling snapshot..."
    "$FASTBOOT" snapshot-update cancel && ok "Snapshot cancelled." \
      || warn "snapshot-update cancel failed (may be harmless)."
  fi
}

free_cow_space() {
  local p s
  log "Cleaning up residual COW partitions in super..."
  for p in $LOGICAL_PARTS; do
    for s in a b; do
      "$FASTBOOT" delete-logical-partition "${p}_${s}-cow" >/dev/null 2>&1 || true
    done
  done
}

# ------------------------------------------------------------------ logical partition recreation
recreate_and_flash_logical() {
  local part="$1" img="$2" size suffixed
  size="$(stat -c%s "$img")"
  suffixed="${part}_${CURRENT_SLOT:-a}"
  warn "    Recreating '$suffixed' (${size} bytes)..."
  "$FASTBOOT" delete-logical-partition "${suffixed}-cow" >/dev/null 2>&1 || true
  "$FASTBOOT" delete-logical-partition "$suffixed"       >/dev/null 2>&1 || true
  if ! "$FASTBOOT" create-logical-partition "$suffixed" "$size" 2>/dev/null; then
    free_cow_space
    cancel_snapshot
    "$FASTBOOT" create-logical-partition "$suffixed" "$size" || return 1
  fi
  "$FASTBOOT" flash "$suffixed" "$img" || return 1
  ok "    '$part' flashed after recreation."
}

# ------------------------------------------------------------------ flash_part
# BOOTLOADER_QUEUE entries: "part|img|mode"
#   mode=all     → Phase 2: fastboot flash --slot=all  (OTA partitions)
#   mode=current → Phase 2: fastboot flash             (custom image, active slot only)
BOOTLOADER_QUEUE=()
FAILED_PARTS=()
FLASH_IDX=0
FLASH_TOTAL=0

# flash_part <partition> <image> [all|current]
flash_part() {
  local part="$1" img="$2" bl_mode="${3:-all}" out
  FLASH_IDX=$((FLASH_IDX + 1))
  log "[${FLASH_IDX}/${FLASH_TOTAL}] flash ${part}  ←  $(basename "$img")"

  # 1) primary attempt in fastbootd
  if out="$("$FASTBOOT" flash "$part" "$img" 2>&1)"; then
    echo "$out" | tail -n1; return 0
  fi
  echo "$out" >&2

  # 2) logical partition missing or too small
  if is_logical "$part" && grep -qE "Not enough space|No such file or directory" <<< "$out"; then
    if recreate_and_flash_logical "$part" "$img"; then
      return 0
    fi
    warn "    '$part': recreation failed → permanent error."
    FAILED_PARTS+=("$part"); return 0
  fi

  # 3) protected physical partition → queue for bootloader
  if ! is_logical "$part" && grep -q "Operation not permitted" <<< "$out"; then
    warn "    '$part' blocked in fastbootd → queued for Phase 2 (bootloader)."
    BOOTLOADER_QUEUE+=("${part}|${img}|${bl_mode}"); return 0
  fi

  # 4) other cases → retry on explicit slot
  if [[ -n "${CURRENT_SLOT:-}" ]]; then
    warn "    Retry: fastboot flash ${part}_${CURRENT_SLOT}"
    if "$FASTBOOT" flash "${part}_${CURRENT_SLOT}" "$img"; then
      ok "    '$part' flashed on slot ${CURRENT_SLOT}."; return 0
    fi
  fi

  warn "    Permanent failure for '$part'."
  FAILED_PARTS+=("$part")
}

# ------------------------------------------------------------------ extraction
ZIP_NAME="$(basename "$OTA_ZIP")"
WORKDIR="$(pwd)/ota_extracted_${ZIP_NAME%.zip}"
IMG_DIR="$WORKDIR/images"

NB_IMG=$(ls "$IMG_DIR"/*.img 2>/dev/null | wc -l || true)
if [[ $FORCE_EXTRACT -eq 0 && $NB_IMG -gt 0 ]]; then
  ok "$NB_IMG images already extracted — skipping (use --force-extract to force)."
else
  mkdir -p "$IMG_DIR"
  log "Extracting payload.bin from $ZIP_NAME..."
  unzip -o "$OTA_ZIP" payload.bin -d "$WORKDIR" >/dev/null \
    || die "payload.bin not found in zip (not an A/B OTA?)"
  log "Extracting images with $(basename "$DUMPER")..."
  if [[ "$(basename "$DUMPER")" == "payload-dumper-go" ]]; then
    "$DUMPER" -output "$IMG_DIR" "$WORKDIR/payload.bin" >/dev/null
  else
    "$DUMPER" --out "$IMG_DIR" "$WORKDIR/payload.bin" >/dev/null
  fi
  rm -f "$WORKDIR/payload.bin"
  NB_IMG=$(ls "$IMG_DIR"/*.img 2>/dev/null | wc -l)
  (( NB_IMG > 0 )) || die "No images extracted — corrupted payload?"
  ok "$NB_IMG images extracted to: $IMG_DIR"
fi

OTA_IMGS=()
for img in "$IMG_DIR"/*.img; do
  part="$(basename "$img" .img)"
  if is_skipped "$part"; then warn "Skipping partition: $part"; continue; fi
  OTA_IMGS+=("$img")
done

echo
log "Summary:"
echo "    OTA zip          : $OTA_ZIP"
echo "    Extracted images : $NB_IMG ($IMG_DIR)"
echo "    Flash OTA        : $([[ $OTA_NO_FLASH -eq 1 ]] && echo 'NO (--ota-no-flash)' || echo "YES (${#OTA_IMGS[@]} partitions)")"
if [[ -n "$CUSTOM_IMG" ]]; then
  CUSTOM_PART="$(partition_from_img "$CUSTOM_IMG")"
  echo "    Custom image     : $(basename "$CUSTOM_IMG") → partition '$CUSTOM_PART'"
fi
echo

if [[ $OTA_NO_FLASH -eq 1 && -z "$CUSTOM_IMG" ]]; then
  ok "Extraction complete, nothing to flash."; exit 0
fi

read -r -p "Continue with flash? [y/N] " rep
[[ "$rep" =~ ^[yY]$ ]] || { warn "Aborted."; exit 0; }

ensure_fastboot_mode

# ======================================================== Phase 1: fastbootd
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
      die "Cannot infer partition from '$(basename "$CUSTOM_IMG")'. Rename it as <partition>_magisk.img (e.g. init_boot_magisk.img)." ;;
  esac
  echo
  log "Flashing custom image on '$CUSTOM_PART' (active slot only)..."
  flash_part "$CUSTOM_PART" "$CUSTOM_IMG" "current"
fi

# ====================================================== Phase 2: bootloader
if (( ${#BOOTLOADER_QUEUE[@]} > 0 )); then
  echo
  log "══════════════════════════════════════"
  log "  Phase 2 — bootloader (${#BOOTLOADER_QUEUE[@]} partition(s) rejected by fastbootd)"
  log "══════════════════════════════════════"

  if enter_bootloader; then
    bl_idx=0; bl_total=${#BOOTLOADER_QUEUE[@]}
    for entry in "${BOOTLOADER_QUEUE[@]}"; do
      bl_part="${entry%%|*}"; rest="${entry#*|}"; bl_img="${rest%%|*}"; bl_mode="${rest#*|}"
      bl_idx=$((bl_idx + 1))

      if [[ "$bl_mode" == "all" ]]; then
        # OTA partition: write both slots to keep them in sync
        log "[${bl_idx}/${bl_total}] flash --slot=all ${bl_part}  ←  $(basename "$bl_img")"
        if "$FASTBOOT" flash --slot=all "$bl_part" "$bl_img"; then
          ok "    '$bl_part' flashed on both slots."
        else
          warn "    --slot=all failed. Retrying on active slot only..."
          if "$FASTBOOT" flash "$bl_part" "$bl_img"; then
            ok "    '$bl_part' flashed on active slot."
          else
            err "    Permanent failure for '$bl_part' even in bootloader mode."
            FAILED_PARTS+=("$bl_part")
          fi
        fi
      else
        # Custom image: active slot only
        log "[${bl_idx}/${bl_total}] flash ${bl_part}  ←  $(basename "$bl_img")"
        if "$FASTBOOT" flash "$bl_part" "$bl_img"; then
          ok "    '$bl_part' flashed on active slot."
        else
          err "    Permanent failure for '$bl_part' even in bootloader mode."
          FAILED_PARTS+=("$bl_part")
        fi
      fi
    done
  else
    err "Could not reach bootloader mode. Partitions not flashed:"
    for entry in "${BOOTLOADER_QUEUE[@]}"; do
      bl_part="${entry%%|*}"
      err "  • $bl_part"
      FAILED_PARTS+=("$bl_part")
    done
  fi
fi

# ================================================================= Result
echo
if (( ${#FAILED_PARTS[@]} > 0 )); then
  err "Flash INCOMPLETE — permanently failed partitions:"
  for p in "${FAILED_PARTS[@]}"; do err "  • $p"; done
  err "DO NOT REBOOT. Fix the errors above first."
  exit 1
fi

ok "Flash completed successfully."
read -r -p "Reboot now? [Y/n] " rep
if [[ ! "$rep" =~ ^[nN]$ ]]; then
  "$FASTBOOT" reboot; ok "Rebooting..."
else
  warn "Remember to run 'fastboot reboot' yourself."
fi
