# macos-kvm

One-command setup for running **macOS Tahoe (26)** in a virtual machine on Linux with **QEMU/KVM**, built on top of
[OSX-KVM](https://github.com/kholia/OSX-KVM).

The script installs the required packages, prepares KVM, downloads the macOS recovery image straight from Apple, creates a system disk,
tunes the OSX-KVM launch script for Tahoe and prepares OpenCore so that Apple ID sign-in works (unique SMBIOS, VM cloaking). Day-to-day
helpers cover iPhone USB passthrough, shell and file access to the guest, clipboard sharing and a full uninstall. It is written and
tested for Ubuntu; other Debian-based distributions should work as well.

> **Legal notice.** Apple's license only permits running macOS on Apple-branded hardware. This project is provided for educational and
> research purposes. You are responsible for complying with Apple's license terms.

## Requirements

| Item           | Requirement                                                |
| -------------- | ---------------------------------------------------------- |
| Host OS        | Ubuntu (or another Debian-based distribution)              |
| CPU            | Intel VT-x or AMD-V, with **AVX2** support                 |
| Virtualization | Enabled in BIOS/UEFI; `/dev/kvm` must exist                |
| QEMU           | 8.2 or newer (installed by the script)                     |
| RAM            | 8 GiB or more free for the guest is recommended            |
| Disk           | 60 GiB or more free (the qcow2 image grows on write)       |
| Network        | Internet access (recovery download and macOS installation) |
| Privileges     | `sudo` (package installation and KVM settings)             |

Check virtualization support before you start:

```bash
lscpu | grep -i virtualization
ls -l /dev/kvm
grep -c -E '(vmx|svm)' /proc/cpuinfo
```

## Quick start

```bash
git clone <this repository>
cd macos-kvm
bash macos-kvm.sh        # one-time setup (also installs the `macos-kvm` command)
macos-kvm run            # start the VM, from any directory
```

The setup creates a symlink `~/.local/bin/macos-kvm` pointing to the script, so every command works from any directory. If
`~/.local/bin` is not in your `PATH`, the script prints the line to add to `~/.bashrc`.

If the script adds you to the `kvm` group, log out and back in (or run `newgrp kvm`) before starting the VM.

## Installing macOS

In the QEMU window:

1. In the OpenCore menu, pick **macOS Base System (External)**.
2. In **Disk Utility**, select the large `QEMU HARDDISK`, click **Erase**, and choose **APFS** with the **GUID** partition scheme.
3. Close Disk Utility, choose **Reinstall macOS**, and select the disk you just erased.
4. The installation downloads macOS from Apple and reboots several times. After each reboot, pick **macOS Installer** in the OpenCore menu,
   and once it appears, **macOS**.

After the installation, in macOS:

- enable **System Settings → General → Sharing → Remote Login** (needed by `ssh`, `send`, `get`, `copy` and `paste`);
- sign in to **System Settings → Apple Account** (the setup already prepared SMBIOS and VM cloaking for this, see below).

## Commands

Everything except the setup works from any directory once the symlink exists. Before that, call the script by path:
`bash /path/to/macos-kvm.sh <command>`. Unknown commands are rejected instead of falling back to the full setup.

| Command                                | Description                                                                                                                    |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `bash macos-kvm.sh`                    | Full setup (see "What the setup does"); idempotent, safe to re-run                                                             |
| `macos-kvm run`                        | Start the VM (`OpenCore-Boot.sh`)                                                                                              |
| `macos-kvm shot [file]`                | Save a PNG screenshot of the VM display (default `./screen.png`); needs the VM running                                         |
| `macos-kvm usb attach [VID:PID]`       | Pass a host USB device through to the running VM (default: the first Apple device, i.e. an iPhone)                             |
| `macos-kvm usb detach`                 | Give the device back to the host                                                                                               |
| `macos-kvm ssh [COMMAND...]`           | Open a shell in the VM, or run a command there and print its output                                                            |
| `macos-kvm send FILE...`               | Copy files/directories into the VM over scp (default destination `~/Desktop/`)                                                 |
| `macos-kvm get REMOTE [DIR]`           | Copy a file/directory from the VM to `DIR` (default: current directory)                                                        |
| `macos-kvm copy [TEXT...]`             | Put `TEXT` (or stdin, or the host clipboard) into the macOS clipboard                                                          |
| `macos-kvm paste`                      | Put the macOS clipboard into the host clipboard (printed to stdout when piped)                                                 |
| `macos-kvm smbios`                     | Generate a new unique serial/MLB/UUID/ROM into `OpenCore/config.plist` and rebuild `OpenCore.qcow2` (VM must be stopped)       |
| `macos-kvm cloak`                      | Hide the VM from macOS (`kern.hv_vmm_present=0`) and rebuild `OpenCore.qcow2` (VM must be stopped)                             |
| `macos-kvm link` / `macos-kvm unlink`  | Create / remove the `~/.local/bin/macos-kvm` symlink (the setup creates it automatically)                                      |
| `macos-kvm uninstall [-n] [-y]`        | Remove everything the setup installed (see "Uninstall"); `-n`/`--dry-run` only prints, `-y`/`--yes` answers yes to all questions |

`ssh`, `send`, `get`, `copy` and `paste` talk to the guest through the forwarded port `2222` (`hostfwd` in `OpenCore-Boot.sh`) with the
account named like your host user; override it with `MAC_USER`. They ask for the macOS password each time unless you install a key:
`ssh-copy-id -p 2222 <user>@localhost`. `copy`/`paste` use `pbcopy`/`pbpaste` in the guest and `wl-copy`/`wl-paste` (Wayland) or `xclip`
(X11) on the host. The QEMU window itself has no shared clipboard: macOS has no SPICE agent.

## Configuration

Set these environment variables when running the script:

| Variable      | Default                | Description                                                                                                        |
| ------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `RAM`         | `8192`                 | Guest memory in MiB                                                                                                |
| `CORES`       | `6`                    | Guest CPU cores (one thread per core)                                                                              |
| `DISK_SIZE`   | `60G`                  | Size of the system disk (qcow2)                                                                                    |
| `OS`          | `tahoe`                | macOS release: `high-sierra`, `mojave`, `catalina`, `big-sur`, `monterey`, `ventura`, `sonoma`, `sequoia`, `tahoe` |
| `INSTALL_DIR` | `$HOME/OSX-KVM`        | Where OSX-KVM is cloned                                                                                            |
| `QMP`         | `/tmp/qemu-qmp.sock`   | QMP socket used by `shot` and `usb`                                                                                |
| `LINK_DIR`    | `$HOME/.local/bin`     | Where the `macos-kvm` symlink is created                                                                           |
| `MAC_USER`    | your host user name    | macOS account used by `ssh`, `send`, `get`, `copy`, `paste`                                                        |
| `MAC_PORT`    | `2222`                 | Host port forwarded to the guest's SSH                                                                             |
| `MAC_DEST`    | `~/Desktop/`           | Destination folder of `send` inside macOS                                                                          |
| `USB_BUS`     | `ehci.0`               | Guest USB controller used by `usb attach`                                                                          |
| `USB_ID`      | `usbdev`               | QEMU device id used by `usb attach` / `usb detach`                                                                 |
| `MACSERIAL`   | auto                   | Path to `macserial`; by default taken from `PATH` or downloaded once into `$INSTALL_DIR/.cache`                    |

Example:

```bash
RAM=16384 CORES=8 DISK_SIZE=80G bash macos-kvm.sh
```

## What the setup does

1. Verifies CPU virtualization support and that `/dev/kvm` is available.
2. Sets the KVM parameter `ignore_msrs=1` immediately and persistently (`/etc/modprobe.d/kvm.conf`); macOS crashes without it.
3. Installs `qemu-system-x86`, `qemu-utils`, `ovmf`, `dmg2img`, `git`, `wget`, `socat`, `python3`, `perl`, `curl`, `unzip` and
   `libguestfs-tools`, and adds your user to the `kvm` group.
4. Clones OSX-KVM to `$INSTALL_DIR`.
5. Downloads the recovery image with `fetch-macOS-v2.py --shortname <OS>` and converts it to `BaseSystem.img`.
6. Creates the `mac_hdd_ng.img` system disk.
7. Edits `OpenCore-Boot.sh` (the original is saved once as `OpenCore-Boot.sh.orig`): RAM and CPU settings, the `Skylake-Client` CPU model
   required for Sequoia and Tahoe, a QMP socket for `shot`/`usb`, and an EHCI USB controller for `usb attach`.
8. Prepares OpenCore for Apple services and rebuilds `OpenCore.qcow2` once if anything changed (see the next section).
9. Creates the `~/.local/bin/macos-kvm` symlink.

An existing `BaseSystem.img` and `mac_hdd_ng.img` are kept, and steps already done are skipped.

### Apple ID support: unique SMBIOS and VM cloaking

Apple ID, iCloud and App Store sign-in fail in a stock OSX-KVM guest ("Your Mac cannot be authorized by Apple's servers",
"An unknown error occurred"). Two things are fixed in `OpenCore/config.plist`:

- **Unique SMBIOS.** OSX-KVM ships a placeholder identity (serial `W00000000001`, zero UUID). The setup generates a valid serial/MLB pair
  with `macserial` (from [OpenCorePkg](https://github.com/acidanthera/OpenCorePkg)), a random UUID and a locally administered ROM, and
  writes them to `PlatformInfo → Generic`. The original file is kept as `config.plist.orig`. It runs only while the placeholder is present,
  so re-running the setup does not change the identity; `macos-kvm smbios` forces a new one.
- **VM cloaking.** Sequoia and Tahoe check `sysctl kern.hv_vmm_present` and refuse to authorize a virtual machine. The setup installs
  Lilu 1.7.2 and the RestrictEvents fork 1.1.7 from the [OC4VM](https://github.com/DrDonk/OC4VM) project and adds
  `revpatch=sbvmm,asset,novmm` to `boot-args`, which forces the value to `0`. Check it in the guest:
  `macos-kvm ssh 'sysctl kern.hv_vmm_present'` (expected `0`). The previous files are kept as `config.plist.pre-cloak` and
  `OpenCore.qcow2.bak`. Hiding the CPUID hypervisor bit instead (`-cpu ...,-hypervisor`) makes Tahoe fail to boot; do not use it.

Both commands download third-party binaries (`macserial`, Lilu, RestrictEvents fork) at setup time. Tested with macOS 26.7.1.

## iPhone and other USB devices

Attach a host USB device to the running VM, after macOS has booted:

```bash
macos-kvm usb attach        # first Apple device (iPhone); or: macos-kvm usb attach 05ac:12a8
macos-kvm usb detach        # give it back to the host
```

Notes:

- `attach` frees the device on the host first: it blacklists `ipheth`/`apple-mfi-fastcharge` and masks `usbmuxd` **at runtime only**
  (`/run`, undone by `detach` or a reboot). The phone has to be unlocked and trusted ("Trust This Computer" appears in macOS once a client
  such as Finder asks).
- The device is passed through an **EHCI** controller (`ehci.0`). Behind the default xHCI controller macOS did not complete pairing.
- Do not put a hard-coded `-device usb-host,...` for the phone into `OpenCore-Boot.sh`: QEMU would grab the device before the host drivers
  are released and the phone keeps re-enumerating. Use `usb attach` instead.
- After `usb detach`, `usbmuxd` on the host may need a restart before `idevice_id`/`pymobiledevice3` see the phone again:
  `sudo systemctl kill -s SIGKILL usbmuxd; sudo systemctl start usbmuxd`.

## Uninstall

```bash
macos-kvm uninstall --dry-run     # preview
macos-kvm uninstall               # asks before the destructive steps
```

(or `bash uninstall.sh` from the repository). It removes:

| What                                                                 | Asked first?                                   |
| -------------------------------------------------------------------- | ---------------------------------------------- |
| Runtime USB leftovers (driver blacklist, `usbmuxd` mask), QMP socket | no                                             |
| `~/.local/bin/macos-kvm` symlink, `~/.ssh/known_hosts_macos-kvm`     | no                                             |
| `/etc/modprobe.d/kvm.conf` written by the setup (`ignore_msrs`)     | no (only if the content is exactly ours)       |
| `$INSTALL_DIR` (OSX-KVM, images, OpenCore, **the macOS system disk**) | **yes** (default No)                           |
| `kvm` group membership                                               | **yes** (default No)                           |
| QEMU packages (`qemu-system-x86`, `qemu-utils`)                      | **yes** (default No; `apt` shows its own list) |
| Helper packages (`dmg2img`, `libguestfs-tools`, `ovmf`, `socat`)     | **yes** (default No)                           |

`git`, `wget`, `curl`, `unzip`, `perl` and `python3` are never removed, and neither is this repository. The VM must be shut down first.
`--yes` answers "yes" to every question, including deleting the macOS disk.

## Troubleshooting

- **Crash right after the Apple logo.** Make sure `cat /sys/module/kvm/parameters/ignore_msrs` prints `Y` and that your CPU supports AVX2
  (`grep -c avx2 /proc/cpuinfo`).
- **`Permission denied` on `/dev/kvm`.** Log out and back in after being added to the `kvm` group, or run `newgrp kvm`.
- **`shot`/`usb` report a missing socket.** The VM must be running and started through this script's tweaked `OpenCore-Boot.sh` (the `-qmp`
  option); re-run `bash macos-kvm.sh` if it was not applied.
- **Keyboard and mouse do not work.** The launch script attaches a USB keyboard and tablet on an xHCI controller; do not remove those lines.
- **Apple ID: "Your Mac cannot be authorized" / "unknown error".** Check `macos-kvm ssh 'system_profiler SPHardwareDataType | grep -i serial'`
  (must not be `W00000000001`) and `sysctl kern.hv_vmm_present` (must be `0`). If not, stop the VM and run `macos-kvm smbios` /
  `macos-kvm cloak`. The log shows the cause:
  `macos-kvm ssh "/usr/bin/log show --last 3m --info --predicate 'process == \"akd\"' | grep -i -E 'error|anisette|attestation'"`.
- **macOS does not boot after `cloak`.** In `$INSTALL_DIR/OpenCore` restore `OpenCore.qcow2.bak` over `OpenCore.qcow2` and
  `config.plist.pre-cloak` over `config.plist`.
- **iPhone is not visible in macOS or keeps reconnecting.** Use `usb attach` (not a fixed `usb-host` line in `OpenCore-Boot.sh`), keep the
  phone unlocked, try another cable/port, and watch the host with `sudo dmesg -w | grep 'usb 3-'` (a growing device number means it
  re-enumerates).
- **`ssh`/`send`/`copy` fail.** Enable Remote Login in macOS and check that the account name matches `MAC_USER`.
- **Debugging the boot.** Add `-v` to the guest boot arguments through OpenCore, or watch the terminal that started QEMU.

## Why not VirtualBox?

macOS 26 does not run reliably under VirtualBox: the guest did not detect the emulated USB or PS/2 input devices, so the installer could not
be operated. QEMU/KVM with OpenCore provides working USB input and CPU features that macOS expects.

## Repository layout

| Path                 | Purpose                                                                                |
| -------------------- | -------------------------------------------------------------------------------------- |
| `macos-kvm.sh`       | Setup and all commands (run, shot, usb, ssh, send, get, copy, paste, smbios, cloak, link) |
| `uninstall.sh`       | Removes everything the setup installed (also available as `macos-kvm uninstall`)       |
| `.github/CODEOWNERS` | Code ownership                                                                         |
| `LICENSE`            | MIT license                                                                            |

## Credits

- [OSX-KVM](https://github.com/kholia/OSX-KVM) by Dhiru Kholia and contributors
- [OpenCore](https://github.com/acidanthera/OpenCorePkg) by Acidanthera (`macserial`, Lilu)
- [OC4VM](https://github.com/DrDonk/OC4VM) by David Parsons (RestrictEvents fork with `novmm`)

## License

MIT. See [LICENSE](LICENSE).
