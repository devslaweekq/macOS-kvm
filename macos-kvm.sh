#!/usr/bin/env bash
# macOS Tahoe on QEMU/KVM via OSX-KVM (https://github.com/kholia/OSX-KVM)
# https://github.com/DrDonk/recoveryOS
#
# Usage:
#   bash macos-kvm.sh                 - full setup (packages, KVM, recovery image, disk, launch script tweaks,
#                                       unique SMBIOS and VM cloaking for Apple ID; safe to re-run)
#   macos-kvm run                     - start the VM
#   macos-kvm shot [file]             - save a PNG screenshot of the VM display (default: ./screen.png)
#   macos-kvm usb attach [VID:PID]    - pass a host USB device (default: iPhone/any Apple) through to the VM
#   macos-kvm usb detach              - give it back to the host (attach also unloads ipheth/apple-mfi-fastcharge
#                                       and masks usbmuxd on the host, at runtime only; detach undoes that)
#   macos-kvm ssh [COMMAND...]       - open a shell in the VM, or run a command there and print its output
#   macos-kvm send FILE...          - copy files/dirs into the VM over scp (default ~/Desktop/)
#   macos-kvm get REMOTE [DIR]        - copy a file/dir from the VM to DIR (default: current dir)
#   macos-kvm copy [TEXT...]          - put TEXT (or stdin, or the host clipboard) into the macOS clipboard
#   macos-kvm paste                   - put the macOS clipboard into the host clipboard (stdout if piped)
#   macos-kvm smbios                  - generate a unique serial/MLB/UUID/ROM into OpenCore/config.plist and rebuild
#                                       OpenCore.qcow2 (needed for Apple ID sign-in; VM must be stopped)
#   macos-kvm cloak                   - hide the VM from macOS (kern.hv_vmm_present=0 via RestrictEvents fork) and
#                                       rebuild OpenCore.qcow2 (for Apple ID sign-in; VM must be stopped)
#   macos-kvm link                    - symlink this script to ~/.local/bin/macos-kvm (done by the full setup too)
#   macos-kvm unlink                  - remove that symlink
#   macos-kvm uninstall [--dry-run] [--yes]
#                                     - remove everything the setup installed (see uninstall.sh)
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
SSH_OPTS=(-p "$MAC_PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/known_hosts_macos-kvm")

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

# OSX-KVM ships a placeholder identity (serial W00000000001, zero UUID). Apple ID / iCloud / App Store refuse such
# a "Mac" ("Your Mac cannot be authorized by Apple's servers"), so a unique one is generated during the setup.
smbios_is_placeholder() {
    perl -0777 -ne 'exit(/<key>PlatformInfo<\/key>.*?<key>Generic<\/key>\s*<dict>.*?<key>SystemSerialNumber<\/key>\s*<string>W00000000001<\/string>/s ? 0 : 1)' "$1"
}

# Common checks for everything that edits OpenCore/config.plist and rebuilds OpenCore.qcow2 (sets OC_DIR and CFG)
oc_prepare() {
    OC_DIR="$INSTALL_DIR/OpenCore"
    CFG="$OC_DIR/config.plist"
    [ -f "$CFG" ] || die "$CFG not found - run the full setup first: macos-kvm"
    ! pgrep -f qemu-system-x86_64 >/dev/null || die "The VM is running - shut it down first (OpenCore.qcow2 gets rebuilt)"
    for t in perl curl unzip guestfish; do
        command -v "$t" >/dev/null || die "$t is required: sudo apt install perl curl unzip libguestfs-tools"
    done
}

oc_rebuild() {
    [ -z "${OC_DEFER_REBUILD:-}" ] || return 0   # the full setup rebuilds once after all tweaks
    info "Rebuilding OpenCore.qcow2 (sudo)..."
    pushd "$OC_DIR" >/dev/null
    [ ! -f OpenCore.qcow2 ] || mv -f OpenCore.qcow2 OpenCore.qcow2.bak
    sudo ./opencore-image-ng.sh --cfg config.plist --img OpenCore.qcow2 >/dev/null \
        || { [ ! -f OpenCore.qcow2.bak ] || mv -f OpenCore.qcow2.bak OpenCore.qcow2; die "OpenCore image build failed (previous image restored)"; }
    ok "OpenCore.qcow2 rebuilt (previous image: OpenCore.qcow2.bak)"
    popd >/dev/null
}

# Writes a fresh serial/MLB/UUID/ROM into OpenCore/config.plist and rebuilds OpenCore.qcow2 (the VM must be stopped)
smbios_generate() {
    oc_prepare
    # macserial (OpenCorePkg) makes serial/MLB pairs with a valid format; use $MACSERIAL, PATH, or fetch it once
    MACSERIAL="${MACSERIAL:-$(command -v macserial || true)}"
    if [ -z "$MACSERIAL" ]; then
        MACSERIAL="$INSTALL_DIR/.cache/macserial"
        if [ ! -x "$MACSERIAL" ]; then
            info "Downloading macserial from the latest OpenCorePkg release..."
            URL="$(curl -fsS https://api.github.com/repos/acidanthera/OpenCorePkg/releases/latest | grep -oE 'https://[^"]+RELEASE\.zip' | head -1)"
            [ -n "$URL" ] || die "Could not find the OpenCorePkg RELEASE.zip URL"
            TMP="$(mktemp -d)"
            curl -fsSL -o "$TMP/oc.zip" "$URL"
            unzip -q -o -j "$TMP/oc.zip" 'Utilities/macserial/macserial.linux' -d "$TMP"
            mkdir -p "$(dirname "$MACSERIAL")"
            install -m 755 "$TMP/macserial.linux" "$MACSERIAL"
            rm -rf "$TMP"
        fi
    fi
    MODEL="$(perl -0777 -ne 'print $1 if /<key>PlatformInfo<\/key>.*?<key>SystemProductName<\/key>\s*<string>([^<]+)<\/string>/s' "$CFG")"
    [ -n "$MODEL" ] || die "SystemProductName not found in $CFG"
    PAIR="$("$MACSERIAL" -m "$MODEL" -n 1 2>/dev/null | grep ' | ' | head -1 || true)"
    [ -n "$PAIR" ] || die "macserial produced no serial for $MODEL"
    export SERIAL="${PAIR%% | *}" MLB="${PAIR##* | }"
    export UUID="$(tr a-z A-Z </proc/sys/kernel/random/uuid)"
    ROM_HEX="$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    export ROM_HEX="$(printf '%02x' $(( (0x${ROM_HEX:0:2} & 0xFC) | 0x02 )))${ROM_HEX:2}"   # unicast, locally administered

    [ -f "$CFG.orig" ] || cp "$CFG" "$CFG.orig"
    # Only the PlatformInfo/Generic dict is touched (DataHub/PlatformNVRAM/SMBIOS keep their own copies)
    perl -0777 -pe '
        use MIME::Base64;
        my ($pre, $gen, $post) = /\A(.*?<key>PlatformInfo<\/key>.*?<key>Generic<\/key>\s*<dict>)(.*?)(<\/dict>.*)\z/s
            or die "PlatformInfo/Generic not found\n";
        my $rom = encode_base64(pack("H*", $ENV{ROM_HEX}), "");
        $gen =~ s{(<key>SystemSerialNumber</key>\s*<string>)[^<]*(</string>)}{$1$ENV{SERIAL}$2} or die "SystemSerialNumber missing\n";
        $gen =~ s{(<key>MLB</key>\s*<string>)[^<]*(</string>)}{$1$ENV{MLB}$2}                   or die "MLB missing\n";
        $gen =~ s{(<key>SystemUUID</key>\s*<string>)[^<]*(</string>)}{$1$ENV{UUID}$2}           or die "SystemUUID missing\n";
        $gen =~ s{(<key>ROM</key>\s*<data>)[^<]*(</data>)}{$1$rom$2}                            or die "ROM missing\n";
        $_ = $pre . $gen . $post;
    ' "$CFG" >"$CFG.new" || { rm -f "$CFG.new"; die "Failed to patch $CFG (original untouched)"; }
    mv "$CFG.new" "$CFG"
    ok "config.plist: $MODEL serial=$SERIAL MLB=$MLB UUID=$UUID ROM=$ROM_HEX (original kept as config.plist.orig)"

    oc_rebuild
}

# Hides the VM from macOS. Apple ID sign-in on Sequoia/Tahoe needs kern.hv_vmm_present=0, and hiding the CPUID
# hypervisor bit in QEMU makes Tahoe unbootable. Instead: Lilu + DrDonk's RestrictEvents fork (OC4VM project)
# with revpatch=...,novmm in boot-args. Undo: restore OpenCore.qcow2.bak and config.plist.pre-cloak.
cloak_install() {
    oc_prepare
    local KEXTS="$OC_DIR/EFI/OC/Kexts" BACKUP="$OC_DIR/EFI/OC/.backup" TMP
    local BASE_URL="https://raw.githubusercontent.com/DrDonk/OC4VM/master/software"
    [ -d "$KEXTS" ] || die "$KEXTS not found - run the full setup first: macos-kvm"
    TMP="$(mktemp -d)"
    info "Downloading Lilu 1.7.2 and the RestrictEvents fork 1.1.7 (OC4VM)..."
    curl -fsSL -o "$TMP/lilu.zip" "$BASE_URL/acidanthera/Lilu-1.7.2-RELEASE.zip"
    curl -fsSL -o "$TMP/re.zip" "$BASE_URL/DrDonk/RestrictEvents-1.1.7-RELEASE.zip"
    unzip -q -o "$TMP/lilu.zip" 'Lilu.kext/*' -d "$TMP"
    unzip -q -o "$TMP/re.zip" 'RestrictEvents.kext/*' -d "$TMP"
    mkdir -p "$BACKUP"
    [ ! -d "$KEXTS/Lilu.kext" ] || [ -d "$BACKUP/Lilu.kext" ] || cp -a "$KEXTS/Lilu.kext" "$BACKUP/"
    rm -rf "$KEXTS/Lilu.kext" "$KEXTS/RestrictEvents.kext"
    cp -a "$TMP/Lilu.kext" "$TMP/RestrictEvents.kext" "$KEXTS/"
    rm -rf "$TMP"

    cp "$CFG" "$CFG.pre-cloak"
    perl -0777 -pe '
        # kext entry right after Lilu.kext (Lilu has to load first)
        unless (m{<string>RestrictEvents\.kext</string>}) {
            my @f = (["Arch", "<string>x86_64</string>"], ["BundlePath", "<string>RestrictEvents.kext</string>"],
                     ["Comment", "<string>RestrictEvents fork (kern.hv_vmm_present)</string>"], ["Enabled", "<true/>"],
                     ["ExecutablePath", "<string>Contents/MacOS/RestrictEvents</string>"], ["MaxKernel", "<string></string>"],
                     ["MinKernel", "<string>20.3.0</string>"], ["PlistPath", "<string>Contents/Info.plist</string>"]);
            my $entry = "\t\t\t<dict>\n" . join("", map { "\t\t\t\t<key>$_->[0]</key>\n\t\t\t\t$_->[1]\n" } @f) . "\t\t\t</dict>\n";
            s{(<key>BundlePath</key>\s*<string>Lilu\.kext</string>.*?</dict>\n)}{$1$entry}s or die "Lilu.kext entry not found\n";
        }
        # boot-args (rewritten at every boot: it is in NVRAM/Delete)
        s{(<key>boot-args</key>\s*<string>)([^<]*)(</string>)}{my ($a, $b, $c) = ($1, $2, $3); $b =~ s/\s*revpatch=\S*//g; "$a$b revpatch=sbvmm,asset,novmm$c"}e
            or die "boot-args not found\n";
    ' "$CFG" >"$CFG.new" || { rm -f "$CFG.new"; die "Failed to patch $CFG (original untouched)"; }
    mv "$CFG.new" "$CFG"
    ok "config.plist: RestrictEvents.kext added, boot-args get revpatch=sbvmm,asset,novmm (previous: config.plist.pre-cloak)"
    oc_rebuild
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
        USB_BUS="${USB_BUS:-ehci.0}"     # guest USB controller (id=ehci in OpenCore-Boot.sh); an iPhone is not seen by macOS behind xhci.0
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
        exec ssh "${SSH_OPTS[@]}" "$MAC_USER@localhost" "$@" ;;
    copy)
        # host -> macOS clipboard: TEXT args, else stdin if piped, else the host clipboard
        shift
        command -v ssh >/dev/null || die "ssh is required: sudo apt install openssh-client"
        if [ "$#" -gt 0 ]; then
            printf '%s' "$*"
        elif [ ! -t 0 ]; then
            cat
        elif [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null; then
            wl-paste --no-newline
        elif command -v xclip >/dev/null; then
            xclip -selection clipboard -o
        else
            die "Nothing to copy: pass TEXT, pipe stdin, or install wl-clipboard/xclip to use the host clipboard"
        fi | ssh "${SSH_OPTS[@]}" "$MAC_USER@localhost" 'LANG=en_US.UTF-8 pbcopy'
        ok "Copied to the macOS clipboard"
        exit 0 ;;
    paste)
        # macOS clipboard -> host clipboard (printed to stdout instead when stdout is piped)
        command -v ssh >/dev/null || die "ssh is required: sudo apt install openssh-client"
        if [ ! -t 1 ]; then
            exec ssh "${SSH_OPTS[@]}" "$MAC_USER@localhost" 'LANG=en_US.UTF-8 pbpaste'
        fi
        TEXT="$(ssh "${SSH_OPTS[@]}" "$MAC_USER@localhost" 'LANG=en_US.UTF-8 pbpaste')"
        if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null; then
            printf '%s' "$TEXT" | wl-copy
        elif command -v xclip >/dev/null; then
            printf '%s' "$TEXT" | xclip -selection clipboard
        else
            die "Install wl-clipboard (Wayland) or xclip (X11) to fill the host clipboard"
        fi
        ok "macOS clipboard copied to the host (${#TEXT} chars)"
        exit 0 ;;
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
    smbios)
        smbios_generate
        echo "Start the VM, then check:  macos-kvm ssh 'system_profiler SPHardwareDataType | grep -i -E \"serial|uuid\"'"
        echo "Then sign in: System Settings -> Apple Account. Optional: confirm the serial is unused at https://checkcoverage.apple.com (\"not valid\" is what you want)."
        exit 0 ;;
    cloak)
        cloak_install
        echo "Start the VM and check:  macos-kvm ssh 'sysctl kern.hv_vmm_present'   (expected: 0), then sign in to Apple Account."
        echo "If macOS does not boot: in $INSTALL_DIR/OpenCore restore  OpenCore.qcow2.bak  and  config.plist.pre-cloak  (mv/cp over the current files)."
        exit 0 ;;
    uninstall)
        shift
        exec bash "$(dirname "$SELF")/uninstall.sh" "$@" ;;
    "")
        ;;  # no argument: full setup below
    *)
        die "Unknown command '$1'. Use: run | shot [file] | usb attach|detach | ssh [cmd] | send FILE... | get REMOTE [DIR] | copy [TEXT] | paste | smbios | cloak | link | unlink | uninstall (no argument = full setup)" ;;
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
sudo apt-get install -y qemu-system-x86 qemu-utils ovmf dmg2img git wget socat python3 perl curl unzip libguestfs-tools
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

# EHCI controller for "usb attach": an iPhone is not seen by macOS behind the xhci controller
grep -qE '^\s*-device usb-ehci,id=ehci' "$F" || sed -i -E 's|^(\s*)-device qemu-xhci,id=xhci|&\n\1-device usb-ehci,id=ehci|' "$F"
grep -qE '^\s*-device usb-ehci,id=ehci' "$F" || die "Could not add the usb-ehci controller to $F - add '-device usb-ehci,id=ehci' by hand"

chmod +x "$F"
ok "$F configured: ${RAM} MiB, ${CORES} cores (original saved as $F.orig)"

# -----------------------------------------------------------------------------
# 6b. OpenCore tweaks for Apple ID / iCloud / iMazing: unique SMBIOS (serial/MLB/UUID/ROM) and VM cloaking
#     (kern.hv_vmm_present=0). Each is skipped once done; OpenCore.qcow2 is rebuilt once at the end if needed.
# -----------------------------------------------------------------------------
OC_CHANGED=""
if smbios_is_placeholder "$INSTALL_DIR/OpenCore/config.plist"; then
    info "OpenCore still has the placeholder SMBIOS - generating a unique one..."
    OC_DEFER_REBUILD=1 smbios_generate
    OC_CHANGED=1
else
    ok "SMBIOS already unique (macos-kvm smbios generates a new one)"
fi
if grep -q 'RestrictEvents\.kext' "$INSTALL_DIR/OpenCore/config.plist"; then
    ok "VM cloaking already configured"
else
    info "Adding VM cloaking (RestrictEvents fork)..."
    OC_DEFER_REBUILD=1 cloak_install
    OC_CHANGED=1
fi
[ -z "$OC_CHANGED" ] || oc_rebuild

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
echo "After the install: enable System Settings -> General -> Sharing -> Remote Login, then sign in to Apple Account."
echo "Screenshot of the VM display:  macos-kvm shot"
echo "iPhone into the VM (after macOS booted):  macos-kvm usb attach   /   usb detach"
echo "Clipboard and files:  macos-kvm copy | paste | send | get   (ssh shortcut: macos-kvm ssh)"
echo "Remove everything this project installed:  macos-kvm uninstall   (--dry-run to preview)"
