#!/usr/bin/env bash
# patch_boot_a.sh - patch the boot_a partition for Xiaomi Pad 6 (Pipa) dual boot.
# Run as root on the tablet (Linux). Everything needed is inside this folder.
#
#   read boot_a -> backup -> magiskboot unpack -> patch kernel (Mu UEFI + shell code)
#   -> magiskboot repack -> size check -> write back -> verify
#
#   sudo ./patch_boot_a.sh [N]      N = shell code number (asked if omitted)
# WARNING: assumes Linux is running from slot b; it patches boot_a (the Android slot).
#   env: BOOT_PART=<dev|file>       default /dev/disk/by-partlabel/boot_a
#        YES=1                      skip the final confirmation
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PART="${BOOT_PART:-/dev/disk/by-partlabel/boot_a}"

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; Z=$'\e[0m'; else B=""; G=""; Y=""; R=""; C=""; Z=""; fi
info() { printf '%s>>%s %s\n' "$C" "$Z" "$*"; }
ok()   { printf '%s OK%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '%s !!%s %s\n' "$Y" "$Z" "$*"; }
die()  { printf '%sERROR:%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }
size() { wc -c < "$1" | tr -d ' '; }

printf '\n%s+--------------------------------------------+\n|   Pipa DualBoot  -  boot_a kernel patcher  |\n+--------------------------------------------+%s\n\n' "$B" "$Z"

# ---- environment -------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run as root:  sudo $0"
case "$(uname -m)" in
  aarch64|arm64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=x86_64 ;;
  *) die "unsupported CPU $(uname -m) (arm64 and x86_64 only)" ;;
esac
for t in dd cmp readlink mktemp blockdev; do command -v "$t" >/dev/null 2>&1 || die "missing command: $t"; done

if [ -f "$ROOT/SHA256SUMS" ] && command -v sha256sum >/dev/null 2>&1; then
  (cd "$ROOT" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1) \
    || die "file check failed (corrupt or modified bundle). Re-extract the zip, or delete SHA256SUMS to skip this check."
  ok "bundle files verified"
fi

# ---- bundle contents ---------------------------------------------------------
MAGISKBOOT="$ROOT/magiskboot/$ARCH/magiskboot"
PATCHER="$ROOT/bin/$ARCH/DualBootKernelPatcher"
CFG="$ROOT/Config/DualBoot.Sm8250.cfg"
UEFI=""
for f in "$ROOT"/uefi/*Mu*.fd "$ROOT"/uefi/*.fd; do [ -f "$f" ] && { UEFI="$f"; break; }; done

for f in "$MAGISKBOOT" "$PATCHER"; do
  [ -f "$f" ] || die "missing $f"
  [ -x "$f" ] || chmod +x "$f" || die "cannot make $f executable"
done
[ -f "$CFG" ]  || die "missing $CFG"
[ -n "$UEFI" ] || die "no UEFI image (*.fd) in $ROOT/uefi/"

STACKSIZE="$(sed -n 's/^StackSize=\(0x[0-9A-Fa-f]*\).*/\1/p' "$CFG" | head -n1)"
[ -z "$STACKSIZE" ] || [ "$(size "$UEFI")" -le $((STACKSIZE)) ] \
  || die "$(basename "$UEFI") ($(size "$UEFI") bytes) is larger than StackSize $STACKSIZE"

# ---- pick a shell code -------------------------------------------------------
describe() {
  case "$1" in
    Pipa.Magnetic.cover) echo "cover open -> UEFI, cover closed -> Android   (magnetic sensor, GPIO 110)" ;;
    Pipa.Orientation)    echo "androidboot.ori=03 -> UEFI, otherwise Android (inverted landscape)" ;;
    *)                   echo "custom shell code" ;;
  esac
}
shopt -s nullglob
CODES=("$ROOT"/ShellCode/*.bin)
[ "${#CODES[@]}" -gt 0 ] || die "no shell code (*.bin) in $ROOT/ShellCode/"

echo "${B}Available shell codes:${Z}"
for i in "${!CODES[@]}"; do
  n="$(basename "${CODES[$i]}" .bin)"
  printf '  %s%d)%s %-22s %s\n' "$B" $((i + 1)) "$Z" "$n" "$(describe "$n")"
done
echo
CHOICE="${1:-}"
if [ -z "$CHOICE" ]; then read -r -p "Select shell code [1-${#CODES[@]}]: " CHOICE || die "no selection"; fi
[[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#CODES[@]}" ] \
  || die "invalid selection '$CHOICE'"
SHELLCODE="${CODES[$((CHOICE - 1))]}"
info "Shell code : $(basename "$SHELLCODE")"
info "UEFI       : $(basename "$UEFI") ($(size "$UEFI") bytes)"
info "Arch       : $ARCH"

# ---- partition ---------------------------------------------------------------
[ -e "$PART" ] || die "$PART not found (pass another one with BOOT_PART=...)"
PART="$(readlink -f "$PART")"
if   [ -b "$PART" ]; then PSIZE="$(blockdev --getsize64 "$PART")"
elif [ -f "$PART" ]; then PSIZE="$(size "$PART")"
else die "$PART is neither a block device nor a file"; fi
if grep -q "^$PART " /proc/mounts 2>/dev/null; then die "$PART is mounted"; fi
info "Partition  : $PART ($PSIZE bytes)"

# write IMG to the partition and compare it back; returns 1 on mismatch
write_verify() {
  local n; n="$(size "$1")"
  dd if="$1" of="$PART" bs=1M conv=notrunc,fsync status=none && sync
  cmp -s -n "$n" "$1" "$PART"
}

# ---- backup ------------------------------------------------------------------
mkdir -p "$ROOT/backups"
BACKUP="$ROOT/backups/boot_a-$(date +%Y%m%d-%H%M%S).img"
dd if="$PART" of="$BACKUP" bs=1M status=none
[ "$(size "$BACKUP")" -eq "$PSIZE" ] || die "backup is incomplete, nothing was changed"
ok "backup: $BACKUP"

# ---- unpack / patch / repack -------------------------------------------------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp "$BACKUP" "$WORK/boot.img"; cd "$WORK"

info "Unpacking"
"$MAGISKBOOT" unpack boot.img >/dev/null 2>&1 || die "unpack failed - is $PART really a boot image?"
[ -s kernel ] || die "unpack produced no kernel"

info "Patching kernel"
"$PATCHER" kernel "$UEFI" PatchedKernel "$CFG" "$SHELLCODE" >/dev/null || die "patcher failed"
[ -s PatchedKernel ] || die "patcher produced no output"
rm -f kernel; mv PatchedKernel kernel

info "Repacking"
"$MAGISKBOOT" repack boot.img boot-repack.img >/dev/null 2>&1 || die "repack failed"
[ -s boot-repack.img ] || die "repack produced no image"

NSIZE="$(size boot-repack.img)"
[ "$NSIZE" -le "$PSIZE" ] || die "patched image ($NSIZE bytes) does not fit into the partition ($PSIZE bytes) - nothing was written"
ok "patched image: $NSIZE bytes"

# ---- write -------------------------------------------------------------------
echo
warn "About to overwrite $PART"
if [ "${YES:-0}" != 1 ]; then
  read -r -p "Type YES to continue: " ans || die "aborted"
  [ "$ans" = YES ] || die "aborted, nothing was written"
fi

if write_verify boot-repack.img; then
  ok "written and verified"
else
  warn "verify failed - restoring backup"
  write_verify "$BACKUP" || die "RESTORE FAILED. Run now:  dd if=$BACKUP of=$PART bs=1M conv=fsync"
  die "write failed, original boot_a restored"
fi

echo
echo "${G}${B}Done.${Z}  boot_a patched with $(basename "$SHELLCODE" .bin). Reboot to test."
echo "Undo:  dd if=$BACKUP of=$PART bs=1M conv=fsync"
