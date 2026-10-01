#!/usr/bin/env bash
# Removes what macos-kvm.sh set up on this machine: the OSX-KVM directory (with the macOS disk), the `macos-kvm`
# symlink, the ssh known_hosts file, runtime USB/QMP leftovers, the persistent KVM option, and - after a question -
# the kvm group membership and the QEMU / helper packages. This repository itself is never touched.
#
# Usage:
#   bash uninstall.sh [--dry-run] [--yes]        (or: macos-kvm uninstall [--dry-run] [--yes])
#     -n, --dry-run   only print what would be done
#     -y, --yes       answer "yes" to every question, INCLUDING deleting the macOS disk (mac_hdd_ng.img)
#
# Optional environment variables (same names and defaults as in macos-kvm.sh):
#   INSTALL_DIR=$HOME/OSX-KVM  LINK_DIR=$HOME/.local/bin  QMP=/tmp/qemu-qmp.sock

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/OSX-KVM}"
LINK_DIR="${LINK_DIR:-$HOME/.local/bin}"
LINK="$LINK_DIR/macos-kvm"
QMP="${QMP:-/tmp/qemu-qmp.sock}"
KNOWN_HOSTS="${KNOWN_HOSTS:-$HOME/.ssh/known_hosts_macos-kvm}"
KVM_CONF="${KVM_CONF:-/etc/modprobe.d/kvm.conf}"
KVM_CONF_CONTENT='options kvm ignore_msrs=1 report_ignored_msrs=0'      # exactly what macos-kvm.sh writes
IGNORE_MSRS="${IGNORE_MSRS:-/sys/module/kvm/parameters/ignore_msrs}"
MODPROBE_CONF="${MODPROBE_CONF:-/run/modprobe.d/macos-kvm-usb.conf}"    # runtime file of "macos-kvm usb attach"
QEMU_PKGS=(qemu-system-x86 qemu-utils)
HELPER_PKGS=(dmg2img libguestfs-tools ovmf socat)   # git wget curl unzip perl python3 are general tools: never removed

DRY_RUN=""; ASSUME_YES=""
for a in "$@"; do
    case "$a" in
        -n|--dry-run) DRY_RUN=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option '$a' (use --dry-run, --yes, --help)" >&2; exit 1 ;;
    esac
done

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN} ok${NC}  $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# Runs a command, or only prints it with --dry-run
act() {
    if [ -n "$DRY_RUN" ]; then echo -e "    ${YELLOW}would run:${NC} $*"; else "$@"; fi
}
# Yes/No question, default No. Without a terminal (and without --yes) the answer is No. --dry-run answers Yes to list everything.
ask() {
    [ -z "$ASSUME_YES$DRY_RUN" ] || return 0
    [ -t 0 ] || return 1
    local a; read -r -p "$1 [y/N] " a
    [[ "$a" =~ ^([yY]|[yY][eE][sS]|[дД]|[дД][аА])$ ]]
}
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
REMOVED=(); KEPT=()

[ -z "$DRY_RUN" ] || warn "Dry run: nothing will be changed"

# --- 0. A running VM would hold the files -------------------------------------------------------------------------
if pgrep -f qemu-system-x86_64 >/dev/null 2>&1; then
    die "A qemu-system-x86_64 process is running - shut the VM down first (and re-run this script)"
fi

# --- 1. Runtime leftovers of "usb attach" (host drivers blacklisted, usbmuxd masked) and the QMP socket ----------
info "Host USB state and QMP socket"
if [ -e "$MODPROBE_CONF" ] || systemctl is-enabled usbmuxd 2>/dev/null | grep -q 'masked-runtime'; then
    act sudo rm -f "$MODPROBE_CONF"
    act sudo systemctl unmask --runtime usbmuxd
    act sudo modprobe ipheth apple-mfi-fastcharge || true
    REMOVED+=("runtime USB blacklist / usbmuxd mask")
else
    ok "no runtime USB leftovers"
fi
if [ -S "$QMP" ] || [ -e "$QMP" ]; then act rm -f "$QMP"; REMOVED+=("$QMP"); fi

# --- 2. Command symlink and ssh known_hosts --------------------------------------------------------------------
info "Command symlink and ssh host keys"
if [ -L "$LINK" ]; then
    case "$(readlink "$LINK")" in
        */macos-kvm.sh) act rm -f "$LINK"; REMOVED+=("$LINK") ;;
        *) warn "$LINK points to $(readlink "$LINK") - not ours, left in place"; KEPT+=("$LINK") ;;
    esac
else
    ok "no symlink at $LINK"
fi
for f in "$KNOWN_HOSTS" "$KNOWN_HOSTS.old"; do
    if [ -e "$f" ]; then act rm -f "$f"; REMOVED+=("$f"); fi
done

# --- 3. OSX-KVM directory (clone, recovery image, OpenCore, and the macOS system disk) -------------------------
info "OSX-KVM directory: $INSTALL_DIR"
if [ -d "$INSTALL_DIR" ]; then
    REAL="$(realpath "$INSTALL_DIR")"; HERE="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
    case "$REAL" in
        /|"$(realpath "$HOME")"|"$(realpath "$HOME")"/) die "Refusing to delete $REAL" ;;
    esac
    [ -f "$REAL/OpenCore-Boot.sh" ] || die "$REAL does not look like OSX-KVM (no OpenCore-Boot.sh) - not deleting it"
    case "$HERE/" in "$REAL"/*) die "This script lives inside $REAL - not deleting it" ;; esac
    echo "    size: $(du -sh "$REAL" 2>/dev/null | cut -f1)"
    if [ -f "$REAL/mac_hdd_ng.img" ]; then
        warn "It contains the macOS system disk (mac_hdd_ng.img, $(du -h "$REAL/mac_hdd_ng.img" | cut -f1)): installed macOS, accounts and files are lost for good"
    fi
    if ask "Delete $REAL?"; then act rm -rf -- "$REAL"; REMOVED+=("$REAL"); else warn "kept $REAL"; KEPT+=("$REAL"); fi
else
    ok "$INSTALL_DIR does not exist"
fi

# --- 4. Persistent KVM option written by the setup -----------------------------------------------------------
info "KVM module option"
if [ -f "$KVM_CONF" ] && [ "$(cat "$KVM_CONF")" = "$KVM_CONF_CONTENT" ]; then
    act sudo rm -f "$KVM_CONF"
    if [ -e "$IGNORE_MSRS" ]; then act sudo sh -c "echo 0 > '$IGNORE_MSRS'"; fi
    REMOVED+=("$KVM_CONF (+ ignore_msrs back to 0)")
elif [ -f "$KVM_CONF" ]; then
    warn "$KVM_CONF has other content than the setup writes - left in place"; KEPT+=("$KVM_CONF")
else
    ok "no $KVM_CONF"
fi

# --- 5. kvm group membership (the setup adds the user if missing) ----------------------------------------------
info "kvm group"
if id -nG "$USER" 2>/dev/null | grep -qw kvm; then
    if ask "Remove $USER from the kvm group? (other VM tools such as libvirt/virt-manager may need it)"; then
        act sudo gpasswd -d "$USER" kvm; REMOVED+=("kvm group membership (log out/in to apply)")
    else
        KEPT+=("kvm group membership")
    fi
else
    ok "$USER is not in the kvm group"
fi

# --- 6. Packages (plain purge, no --auto-remove: leftover dependencies may belong to other tools) ----------------
info "Packages"
PKGS=(); for p in "${QEMU_PKGS[@]}"; do pkg_installed "$p" && PKGS+=("$p"); done
if [ "${#PKGS[@]}" -gt 0 ]; then
    if ask "Uninstall QEMU (${PKGS[*]})? apt shows the full list first"; then
        if [ -n "$ASSUME_YES" ]; then act sudo apt-get purge -y "${PKGS[@]}"; else act sudo apt-get purge "${PKGS[@]}"; fi
        REMOVED+=("QEMU packages")
    else
        KEPT+=("QEMU packages")
    fi
else
    ok "QEMU packages are not installed"
fi
PKGS=(); for p in "${HELPER_PKGS[@]}"; do pkg_installed "$p" && PKGS+=("$p"); done
if [ "${#PKGS[@]}" -gt 0 ]; then
    if ask "Uninstall helper packages the setup installed (${PKGS[*]})? You may use them elsewhere"; then
        if [ -n "$ASSUME_YES" ]; then act sudo apt-get purge -y "${PKGS[@]}"; else act sudo apt-get purge "${PKGS[@]}"; fi
        REMOVED+=("helper packages: ${PKGS[*]}")
    else
        KEPT+=("helper packages")
    fi
fi

# --- Summary ---------------------------------------------------------------------------------------------------
echo
[ -z "$DRY_RUN" ] && echo -e "${GREEN}Done.${NC}" || echo -e "${YELLOW}Dry run finished - nothing was changed.${NC}"
[ "${#REMOVED[@]}" -eq 0 ] || { [ -n "$DRY_RUN" ] && echo "Would remove:" || echo "Removed:"; printf '  - %s\n' "${REMOVED[@]}"; }
[ "${#KEPT[@]}" -eq 0 ] || { echo "Kept:"; printf '  - %s\n' "${KEPT[@]}"; }
echo "Leftover dependencies are not removed automatically; review them with: sudo apt autoremove --dry-run"
echo "Not touched: this repository ($(realpath "$(dirname "${BASH_SOURCE[0]}")")), git/wget/curl/unzip/perl/python3, and anything you installed for other purposes"
echo "(for example pymobiledevice3, libimobiledevice, ipatool). Remove the repository folder by hand if you do not need it."
