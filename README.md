# ab-ota-flasher

Script bash pour flasher une mise à jour OTA Android A/B via `fastboot`, avec support natif du root Magisk (et dérivés : KernelSU, APatch).

---

## Fonctionnalités

- **Extraction automatique** du `payload.bin` depuis le zip OTA
- **Cache intelligent** : les images déjà extraites sont réutilisées, l'extraction n'a lieu qu'une fois
- **Flash en deux phases** :
  - *Phase 1 — fastbootd* : partitions logiques (system, vendor, my_\*, …) et physiques standards
  - *Phase 2 — bootloader* : partitions physiques refusées par fastbootd (`modem`, etc.) avec `--slot=all` pour mettre à jour les deux slots
- **Recréation automatique** des partitions logiques absentes ou trop petites (nettoyage des snapshots COW résiduels si nécessaire)
- **Annulation des snapshots Virtual A/B** résiduels avant le flash (libère l'espace dans `super`)
- **Image perso** (Magisk, KernelSU…) : partition cible déduite du nom du fichier
- **Refus du reboot** si une partition est en échec définitif

---

## Prérequis

- Linux x86\_64 ou arm64 (macOS supporté par `get_deps.sh`)
- Bootloader déverrouillé sur l'appareil
- `curl` et `unzip` installés

---

## Installation

```bash
git clone https://github.com/CiLiBi18/ab-ota-flasher
cd ab-ota-flasher
chmod +x flash_ota.sh get_deps.sh
./get_deps.sh          # télécharge fastboot, adb et payload-dumper-go dans ./bin/
```

Les outils sont téléchargés dans `./bin/` et utilisés automatiquement par `flash_ota.sh`.  
Si `fastboot`, `adb` ou `payload-dumper-go` sont déjà dans ton PATH, ils sont utilisés tels quels — pas besoin de lancer `get_deps.sh`.

---

## Utilisation

```
./flash_ota.sh <ota.zip> [image_perso.img] [OPTIONS]

OPTIONS
  --ota-no-flash    Extrait les images sans flasher l'OTA.
                    Si une image perso est fournie, elle est flashée quand même.
  --force-extract   Force la ré-extraction même si les images existent déjà.
  -h, --help        Affiche l'aide complète.
```

Voir `./flash_ota.sh --help` pour la documentation complète.

---

## Workflow recommandé avec Magisk

```bash
# 1. Extraire les images de la nouvelle OTA
./flash_ota.sh OTA.zip --ota-no-flash

# 2. Patcher init_boot.img dans l'app Magisk :
#    Magisk → Installer → Sélectionner et patcher un fichier
#    → sélectionner ota_extracted_*/images/init_boot.img

# 3. Flasher l'OTA + l'image patchée
./flash_ota.sh OTA.zip init_boot_magisk.img
```

Si l'OTA a déjà été flashée et qu'il faut seulement re-flasher Magisk :

```bash
./flash_ota.sh OTA.zip init_boot_magisk.img --ota-no-flash
```

---

## Nommage de l'image perso

La partition cible est déduite automatiquement du nom du fichier en retirant les suffixes courants :

| Fichier                    | Partition flashée |
|----------------------------|-------------------|
| `init_boot_magisk.img`     | `init_boot`       |
| `boot_patched.img`         | `boot`            |
| `vendor_boot_ksu.img`      | `vendor_boot`     |
| `init_boot_apatch.img`     | `init_boot`       |

Suffixes reconnus : `_magisk`, `_patched`, `_root`, `_rooted`, `_ksu`, `_kernelsu`, `_apatch`, `_mod`

---

## Appareils testés

| Appareil    | OS                   | Root   |
|-------------|----------------------|--------|
| OnePlus 11  | OxygenOS 15 → 16     | Magisk |

*Pull requests bienvenues pour ajouter d'autres appareils.*

---

## Compatibilité

Tout appareil Android A/B avec partitions dynamiques (`super`), quelle que soit la marque.

---

## Licence

MIT
