#!/usr/bin/env bash
# macOS Tahoe on QEMU/KVM via OSX-KVM (https://github.com/kholia/OSX-KVM)
# https://github.com/DrDonk/recoveryOS
#
# Usage:
#   bash macos-kvm.sh                 - full setup (packages, KVM, recovery image, disk, launch script tweaks)
#   macos-kvm run                     - start the VM
#   macos-kvm shot [file]             - save a PNG screenshot of the VM display (default: ./screen.png)
#   macos-kvm usb attach [VID:PID]    - pass a host USB device (default: iPhone/any Apple) through to the VM
#   macos-kvm usb detach              - give it back to the host (attach also unloads ipheth/apple-mfi-fastcharge
#                                       and masks usbmuxd on the host, at runtime only; detach undoes that)
#   macos-kvm ssh [COMMAND...]       - open a shell in the VM, or run a command there and print its output
#   macos-kvm send FILE...          - copy files/dirs into the VM over scp (default ~/Desktop/)
#   macos-kvm get REMOTE [DIR]        - copy a file/dir from the VM to DIR (default: current dir)
#   macos-kvm link                    - symlink this script to ~/.local/bin/macos-kvm (done by the full setup too)
#   macos-kvm unlink                  - remove that symlink
#
# watch -n1 'lsusb | grep -i apple'
#
# The run/shot/link/unlink commands work from any directory once the symlink exists
# (before that, use: bash /path/to/macos-kvm.sh <command>).
#
# Optional environment variables:
#   RAM=8192 CORES=6 DISK_SIZE=60G OS=tahoe INSTALL_DIR=$HOME/OSX-KVM
#   MAC_USER=<macOS account> MAC_PORT=2222 MAC_DEST=~/Desktop/   (for send/get; needs
#   System Settings -> General -> Sharing -> Remote Login enabled in macOS)

set -euo pipefail

# Resolve the real script path even when invoked through a symlink
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
LINK_DIR="${LINK_DIR:-$HOME/.local/bin}"
LINK="$LINK_DIR/macos-kvm"

INSTALL_DIR="${INSTALL_DIR:-$HOME/OSX-KVM}"
RAM="${RAM:-8192}"          # MiB
CORES="${CORES:-6}"          # guest cores (one thread each)
DISK_SIZE="${DISK_SIZE:-60G}"
OS="${OS:-tahoe}"            # high-sierra ... sequoia, tahoe
QMP="${QMP:-/tmp/qemu-qmp.sock}"
MAC_USER="${MAC_USER:-${USER:-$(id -un)}}"      # account name inside macOS
MAC_PORT="${MAC_PORT:-2222}"         # host port forwarded to guest :22 (hostfwd in OpenCore-Boot.sh)
MAC_DEST="${MAC_DEST:-~/Desktop/}"   # where "send" puts files in the guest
SCP_OPTS=(-P "$MAC_PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/known_hosts_macos-kvm")

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN} ok${NC}  $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

link_script() {
    mkdir -p "$LINK_DIR"
    ln -sfn "$SELF" "$LINK"
    ok "Symlink: $LINK -> $SELF"
    case ":$PATH:" in
        *":$LINK_DIR:"*) ;;
        *) warn "$LINK_DIR is not in PATH - add to ~/.bashrc:  export PATH=\"$LINK_DIR:\$PATH\"" ;;
    esac
}

# -----------------------------------------------------------------------------
# Subcommands
# -----------------------------------------------------------------------------
case "${1:-}" in
    link)
        link_script
        exit 0 ;;
    unlink)
        if [ -L "$LINK" ]; then rm "$LINK"; ok "Removed $LINK"; else warn "No symlink at $LINK"; fi
        exit 0 ;;
    run)
        [ -x "$INSTALL_DIR/OpenCore-Boot.sh" ] || die "$INSTALL_DIR/OpenCore-Boot.sh not found - run the full setup first: macos-kvm"
        cd "$INSTALL_DIR"
        exec ./OpenCore-Boot.sh ;;
    shot)
        OUT="$(realpath -m "${2:-./screen.png}")"
        [ -S "$QMP" ] || die "Socket $QMP not found - the VM is not running or was started without -qmp"
        command -v socat >/dev/null || die "socat is required: sudo apt install socat"
        printf '%s\n' '{"execute":"qmp_capabilities"}' \
            "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$OUT\",\"format\":\"png\"}}" \
            | socat - "UNIX-CONNECT:$QMP" >/dev/null
        ok "Screenshot saved: $OUT"
        exit 0 ;;
    usb)
        command -v socat >/dev/null || die "socat is required: sudo apt install socat"
        USB_ID="${USB_ID:-usbdev}"       # QEMU device id used for attach/detach
        USB_BUS="${USB_BUS:-xhci.0}"     # guest USB controller (id=xhci in OpenCore-Boot.sh)
        MODPROBE_CONF=/run/modprobe.d/macos-kvm-usb.conf
        qmp() { { printf '%s\n' '{"execute":"qmp_capabilities"}' "$1"; sleep 1; } | socat -t2 - "UNIX-CONNECT:$QMP" | tail -1; }
        # While the device is in the VM, keep the host from grabbing it: ipheth / apple-mfi-fastcharge / usbmuxd
        # re-bind on every re-enumeration and fight QEMU. Runtime-only (/run), undone by "usb detach" or a reboot.
        host_prepare() {
            sudo mkdir -p "$(dirname "$MODPROBE_CONF")"
            printf 'blacklist ipheth\nblacklist apple-mfi-fastcharge\n' | sudo tee "$MODPROBE_CONF" >/dev/null
            sudo systemctl mask --runtime --now usbmuxd 2>/dev/null || true
            sudo modprobe -r ipheth apple-mfi-fastcharge 2>/dev/null || true
        }
        host_restore() {
            sudo rm -f "$MODPROBE_CONF"
            sudo systemctl unmask --runtime usbmuxd 2>/dev/null || true
            sudo modprobe ipheth apple-mfi-fastcharge 2>/dev/null || true
        }
        case "${2:-}" in
            attach)
                [ -S "$QMP" ] || die "Socket $QMP not found - the VM is not running or was started without -qmp"
                DEV="${3:-05ac:}"        # vendor:product, default: first Apple device (iPhone)
                IDS="$(lsusb -d "$DEV" | head -1 | grep -oE 'ID [0-9a-f]{4}:[0-9a-f]{4}' | cut -d' ' -f2 || true)"
                [ -n "$IDS" ] || die "USB device '$DEV' not found on the host (lsusb)"
                info "Freeing the device on the host (sudo)..."
                host_prepare
                # A fresh attach is needed: re-adding lets the guest's usbmuxd pick the device up
                qmp "{\"execute\":\"device_del\",\"arguments\":{\"id\":\"$USB_ID\"}}" >/dev/null || true
                sleep 3
                # guest-reset=false: forwarding the guest's USB resets makes an iPhone re-enumerate in an endless loop
                R="$(qmp "{\"execute\":\"device_add\",\"arguments\":{\"driver\":\"usb-host\",\"bus\":\"$USB_BUS\",\"vendorid\":$((16#${IDS%:*})),\"productid\":$((16#${IDS#*:})),\"id\":\"$USB_ID\",\"guest-reset\":false,\"guest-resets-all\":false}}")"
                case "$R" in *'"error"'*) die "device_add failed: $R" ;; esac
                ok "USB $IDS attached to the VM (id=$USB_ID)" ;;
            detach)
                if [ -S "$QMP" ]; then
                    R="$(qmp "{\"execute\":\"device_del\",\"arguments\":{\"id\":\"$USB_ID\"}}")"
                    case "$R" in *'"error"'*) warn "device_del: $R" ;; esac
                    sleep 1
                fi
                host_restore   # also works when the VM is already stopped
                ok "USB device returned to the host (driver blacklist and usbmuxd mask removed)" ;;
            *)
                die "Usage: macos-kvm usb attach [VID:PID] | usb detach   (default device: any Apple, 05ac:)" ;;
        esac
        exit 0 ;;
    ssh)
        shift
        command -v ssh >/dev/null || die "ssh is required: sudo apt install openssh-client"
        exec ssh -p "$MAC_PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/known_hosts_macos-kvm" "$MAC_USER@localhost" "$@" ;;
    send)
        shift
        [ "$#" -gt 0 ] || die "Usage: macos-kvm send FILE_OR_DIR... (destination: \$MAC_DEST, default ~/Desktop/)"
        for f in "$@"; do [ -e "$f" ] || die "Not found: $f"; done
        command -v scp >/dev/null || die "scp is required: sudo apt install openssh-client"
        scp "${SCP_OPTS[@]}" -r "$@" "$MAC_USER@localhost:$MAC_DEST"
        ok "Sent to $MAC_USER@VM:$MAC_DEST"
        exit 0 ;;
    get)
        [ -n "${2:-}" ] || die "Usage: macos-kvm get REMOTE_PATH [LOCAL_DIR]  (relative paths are from the macOS home)"
        command -v scp >/dev/null || die "scp is required: sudo apt install openssh-client"
        scp "${SCP_OPTS[@]}" -r "$MAC_USER@localhost:$2" "${3:-.}"
        ok "Copied from VM to ${3:-.}"
        exit 0 ;;
    "")
        ;;  # no argument: full setup below
    *)
        die "Unknown command '$1'. Use: run | shot [file] | usb attach|detach | ssh [cmd] | send FILE... | get REMOTE [DIR] | link | unlink (no argument = full setup)" ;;
esac

# -----------------------------------------------------------------------------
# 1. KVM
# -----------------------------------------------------------------------------
info "Checking KVM..."
[ "$(grep -cE '(vmx|svm)' /proc/cpuinfo || true)" -gt 0 ] || die "No VT-x/AMD-V - enable virtualization in BIOS/UEFI"
[ -e /dev/kvm ] || sudo modprobe kvm-intel 2>/dev/null || sudo modprobe kvm-amd 2>/dev/null || die "Failed to load the kvm module"
ok "KVM available"

# macOS crashes without ignore_msrs
echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs >/dev/null
echo 'options kvm ignore_msrs=1 report_ignored_msrs=0' | sudo tee /etc/modprobe.d/kvm.conf >/dev/null
ok "kvm ignore_msrs=1 (now and after reboot)"

# -----------------------------------------------------------------------------
# 2. Packages and groups
# -----------------------------------------------------------------------------
info "Installing packages..."
sudo apt-get update -qq
sudo apt-get install -y qemu-system-x86 qemu-utils ovmf dmg2img git wget socat python3
ok "Packages installed"

QEMU_VER="$(qemu-system-x86_64 --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
info "QEMU $QEMU_VER (>= 8.2 required)"
if ! id -nG | grep -qw kvm; then
    sudo usermod -aG kvm "$USER"
    warn "Added to the kvm group - log out and back in, or run: newgrp kvm"
fi

# -----------------------------------------------------------------------------
# 3. OSX-KVM
# -----------------------------------------------------------------------------
info "OSX-KVM -> $INSTALL_DIR"
if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --ff-only || true
else
    git clone --depth 1 --recursive https://github.com/kholia/OSX-KVM.git "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
ok "Repository ready"

# -----------------------------------------------------------------------------
# 4. Recovery image (skipped if BaseSystem.img already exists)
# -----------------------------------------------------------------------------
if [ -f BaseSystem.img ]; then
    ok "BaseSystem.img already exists - download skipped"
else
    info "Downloading recovery image: $OS ..."
    ./fetch-macOS-v2.py --shortname "$OS"
    DMG="$(find . -maxdepth 2 -name 'BaseSystem.dmg' | head -1)"
    [ -n "$DMG" ] || die "BaseSystem.dmg not found after fetch-macOS-v2.py"
    info "Converting to BaseSystem.img..."
    dmg2img -i "$DMG" BaseSystem.img
    ok "BaseSystem.img created"
fi

# -----------------------------------------------------------------------------
# 5. System disk
# -----------------------------------------------------------------------------
if [ -f mac_hdd_ng.img ]; then
    ok "mac_hdd_ng.img already exists"
else
    qemu-img create -f qcow2 mac_hdd_ng.img "$DISK_SIZE"
    ok "Disk created: $DISK_SIZE (qcow2, grows on write)"
fi

# -----------------------------------------------------------------------------
# 6. Tweak OpenCore-Boot.sh
# -----------------------------------------------------------------------------
F="OpenCore-Boot.sh"
[ -f "$F" ] || die "$F not found in $INSTALL_DIR"
[ -f "$F.orig" ] || cp "$F" "$F.orig"

sed -i -E "s/^ALLOCATED_RAM=\"[0-9]+\"/ALLOCATED_RAM=\"$RAM\"/"   "$F"
sed -i -E 's/^CPU_SOCKETS="[0-9]+"/CPU_SOCKETS="1"/'              "$F"
sed -i -E "s/^CPU_CORES=\"[0-9]+\"/CPU_CORES=\"$CORES\"/"         "$F"
sed -i -E "s/^CPU_THREADS=\"[0-9]+\"/CPU_THREADS=\"$CORES\"/"     "$F"

# Sequoia/Tahoe: the Skylake-Client line must be active, Penryn commented out
sed -i -E 's/^(\s*)(-enable-kvm .* -cpu Penryn)/\1# \2/'                  "$F"
sed -i -E 's/^(\s*)#\s*(-enable-kvm .* -cpu Skylake-Client)/\1\2/'        "$F"

# QMP socket for screenshots (the "shot" subcommand)
grep -q -- '-qmp ' "$F" || sed -i -E "s|^(\s*)-monitor stdio|\1-monitor stdio\n\1-qmp unix:$QMP,server,nowait|" "$F"

chmod +x "$F"
ok "$F configured: ${RAM} MiB, ${CORES} cores (original saved as $F.orig)"

# -----------------------------------------------------------------------------
# 7. Command symlink (run/shot from any directory)
# -----------------------------------------------------------------------------
link_script

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo
echo -e "${GREEN}Done.${NC} Start the VM with:  macos-kvm run"
echo "In the QEMU window:"
echo "  1. In the OpenCore menu pick \"macOS Base System (External)\""
echo "  2. Disk Utility -> QEMU HARDDISK (the large one) -> Erase -> APFS, GUID"
echo "  3. Reinstall macOS -> select that disk (internet access required)"
echo "  4. After each reboot pick \"macOS Installer\", then \"macOS\""
echo "Screenshot of the VM display:  macos-kvm shot"
