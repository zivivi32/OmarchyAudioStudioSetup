#!/usr/bin/env bash
#
# ni-install-libraries.sh — auto-mount and install NI library ISOs
#
# Native Access downloads plugin/library installers as .iso files and then
# fails to mount them under Wine, leaving you to mount and install manually.
# This script does that step for you: it scans a Downloads folder for .iso
# files, mounts each one with udisksctl (no root/sudo needed), exposes the
# mount to Wine as a real CD-ROM drive, runs the Windows installer inside it
# with your EXISTING Wine prefix, then cleans everything up. Already-installed
# ISOs are skipped on future runs.
#
# The CD-ROM part matters: NI/InstallAware installers call GetDriveType() on
# their own location and refuse to continue with "Please insert CD/ISO/Media"
# if it comes back DRIVE_FIXED. A plain unix path (or a bare loop mount) is
# always DRIVE_FIXED. So for each ISO we pick a free drive letter and set up
# the three things Wine needs to report DRIVE_CDROM instead:
#
#   $WINEPREFIX/dosdevices/<x>:   -> the mount point   (the filesystem)
#   $WINEPREFIX/dosdevices/<x>::  -> the loop device   (raw device, for the
#                                    volume label + serial the installer reads)
#   HKLM\Software\Wine\Drives\<x>: = "cdrom"           (the type itself)
#
# ...and then launch the installer through the DOS path (X:\setup.exe), not
# the unix mount path, so the installer's own module path lands on that drive.
#
# It does NOT create a new Wine prefix or touch your yabridge setup — it
# just installs into whatever WINEPREFIX you already use.
#
# Usage:
#   ./ni-install-libraries.sh [downloads_dir]
#
# Env vars:
#   WINEPREFIX   - your existing Wine prefix (default: ~/.wine)
#   WINE         - wine binary to use (default: wine)

set -euo pipefail

DOWNLOADS_DIR="${1:-$HOME/Downloads}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
WINE="${WINE:-wine}"
STATE_DIR="$HOME/.local/state/ni-install-libraries"
DONE_LIST="$STATE_DIR/installed.list"
DOSDEVICES="$WINEPREFIX/dosdevices"

export WINEPREFIX

mkdir -p "$STATE_DIR"
touch "$DONE_LIST"

if ! command -v udisksctl >/dev/null 2>&1; then
    echo "error: udisksctl not found. Install it with: sudo pacman -S udisks2" >&2
    exit 1
fi

if ! command -v "$WINE" >/dev/null 2>&1; then
    echo "error: '$WINE' not found. Install it with: sudo pacman -S wine" >&2
    exit 1
fi

if [ ! -d "$DOSDEVICES" ]; then
    echo "error: no Wine prefix at $WINEPREFIX (missing $DOSDEVICES)" >&2
    echo "Set WINEPREFIX to the prefix you already use, e.g.:" >&2
    echo "  WINEPREFIX=\"\$HOME/.wine\" $0" >&2
    exit 1
fi

if [ ! -d "$DOWNLOADS_DIR" ]; then
    echo "error: downloads dir not found: $DOWNLOADS_DIR" >&2
    echo "Pass the right path as an argument, e.g.:" >&2
    echo "  $0 ~/Downloads" >&2
    exit 1
fi

# ---------------------------------------------------------------- helpers --

# Per-ISO teardown state. Set as we go, consumed by cleanup().
loop_dev=""
mount_point=""
mount_out=""
drive_letter=""

# Find a drive letter with no dosdevices entry of either form. c: is drive_c
# and z: is /, so start at d: and leave anything already claimed alone.
pick_drive_letter() {
    local letter
    for letter in {d..y}; do
        if [ ! -e "$DOSDEVICES/$letter:" ] && [ ! -L "$DOSDEVICES/$letter:" ] \
        && [ ! -e "$DOSDEVICES/$letter::" ] && [ ! -L "$DOSDEVICES/$letter::" ]; then
            printf '%s' "$letter"
            return 0
        fi
    done
    return 1
}

# Did we actually get the mount we asked for? udisks records the options it
# used, so this distinguishes our mount from an automount that beat us to it.
mount_has_unhide() {
    findmnt -n -o OPTIONS --source "$loop_dev" 2>/dev/null \
        | head -n1 | grep -q '\bunhide\b'
}

cleanup() {
    # Order matters. Wine's mount manager rescans the system mount table on
    # every wine invocation and re-creates dosdevices device links for whatever
    # it finds, so the media has to be gone *before* we run `wine reg delete`
    # — otherwise that very command puts the "<x>::" link straight back as a
    # dangling symlink that blocks the letter on the next run.
    if [ -n "$loop_dev" ]; then
        # Unmount unconditionally: udisks may have automounted the device
        # behind our back, and loop-delete fails while anything is mounted.
        udisksctl unmount -b "$loop_dev" --no-user-interaction >/dev/null 2>&1 || true
        udisksctl loop-delete -b "$loop_dev" --no-user-interaction >/dev/null 2>&1 || true
        loop_dev=""
    fi
    mount_point=""

    if [ -n "$drive_letter" ]; then
        rm -f "$DOSDEVICES/$drive_letter:" "$DOSDEVICES/$drive_letter::"
        "$WINE" reg delete 'HKLM\Software\Wine\Drives' \
            /v "$drive_letter:" /f >/dev/null 2>&1 || true
        # ...and once more, in case that wine run still managed to re-add them.
        rm -f "$DOSDEVICES/$drive_letter:" "$DOSDEVICES/$drive_letter::"
        drive_letter=""
    fi
}

# Ctrl-C / kill mid-install still tears down the drive letter and the mount.
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

# ------------------------------------------------------------------- main --

shopt -s nullglob nocaseglob
isos=("$DOWNLOADS_DIR"/*.iso)
shopt -u nullglob nocaseglob

if [ ${#isos[@]} -eq 0 ]; then
    echo "No .iso files found in $DOWNLOADS_DIR"
    exit 0
fi

failed=0

for iso in "${isos[@]}"; do
    iso_name="$(basename "$iso")"

    if grep -qxF "$iso_name" "$DONE_LIST"; then
        echo "== Skipping already-installed: $iso_name =="
        continue
    fi

    echo "== Mounting: $iso_name =="

    loop_dev="$(udisksctl loop-setup -f "$iso" --no-user-interaction \
        | sed -n 's/.*as \(\/dev\/loop[0-9]*\)\.$/\1/p')"

    if [ -z "$loop_dev" ]; then
        echo "error: could not set up loop device for $iso_name" >&2
        failed=1
        continue
    fi

    # udisks sometimes needs a moment before the new device is probed/mountable.
    udevadm settle >/dev/null 2>&1 || true

    # "unhide" is the whole ballgame. NI/Cinesamples ship the actual library
    # payload as files flagged HIDDEN in the UDF filesystem — on this ISO the
    # two visible files total 5.7MB while the two hidden .pkg payloads are
    # 770MB. Linux's udf/iso9660 drivers omit hidden files from readdir by
    # default, so the installer enumerates the disc, finds no payload, and asks
    # you to insert the media. Mounting with unhide is what actually fixes the
    # prompt; the CD-ROM drive mapping below is necessary but not sufficient.
    #
    # The desktop's udisks automount races us for the device and mounts it
    # WITHOUT unhide, after which our own mount fails with AlreadyMounted. So
    # unmount whatever is there and retry until the mount we get is ours.
    mount_point=""
    mount_out=""
    for attempt in 1 2 3 4 5; do
        if findmnt -n --source "$loop_dev" >/dev/null 2>&1; then
            if mount_has_unhide; then break; fi
            udisksctl unmount -b "$loop_dev" --no-user-interaction >/dev/null 2>&1 || true
        fi
        mount_out="$(udisksctl mount -b "$loop_dev" --no-user-interaction \
            -o unhide 2>&1 || true)"
        mount_has_unhide && break
        udevadm settle >/dev/null 2>&1 || true
    done

    mount_point="$(findmnt -n -o TARGET --source "$loop_dev" 2>/dev/null | head -n1)"

    if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
        echo "error: could not mount $loop_dev ($iso_name)" >&2
        [ -n "$mount_out" ] && echo "$mount_out" >&2
        mount_point=""
        cleanup
        failed=1
        continue
    fi

    # Not every filesystem accepts "unhide". Proceed anyway, but say so, since
    # this is exactly the condition that produces the media prompt.
    if ! mount_has_unhide; then
        echo "warning: mounted without 'unhide' — any hidden payload files will be" >&2
        echo "         invisible to the installer, which may then ask for the media" >&2
    fi

    echo "Mounted at: $mount_point ($(find "$mount_point" -maxdepth 1 -type f | wc -l) files visible)"

    installer="$(find "$mount_point" -maxdepth 2 -iname '*setup*.exe' -print -quit)"
    if [ -z "$installer" ]; then
        installer="$(find "$mount_point" -maxdepth 2 -iname '*.exe' -print -quit)"
    fi

    if [ -z "$installer" ]; then
        echo "error: no .exe installer found in $iso_name — browse $mount_point manually" >&2
        cleanup
        failed=1
        continue
    fi

    drive_letter="$(pick_drive_letter)" || {
        echo "error: no free drive letter left in $DOSDEVICES" >&2
        drive_letter=""
        cleanup
        failed=1
        continue
    }

    # Present the mount to Wine as a CD-ROM, so the installer's GetDriveType()
    # check on its own location returns DRIVE_CDROM instead of DRIVE_FIXED.
    ln -sfn "$mount_point" "$DOSDEVICES/$drive_letter:"
    ln -sfn "$loop_dev"    "$DOSDEVICES/$drive_letter::"
    "$WINE" reg add 'HKLM\Software\Wine\Drives' \
        /v "$drive_letter:" /d cdrom /f >/dev/null 2>&1 || true

    # Installer path relative to the mount, as a DOS path on that drive.
    rel_path="${installer#"$mount_point"/}"
    dos_path="${drive_letter^^}:\\${rel_path//\//\\}"

    echo "Mapped $mount_point -> ${drive_letter^^}: (cdrom)"
    echo "Running installer with WINEPREFIX=$WINEPREFIX: $dos_path"

    rc=0
    "$WINE" "$dos_path" || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "$iso_name" >> "$DONE_LIST"
    else
        echo "warning: installer for $iso_name exited with status $rc — not marking it" >&2
        echo "         installed. If you cancelled the wizard, just re-run. If not," >&2
        echo "         re-run with WINEDEBUG=+all to see what it did." >&2
        failed=1
    fi

    echo "== Unmounting: $iso_name =="
    cleanup
    echo
done

echo "Done. Installed ISOs are tracked in: $DONE_LIST"
exit "$failed"
