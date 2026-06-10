# A/B OTA Flasher

A Bash script to flash Android A/B OTA updates (via `payload.bin`) using `fastboot`, with optional custom image support (e.g. Magisk-patched `init_boot`).

## Features

- Automatic extraction of `payload.bin` from the OTA zip using `payload-dumper-go`
- **Two-phase flashing:**
  - **Phase 1 — fastbootd:** flashes logical and most physical partitions
    - Logical partition missing or too small → auto delete / recreate / flash
    - If `super` is full → cleans up COW partitions + cancels snapshot, then retries
  - **Phase 2 — bootloader:** handles partitions rejected by fastbootd (`Operation not permitted`)
    - `fastboot flash --slot=all` (updates both slots), with active-slot retry on failure
    - If the device falls back to fastbootd (disabled bootloader) → clear error message
- Custom image flashing (e.g. Magisk-patched boot/init_boot) on the active slot only
- Refuses to propose reboot if any partition failed (exits with code 1)
- Skips `userdata` and `metadata` automatically

## Requirements

- `fastboot` (Android SDK Platform-Tools)
- `unzip`
- [`payload-dumper-go`](https://github.com/ssut/payload-dumper-go) or `payload_dumper`

Binaries can be placed in `./bin/` — the script searches there first before `$PATH`.

## Usage

```bash
./flash_ota.sh <ota.zip> [custom_image.img] [--ota-no-flash] [--force-extract]
```

| Argument | Description |
|---|---|
| `<ota.zip>` | Path to the OTA zip file (required) |
| `[custom_image.img]` | Optional custom image to flash (e.g. `init_boot_magisk.img`) |
| `--ota-no-flash` | Extract images only, skip flashing the OTA partitions |
| `--force-extract` | Force re-extraction even if images already exist |

### Examples

```bash
# Flash a full OTA update
./flash_ota.sh OnePlus11_16.0.5.702.zip

# Flash OTA + replace init_boot with a Magisk-patched image
./flash_ota.sh OnePlus11_16.0.5.702.zip init_boot_magisk.img

# Extract images only, then flash just the custom image
./flash_ota.sh OnePlus11_16.0.5.702.zip init_boot_magisk.img --ota-no-flash
```

### Custom image naming convention

The target partition is inferred from the filename. Suffixes like `_magisk`, `_patched`, `_root`, `_ksu`, `_kernelsu`, `_apatch`, `_mod` are stripped automatically:

| Filename | Target partition |
|---|---|
| `init_boot_magisk.img` | `init_boot` |
| `boot_patched.img` | `boot` |
| `init_boot_ksu.img` | `init_boot` |

## Flashing flow

```
Boot device into fastboot mode
        │
        ▼
  Phase 1 — fastbootd
  ├── Cancel pending Virtual A/B snapshot
  ├── Flash each OTA partition
  │   ├── Logical partition too small → recreate + flash
  │   ├── Physical partition blocked  → queue for Phase 2
  │   └── Other failure               → mark as failed
  └── Flash custom image (active slot only)
        │
        ▼  (if Phase 2 queue is non-empty)
  Phase 2 — bootloader
  ├── flash --slot=all for OTA partitions
  └── flash active slot only for custom image
        │
        ▼
  Summary: success → prompt reboot
           failure → exit 1, do NOT reboot
```

## Tested on

- OnePlus 11 (CPH2449) — Android 14/15/16 OTA updates

## License

MIT
