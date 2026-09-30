# Dual boot Android + Linux on the Xiaomi Pad 6 (Pipa)

Android or UEFI/Linux is chosen at power-on by a condition such as the magnetic cover. The script in the release zip does the whole `boot_a` patch for you: back up, unpack, patch the kernel with the Mu UEFI, repack, write, verify.

> **The scripts in this repo were written with an LLM. Use with caution.**

## Warnings
- **Erasing userdata removes all your files in Android** (only needed for the ESP in the GRUB example). Back up anything you want to keep first.
- The script backs up `boot_a` for you, but also keep a copy somewhere off the tablet and make sure you can reach fastboot.
- The zip includes prebuilt Mu UEFI and magiskboot binaries from third-party repos. If you prefer, build the zip yourself (below).

## 1. Download
Download `DualBoot-Pipa.zip` and its `.sha256` from the [Releases](https://github.com/<you>/<repo>/releases) page, then:
```bash
sha256sum -c DualBoot-Pipa.zip.sha256
unzip DualBoot-Pipa.zip && cd DualBoot-Pipa
```
The zip has everything needed (patcher, magiskboot, Mu UEFI, config, shell codes), so nothing else needs installing.

### Or build the zip yourself
```bash
sudo apt install curl git file zip unzip gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libc6-dev-arm64-cross
git clone --depth 1 https://github.com/<you>/<repo>
cd <repo> && bash build.sh      # -> dist/DualBoot-Pipa.zip
```
`build.sh` downloads Mu and magiskboot with curl and shallow-clones the patcher repo (`git clone --depth 1`). Shell codes in the patcher repo are built automatically.

## 2. Patch boot_a
> **Warning: the script assumes your Linux is currently running from slot b.** It patches `boot_a` (the Android slot). Do not run it if you are booted from slot a, or you will overwrite the boot image you are running.

Run this on the tablet from Linux, as root:
```bash
sudo ./patch_boot_a.sh
```
It lists the shell codes and you type a number:

| Shell code            | UEFI boots when                           | Android boots when |
|-----------------------|-------------------------------------------|--------------------|
| `Pipa.Magnetic.cover` | cover open (GPIO 110 reads 1)             | cover closed       |
| `Pipa.Orientation`    | `androidboot.ori=03` (inverted landscape) | anything else      |

It then reads `/dev/disk/by-partlabel/boot_a`, saves a backup to `backups/`, patches, checks the size fits, asks you to type `YES`, writes, and verifies. If verification fails it restores the backup by itself.

Options:
- `sudo ./patch_boot_a.sh 1` picks a shell code without asking.
- `YES=1` skips the final confirmation.
- `BOOT_PART=/path` patches another partition or an image file instead.

The tablet now picks the OS on its own at boot.

## 3. Example: boot Linux with an embedded GRUB
This part is only an example of how to get Linux started from the UEFI. Any loader that ends up at `EFI/BOOT/BOOTAA64.EFI` on the ESP works, so adapt it to your distro.

### Create the ESP
Use GParted to erase the `userdata` partition. Then create it again with the name `userdata`, and add a new **280MB FAT32 partition named `esp`** (set the `esp` flag). Then mount it:
```bash
mkdir -p /boot/efi
mount /dev/disk/by-partlabel/esp /boot/efi
mkdir -p /boot/efi/EFI/BOOT
```

### Build the embedded GRUB
Save this as `build-grub.sh`:
```bash
#!/bin/bash
set -e

SRC=/boot
DTB=/boot/dtbs/qcom/sm8250-xiaomi-pipa.dtb
FONT=/usr/share/grub/unicode.pf2
OUT=/boot/efi/EFI/BOOT/BOOTAA64.EFI
CFG=$(mktemp)

for f in "$SRC/Image" "$SRC/initramfs.img" "$DTB" "$FONT"; do
  [ -f "$f" ] || { echo "Missing $f"; exit 1; }
done

cat > "$CFG" <<'EOF'
insmod all_video
insmod efi_gop
insmod font
insmod gfxterm
loadfont (memdisk)/boot/grub/fonts/unicode.pf2
set gfxmode=auto
set gfxpayload=keep
terminal_output gfxterm

set timeout=3
set default=0

menuentry "Artix (Embedded)" {
    devicetree (memdisk)/boot/pipa/sm8250-xiaomi-pipa.dtb
    linux (memdisk)/boot/pipa/Image root=LABEL=armtix rootwait rw loglevel=7 console=tty0 earlycon=tty0 keep_bootcon fbcon=rotate:1,font:VGA8x16
    initrd (memdisk)/boot/pipa/initramfs.img
}
EOF

grub-mkstandalone -O arm64-efi \
  -o "$OUT" \
  --install-modules="normal linux fdt font all_video efi_gop gfxterm part_gpt fat ext2 echo" \
  "boot/grub/grub.cfg=$CFG" \
  "boot/grub/fonts/unicode.pf2=$FONT" \
  "boot/pipa/Image=$SRC/Image" \
  "boot/pipa/initramfs.img=$SRC/initramfs.img" \
  "boot/pipa/sm8250-xiaomi-pipa.dtb=$DTB"

rm -f "$CFG"
sync
ls -lh "$OUT"
```
Run it with `sudo bash build-grub.sh`. No separate `grub-install` is needed, because the script writes the loader to `EFI/BOOT/BOOTAA64.EFI`, the path the firmware looks for.

Notes:
- The result is one EFI file of about 40MB or more, holding the kernel, initramfs, DTB, and font.
- If the DTB isn't found, check with `ls /boot/dtbs/qcom/ | grep pipa`.
- If `grub-mkstandalone` complains about a missing module, make sure `fdt` is in `--install-modules`.
- Squares in the menu mean the font is missing. The `unicode.pf2` graft point prevents that.
- Change `root=LABEL=armtix` to your own root label.
- Everything is baked into `BOOTAA64.EFI`, so rerun `build-grub.sh` after every kernel, initramfs, or DTB update. A pacman hook can automate this.

## Recovery
- Undo the patch: `dd if=backups/boot_a-<time>.img of=/dev/disk/by-partlabel/boot_a bs=1M conv=fsync`, or from fastboot: `fastboot flash boot_a backups/boot_a-<time>.img`.
- Android won't boot: reflash the backup as above.
- Linux won't boot: set the Android condition (cover closed, or a non-matching orientation), then fix the ESP from Android or a fastboot-booted recovery.
