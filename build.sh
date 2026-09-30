#!/usr/bin/env bash
# build.sh - pull everything, build everything, pack one release zip.
#
#   ./build.sh            -> dist/DualBoot-Pipa.zip (+ .sha256)
#
# Pulls   Mu-pipa.fd + magiskboot (arm64, x86_64)   from Pipa-Dualboot/*
# Clones  DualBootKernelPatcherPipa                  (tools + shell codes + config)
# Builds  DualBootKernelPatcher / DualBootPatchRemover / HDRTool  (static, arm64 + x86_64)
# Builds  every ShellCode/*.S  (except the DummyHead/CommonTail includes) -> .bin
#
# Host: x86_64 Linux with gcc-aarch64-linux-gnu, binutils-aarch64-linux-gnu, libc6-dev-arm64-cross,
#       curl, git, file, zip.  (An arm64 host works too, it then cross-builds x86_64.)
# Every URL / ref below can be overridden from the environment (used for offline testing).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="${DIST:-$ROOT/dist}"
NAME="DualBoot-Pipa"
PKG="$DIST/$NAME"

RAW="https://raw.githubusercontent.com/Pipa-Dualboot"
MU_URL="${MU_URL:-$RAW/Build-MuSilicium/main/Mu-pipa.fd}"
MB_ARM64_URL="${MB_ARM64_URL:-$RAW/Build-Magiskboot/main/arm64-v8a/magiskboot}"
MB_X64_URL="${MB_X64_URL:-$RAW/Build-Magiskboot/main/x86_64/magiskboot}"
PATCHER_REPO="${PATCHER_REPO:-https://github.com/Pipa-Dualboot/DualBootKernelPatcherPipa}"
PATCHER_REF="${PATCHER_REF:-main}"
PATCHER_SRC="${PATCHER_SRC:-}"          # use a local checkout instead of cloning

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# ---- toolchain ---------------------------------------------------------------
if [ "$(uname -m)" = x86_64 ]; then
  CC_X64=gcc;                CC_A64=aarch64-linux-gnu-gcc
  AS=aarch64-linux-gnu-as;   OBJCOPY=aarch64-linux-gnu-objcopy
else
  CC_X64=x86_64-linux-gnu-gcc; CC_A64=gcc
  AS=as;                       OBJCOPY=objcopy
fi
for t in curl git file zip sha256sum unzip "$CC_X64" "$CC_A64" "$AS" "$OBJCOPY"; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done

rm -rf "$DIST"; mkdir -p "$PKG"/{bin/arm64,bin/x86_64,magiskboot/arm64,magiskboot/x86_64,ShellCode,Config,uefi}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- 1. pull prebuilt files --------------------------------------------------
# fetch URL DEST MIN_BYTES  (the size check catches HTML error pages and git-lfs pointers)
fetch() {
  curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1" || die "download failed: $1"
  local n; n="$(wc -c < "$2" | tr -d ' ')"
  [ "$n" -ge "$3" ] || die "$1 is only $n bytes (error page or LFS pointer?)"
  echo "    $(basename "$2")  $n bytes"
}
# want_elf FILE REGEX  (fails if FILE is not an ELF for the expected CPU)
want_elf() {
  file -b "$1" | grep -Eq "^ELF .*($2)" || die "$1 is not the expected binary type ($2): $(file -b "$1")"
}

step "Pulling Mu UEFI + magiskboot"
fetch "$MU_URL"       "$PKG/uefi/Mu-pipa.fd"                   102400
fetch "$MB_ARM64_URL" "$PKG/magiskboot/arm64/magiskboot"       102400
fetch "$MB_X64_URL"   "$PKG/magiskboot/x86_64/magiskboot"      102400
want_elf "$PKG/magiskboot/arm64/magiskboot"  "ARM aarch64"
want_elf "$PKG/magiskboot/x86_64/magiskboot" "x86-64"

# ---- 2. patcher sources ------------------------------------------------------
step "Getting patcher sources"
if [ -n "$PATCHER_SRC" ]; then
  SRC="$(cd "$PATCHER_SRC" && pwd)"
  PATCHER_COMMIT="local"
else
  SRC="$TMP/patcher"
  git clone -q --depth 1 --branch "$PATCHER_REF" "$PATCHER_REPO" "$SRC" || die "clone failed: $PATCHER_REPO"
  PATCHER_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
fi
for f in patcher.c remover.c HDRTool.c utils.c utils.h Config/DualBoot.Sm8250.cfg \
         ShellCode/DummyHead.S ShellCode/CommonTail.S LICENSE; do
  [ -f "$SRC/$f" ] || die "patcher repo is missing $f"
done
echo "    $PATCHER_REPO @ ${PATCHER_COMMIT:0:12}"

# ---- 3. tools, static, both architectures -----------------------------------
step "Building tools"
for pair in "arm64:$CC_A64:ARM aarch64" "x86_64:$CC_X64:x86-64"; do
  IFS=: read -r arch cc want <<< "$pair"
  for t in DualBootKernelPatcher:patcher.c DualBootPatchRemover:remover.c HDRTool:HDRTool.c; do
    out="$PKG/bin/$arch/${t%%:*}"
    "$cc" -O2 -s -static -o "$out" "$SRC/${t##*:}" "$SRC/utils.c" -I"$SRC" || die "build failed: $arch ${t%%:*}"
    want_elf "$out" "$want"
    echo "    bin/$arch/${t%%:*}"
  done
done

# ---- 4. shell codes ----------------------------------------------------------
# Every ShellCode/*.S is a shell code, except the two files that are only .include'd.
# (Deliberately no name pattern: the old CMake glob "ShellCode.*.S" matched nothing.)
step "Assembling shell codes"
count=0
for s in "$SRC"/ShellCode/*.S; do
  base="$(basename "$s" .S)"
  case "$base" in DummyHead|CommonTail) continue ;; esac
  "$AS" -I "$SRC/ShellCode" -o "$TMP/$base.o" "$s"          || die "assemble failed: $base.S"
  "$OBJCOPY" -O binary "$TMP/$base.o" "$PKG/ShellCode/$base.bin" || die "objcopy failed: $base"
  n="$(wc -c < "$PKG/ShellCode/$base.bin" | tr -d ' ')"
  [ "$n" -gt 64 ] || die "$base.bin is only $n bytes"
  # the patcher rejects a shell code without the "SHLLCOD" magic at 0x08
  [ "$(dd if="$PKG/ShellCode/$base.bin" bs=1 skip=8 count=7 2>/dev/null)" = "SHLLCOD" ] \
    || die "$base.bin has no SHLLCOD magic at 0x08"
  echo "    ShellCode/$base.bin  $n bytes"
  count=$((count + 1))
done
[ "$count" -gt 0 ] || die "no shell code found in $SRC/ShellCode"

# ---- 5. assemble the package -------------------------------------------------
step "Packing"
cp "$SRC/Config/DualBoot.Sm8250.cfg" "$PKG/Config/"
cp "$SRC/LICENSE" "$PKG/LICENSE-DualBootKernelPatcher"
cp "$ROOT/patch_boot_a.sh" "$ROOT/README.md" "$PKG/"
chmod +x "$PKG/patch_boot_a.sh" "$PKG"/bin/*/* "$PKG"/magiskboot/*/magiskboot

cat > "$PKG/BUILD_INFO.txt" <<INFO
built    $(date -u +%Y-%m-%dT%H:%M:%SZ)
patcher  $PATCHER_REPO @ $PATCHER_COMMIT
uefi     $MU_URL
magisk   $MB_ARM64_URL
         $MB_X64_URL
INFO

( cd "$PKG" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )

( cd "$DIST" && rm -f "$NAME.zip" && zip -qr -X "$NAME.zip" "$NAME" )
( cd "$DIST" && sha256sum "$NAME.zip" > "$NAME.zip.sha256" )

# ---- 6. verify the zip has everything patch_boot_a.sh expects ----------------
step "Verifying zip"
LIST="$(unzip -Z1 "$DIST/$NAME.zip")"
REQ=(patch_boot_a.sh README.md SHA256SUMS BUILD_INFO.txt uefi/Mu-pipa.fd Config/DualBoot.Sm8250.cfg
     magiskboot/arm64/magiskboot magiskboot/x86_64/magiskboot)
for a in arm64 x86_64; do REQ+=("bin/$a/DualBootKernelPatcher" "bin/$a/DualBootPatchRemover" "bin/$a/HDRTool"); done
for b in "$PKG"/ShellCode/*.bin; do REQ+=("ShellCode/$(basename "$b")"); done
for r in "${REQ[@]}"; do
  grep -qxF "$NAME/$r" <<< "$LIST" || die "zip is missing $r"
done
echo "    ${#REQ[@]} required files present"

echo; echo "Done: $DIST/$NAME.zip ($(wc -c < "$DIST/$NAME.zip" | tr -d ' ') bytes)"
