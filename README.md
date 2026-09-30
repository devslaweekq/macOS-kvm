# macos-kvm

One-command setup for running **macOS Tahoe (26)** in a virtual machine on Linux with **QEMU/KVM**, built on top of
[OSX-KVM](https://github.com/kholia/OSX-KVM).

The script installs the required packages, prepares KVM, downloads the macOS recovery image straight from Apple, creates a system disk and
tunes the OSX-KVM launch script for Tahoe. It is written and tested for Ubuntu; other Debian-based distributions should work as well.

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
| Disk           | 50 GiB or more free (the qcow2 image grows on write)       |
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

The setup creates a symlink `~/.local/bin/macos-kvm` pointing to the script, so `run` and `shot` work from any directory. If `~/.local/bin`
is not in your `PATH`, the script prints the line to add to `~/.bashrc`.

If the script adds you to the `kvm` group, log out and back in (or run `newgrp kvm`) before starting the VM.

## Installing macOS

In the QEMU window:

1. In the OpenCore menu, pick **macOS Base System (External)**.
2. In **Disk Utility**, select the large `QEMU HARDDISK`, click **Erase**, and choose **APFS** with the **GUID** partition scheme.
3. Close Disk Utility, choose **Reinstall macOS**, and select the disk you just erased.
4. The installation downloads macOS from Apple and reboots several times. After each reboot, pick **macOS Installer** in the OpenCore menu,
   and once it appears, **macOS**.

## Commands

| Command                 | Description                                                                                     |
| ----------------------- | ----------------------------------------------------------------------------------------------- |
| `bash macos-kvm.sh`     | Full setup: KVM, packages, OSX-KVM, recovery image, disk, launch script tweaks, command symlink |
| `macos-kvm run`         | Start the VM (`OpenCore-Boot.sh`)                                                               |
| `macos-kvm shot [file]` | Save a PNG screenshot of the VM display (default `./screen.png` in the current directory)       |
| `macos-kvm link`        | Create the `~/.local/bin/macos-kvm` symlink (done automatically by the full setup)              |
| `macos-kvm unlink`      | Remove the symlink                                                                              |

`run`, `shot`, `link` and `unlink` work from any directory once the symlink exists. Before that, call the script by path:
`bash /path/to/macos-kvm.sh run`. Unknown commands are rejected instead of falling back to the full setup.

The setup is idempotent: an existing `BaseSystem.img` and `mac_hdd_ng.img` are kept, and the original launch script is saved once as
`OpenCore-Boot.sh.orig`.

## Configuration

Set these environment variables when running the script:

| Variable      | Default              | Description                                                                                                        |
| ------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `RAM`         | `16384`              | Guest memory in MiB                                                                                                |
| `CORES`       | `8`                  | Guest CPU cores (one thread per core)                                                                              |
| `DISK_SIZE`   | `50G`                | Size of the system disk (qcow2)                                                                                    |
| `OS`          | `tahoe`              | macOS release: `high-sierra`, `mojave`, `catalina`, `big-sur`, `monterey`, `ventura`, `sonoma`, `sequoia`, `tahoe` |
| `INSTALL_DIR` | `$HOME/OSX-KVM`      | Where OSX-KVM is cloned                                                                                            |
| `QMP`         | `/tmp/qemu-qmp.sock` | QMP socket used by the `shot` command                                                                              |

Example:

```bash
RAM=8192 CORES=4 DISK_SIZE=80G bash macos-kvm.sh
```

## What the setup does

1. Verifies CPU virtualization support and that `/dev/kvm` is available.
2. Sets the KVM parameter `ignore_msrs=1` immediately and persistently (`/etc/modprobe.d/kvm.conf`); macOS crashes without it.
3. Installs `qemu-system-x86`, `qemu-utils`, `ovmf`, `dmg2img`, `git`, `wget`, `socat` and `python3`, and adds your user to the `kvm` group.
4. Clones OSX-KVM to `$INSTALL_DIR`.
5. Downloads the recovery image with `fetch-macOS-v2.py --shortname <OS>` and converts it to `BaseSystem.img`.
6. Creates the `mac_hdd_ng.img` system disk.
7. Edits `OpenCore-Boot.sh`: RAM and CPU settings, enables the `Skylake-Client` CPU model required for Sequoia and Tahoe, and adds a QMP
   socket for screenshots.
8. Creates the `~/.local/bin/macos-kvm` symlink so the commands work from any directory.

## Troubleshooting

- **Crash right after the Apple logo.** Make sure `cat /sys/module/kvm/parameters/ignore_msrs` prints `Y` and that your CPU supports AVX2
  (`grep -c avx2 /proc/cpuinfo`).
- **`Permission denied` on `/dev/kvm`.** Log out and back in after being added to the `kvm` group, or run `newgrp kvm`.
- **`shot` reports a missing socket.** The VM must be running and started through this script's tweaked `OpenCore-Boot.sh` (the `-qmp`
  option); re-run `bash macos-kvm.sh` if it was not applied.
- **Keyboard and mouse do not work.** The launch script attaches a USB keyboard and tablet on an xHCI controller; do not remove those lines.
- **Debugging the boot.** Add `-v` to the guest boot arguments through OpenCore, or watch the terminal that started QEMU.

## Why not VirtualBox?

macOS 26 does not run reliably under VirtualBox: the guest did not detect the emulated USB or PS/2 input devices, so the installer could not
be operated. QEMU/KVM with OpenCore provides working USB input and CPU features that macOS expects.

## Repository layout

| Path                 | Purpose                                                                                            |
| -------------------- | -------------------------------------------------------------------------------------------------- |
| `macos-kvm.sh`       | Setup, run and screenshot script                                                                   |
| `recoveryOS-1.0.3/`  | Third-party recovery image maker (OC4VM) with its own README; optional, not used by `macos-kvm.sh` |
| `.github/CODEOWNERS` | Code ownership                                                                                     |
| `LICENSE`            | MIT license                                                                                        |

## Credits

- [OSX-KVM](https://github.com/kholia/OSX-KVM) by Dhiru Kholia and contributors
- [OpenCore](https://github.com/acidanthera/OpenCorePkg) by Acidanthera

## License

MIT. See [LICENSE](LICENSE).
