#!/bin/bash
# ---------------------------
# Configure Omarchy (Arch + Hyprland) for pro audio USING PIPEWIRE.
#
# This is the Omarchy port of arch_audio_setup.sh. The important difference:
# Omarchy does NOT use GRUB. It boots with Limine + a Unified Kernel Image,
# so kernel parameters are set with a drop-in in /etc/limine-entry-tool.d/
# and applied with `limine-mkinitcpio` -- there is no /etc/default/grub to
# sed and no grub-mkconfig to run.
#
# Other Omarchy-specific adjustments vs. the Arch script:
#   - PipeWire (pipewire/-alsa/-jack/-pulse + wireplumber) already ships with
#     Omarchy, and PulseAudio is not installed, so there is nothing to remove.
#   - The [multilib] repo is already enabled in Omarchy's pacman.conf, so the
#     pacman.conf rewrite is replaced by a check.
#   - Package installs go through omarchy-pkg-add / omarchy-pkg-aur-add when
#     available (idempotent, --needed), falling back to pacman/yay.
#   - Arch has no /etc/sysctl.conf; settings go in /etc/sysctl.d/.
#   - A stock Omarchy install has no /etc/security/limits.d, so every system
#     file is written through write_system_file(), which creates the parent
#     directory first.
#
# The whole script is idempotent: it is safe to run more than once. If a step
# does fail, an ERR trap prints the line and the call stack, so a partial run
# reports itself instead of stopping quietly.
#
# Verified end to end on Omarchy 4.0.2 (Linux 7.1.9, Limine 12.6.0).
# ---------------------------
# NOTE: Run it with:
#   chmod +x omarchy_audio_setup.sh && ./omarchy_audio_setup.sh
# ---------------------------

set -eEuo pipefail

notify() {
  echo
  echo "--------------------------------------------------------------------"
  echo "$1"
  echo "--------------------------------------------------------------------"
}

warn() { echo "WARNING: $1" >&2; }

# ------------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  echo "Do not run this script as root -- it uses sudo where it needs to," >&2
  echo "and it installs REAPER and the Wine prefix into your own \$HOME." >&2
  exit 1
fi

if ! command -v pacman &>/dev/null; then
  echo "This script targets Omarchy (Arch-based). No pacman found." >&2
  exit 1
fi

# Omarchy 4 installs to /usr/share/omarchy (exported as $OMARCHY_PATH) and sets
# ID=omarchy in /etc/os-release. Older layouts used ~/.local/share/omarchy, so
# all three are accepted.
if ! grep -q '^ID=omarchy' /etc/os-release 2>/dev/null &&
  [[ ! -d ${OMARCHY_PATH:-/usr/share/omarchy} ]] &&
  [[ ! -d $HOME/.local/share/omarchy ]] &&
  ! command -v omarchy-pkg-add &>/dev/null; then
  warn "This does not look like an Omarchy install. Continuing anyway; the"
  warn "Limine bootloader step will be skipped if Limine is not present."
fi

# Report where a failure happened. Without this, `set -e` aborts silently on
# whatever line broke and the run just stops mid-way with no explanation --
# which is exactly how a partial install goes unnoticed.
on_error() {
  local rc=$1 line=$2 cmd=$3 i
  echo >&2
  echo "--------------------------------------------------------------------" >&2
  echo "FAILED at line $line (exit $rc):" >&2
  echo "  $cmd" >&2
  # When the failure is inside a helper, the useful line is the caller's, so
  # walk the call stack out to the top level of the script.
  for ((i = 0; i < ${#FUNCNAME[@]} - 1; i++)); do
    [[ ${FUNCNAME[i]} == on_error ]] && continue
    echo "  called from ${FUNCNAME[i]}() at line ${BASH_LINENO[i]}" >&2
  done
  echo >&2
  echo "Nothing after this point ran, so the setup is INCOMPLETE. Fix the" >&2
  echo "cause and re-run: the script is idempotent, so the steps that already" >&2
  echo "succeeded are skipped." >&2
  echo "--------------------------------------------------------------------" >&2
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ------------------------------------------------------------------------------------
# Wine / yabridge strategy
#
# This matters more than it looks. The newest yabridge RELEASE is 5.1.1
# (Nov 2024), and it does not work with Wine 9.22 or anything newer -- plugin
# editor windows break. Arch currently ships wine-staging 11.x, so installing
# Wine straight from the repos gives you a broken yabridge.
# Upstream: https://github.com/robbert-vdh/yabridge#downgrading-wine
#
#   pin    (default) Hold wine-staging at 9.21 and use the released
#          yabridge-bin. This is upstream's documented recommendation.
#   latest Use the current wine-staging. yabridge's master branch has merged
#          Wine 10 editor embedding support, but it is UNRELEASED -- you must
#          build yabridge from master yourself, or editor windows will break.
#
# Override at run time:  WINE_STRATEGY=latest ./omarchy_audio_setup.sh
# ------------------------------------------------------------------------------------
WINE_STRATEGY="${WINE_STRATEGY:-pin}"
WINE_PIN_VERSION="${WINE_PIN_VERSION:-9.21-1}"

if [[ $WINE_STRATEGY != "pin" && $WINE_STRATEGY != "latest" ]]; then
  echo "WINE_STRATEGY must be 'pin' or 'latest' (got: $WINE_STRATEGY)" >&2
  exit 1
fi

# Ask for sudo once up front and keep the timestamp alive for the long
# package/download steps, so the script doesn't stall waiting for a password.
sudo -v
# `|| true` on every step: a lapsed timestamp must not fire the ERR trap or
# kill the keepalive, it just means the next sudo re-prompts as normal.
while true; do
  sudo -n true 2>/dev/null || true
  sleep 60
  kill -0 "$$" 2>/dev/null || exit 0
done &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# Write a root-owned config file, creating its directory first.
#
# This is not defensive padding: a stock Omarchy install has NO
# /etc/security/limits.d, so a bare `sudo tee` there fails, and under
# `set -e` that aborted the whole script before the audio group, REAPER,
# Wine and yabridge steps ever ran.
write_system_file() {
  local path=$1
  sudo mkdir -p "$(dirname "$path")"
  sudo tee "$path" >/dev/null
}

# Install repo packages, preferring Omarchy's idempotent helper.
pkg_add() {
  if command -v omarchy-pkg-add &>/dev/null; then
    omarchy-pkg-add "$@"
  else
    sudo pacman -S --needed --noconfirm "$@"
  fi
}

# Install AUR packages, preferring Omarchy's helper (which wraps yay).
aur_add() {
  if command -v omarchy-pkg-aur-add &>/dev/null; then
    omarchy-pkg-aur-add "$@"
  elif command -v yay &>/dev/null; then
    yay -S --needed --noconfirm "$@"
  else
    warn "No AUR helper found; skipping: $*"
    return 1
  fi
}

# ------------------------------------------------------------------------------------
# Update the system
# ------------------------------------------------------------------------------------
notify "Update the system"
sudo pacman -Syu --noconfirm

# ------------------------------------------------------------------------------------
# Audio packages
# ------------------------------------------------------------------------------------
notify "Install audio packages"
# Omarchy already ships pipewire, pipewire-alsa, pipewire-jack, pipewire-pulse,
# wireplumber and alsa-utils. They are listed again so this script also works on
# a stripped-down install; --needed makes already-installed ones a no-op.
# There is no PulseAudio on Omarchy, so no removal prompt to answer.
#   alsa-utils: for alsamixer (to raise the base level of the sound card)
#   helvum:     PipeWire patchbay
#   ardour:     DAW
pkg_add \
  pipewire \
  pipewire-alsa \
  pipewire-jack \
  pipewire-pulse \
  wireplumber \
  alsa-utils \
  helvum \
  ardour

# Make the PipeWire JACK replacement libraries discoverable to JACK clients.
JACK_LD_CONF=/etc/ld.so.conf.d/pipewire-jack.conf
if [[ ! -f $JACK_LD_CONF ]] || ! grep -q '/usr/lib/pipewire-0.3/jack' "$JACK_LD_CONF"; then
  echo "Registering PipeWire's JACK libraries with the dynamic linker"
  echo "/usr/lib/pipewire-0.3/jack" | write_system_file "$JACK_LD_CONF"
  sudo ldconfig
else
  echo "PipeWire JACK libraries already registered."
fi

# ---------------------------
# Kernel parameters  (this is the part that replaces the GRUB block)
#
# threadirqs                        = force threaded IRQ handlers, so audio
#                                     interrupts can be prioritised and don't
#                                     get stuck behind other hardware.
# cpufreq.default_governor=performance = don't let the CPU clock down mid-take,
#                                     which shows up as xruns/crackle.
#
# Omarchy boots via Limine and builds a UKI, so the kernel command line is
# assembled by limine-entry-tool from drop-ins in /etc/limine-entry-tool.d/.
# Omarchy's own defaults live in omarchy-defaults.conf; adding a separate
# 99- file means an Omarchy update can never clobber our settings and we
# never have to edit theirs. `+=` appends to whatever is already set.
# ---------------------------
notify "Add pro-audio kernel parameters (Limine)"

LIMINE_DROP_IN=/etc/limine-entry-tool.d/99-pro-audio.conf
AUDIO_CMDLINE=" threadirqs cpufreq.default_governor=performance"

if command -v limine-mkinitcpio &>/dev/null || [[ -d /etc/limine-entry-tool.d ]]; then
  if [[ -f $LIMINE_DROP_IN ]] && grep -q 'threadirqs' "$LIMINE_DROP_IN"; then
    echo "Pro-audio kernel parameters already configured in $LIMINE_DROP_IN"
  else
    sudo mkdir -p /etc/limine-entry-tool.d
    cat <<EOF | write_system_file "$LIMINE_DROP_IN"
# Pro-audio kernel parameters (added by omarchy_audio_setup.sh)
# threadirqs: threaded interrupt handlers, so audio IRQs can be prioritised.
# cpufreq.default_governor=performance: stop the CPU clocking down mid-take.
KERNEL_CMDLINE[default]+="$AUDIO_CMDLINE"
EOF
    echo "Wrote $LIMINE_DROP_IN"

    # limine-mkinitcpio rebuilds the initramfs/UKI for every kernel and
    # refreshes the /boot/limine.conf entries via limine-entry-tool. We do not
    # need `limine-update` here: that also re-deploys the bootloader binary to
    # the ESP and would rebuild everything a second time for no benefit.
    if command -v limine-mkinitcpio &>/dev/null; then
      echo "Regenerating initramfs / UKI..."
      sudo limine-mkinitcpio
    else
      warn "limine-mkinitcpio not found -- run it (or 'sudo limine-update') by"
      warn "hand so the new kernel parameters are built into the boot entry."
    fi
  fi
elif [[ -f /etc/default/grub ]]; then
  # Not expected on Omarchy, but keeps the script usable on a plain Arch box.
  notify "Limine not found -- falling back to GRUB"
  if grep -q 'threadirqs' /etc/default/grub; then
    echo "Pro-audio kernel parameters already present in /etc/default/grub"
  else
    sudo cp /etc/default/grub "/etc/default/grub.bak.$(date +%Y%m%d%H%M%S)"
    # Append inside the existing quotes instead of matching one exact string,
    # so this works whatever the current default line happens to contain.
    sudo sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1$AUDIO_CMDLINE\"/" /etc/default/grub
    sudo grub-mkconfig -o /boot/grub/grub.cfg
  fi
else
  warn "No Limine and no GRUB config found -- skipping kernel parameters."
  warn "Add this to your bootloader's kernel command line by hand:"
  warn "  $AUDIO_CMDLINE"
fi

# NOTE: Omarchy runs power-profiles-daemon, which manages the CPU governor at
# runtime and can override the boot default above. If you still see the
# governor drop back, set the profile for a session with:
#   powerprofilesctl set performance
if [[ ! -d /sys/devices/system/cpu/cpufreq/policy0 ]]; then
  warn "This kernel exposes no cpufreq policy, so"
  warn "cpufreq.default_governor=performance will have no effect here."
  warn "That is normal in a VM, and on Intel hosts where intel_pstate runs in"
  warn "active mode. threadirqs still applies; the governor line is harmless."
fi

# ---------------------------
# limits
# ---------------------------
notify "Configure realtime limits for the audio group"
# See https://wiki.linuxaudio.org/wiki/system_configuration for more information.
# (Arch also ships a `realtime-privileges` package that does this against a
# `realtime` group instead; this keeps the @audio convention.)
AUDIO_LIMITS=/etc/security/limits.d/audio.conf
if [[ -f $AUDIO_LIMITS ]] && grep -q 'rtprio' "$AUDIO_LIMITS"; then
  echo "Realtime limits already configured in $AUDIO_LIMITS"
else
  printf '@audio - rtprio 90\n@audio - memlock unlimited\n' | write_system_file "$AUDIO_LIMITS"
  echo "Wrote $AUDIO_LIMITS"
fi

# ---------------------------
# sysctl
# ---------------------------
notify "Raise the inotify watch limit"
# Arch/Omarchy has no /etc/sysctl.conf -- drop-ins go in /etc/sysctl.d/.
# Omarchy already ships 90-omarchy-file-watchers.conf at 524288; the 99- prefix
# means this file is read later and wins.
AUDIO_SYSCTL=/etc/sysctl.d/99-pro-audio.conf
if [[ -f $AUDIO_SYSCTL ]] && grep -q 'max_user_watches' "$AUDIO_SYSCTL"; then
  echo "inotify limit already configured in $AUDIO_SYSCTL"
else
  printf '# Raised for sample libraries and project trees (pro-audio setup)\nfs.inotify.max_user_watches=600000\n' |
    write_system_file "$AUDIO_SYSCTL"
  sudo sysctl --system >/dev/null
  echo "Wrote $AUDIO_SYSCTL"
fi

# ---------------------------
# Add the user to the audio group
# ---------------------------
notify "Add ourselves to the audio group"
if id -nG "$USER" | tr ' ' '\n' | grep -qx audio; then
  echo "$USER is already in the audio group."
else
  sudo usermod -a -G audio "$USER"
  echo "Added $USER to the audio group (takes effect after logout/reboot)."
fi

# ---------------------------
# REAPER
# Note: this creates a PORTABLE REAPER installation at ~/REAPER.
# ---------------------------
notify "REAPER"
if [[ -d $HOME/REAPER ]]; then
  echo "~/REAPER already exists -- skipping. Delete it first to reinstall."
else
  # Resolve the current 7.x build from reaper.fm, falling back to a known-good
  # one if the page layout changes or the machine is offline.
  REAPER_FALLBACK_FILE="reaper779_linux_x86_64.tar.xz"
  REAPER_FILE="$(curl -fsSL --max-time 20 https://www.reaper.fm/download.php 2>/dev/null |
    grep -oE 'reaper[0-9]+_linux_x86_64\.tar\.xz' | head -1 || true)"
  REAPER_FILE="${REAPER_FILE:-$REAPER_FALLBACK_FILE}"
  echo "Installing $REAPER_FILE"

  REAPER_TMP="$(mktemp -d)"
  curl -fL --retry 3 -o "$REAPER_TMP/reaper.tar.xz" \
    "https://www.reaper.fm/files/7.x/$REAPER_FILE"
  mkdir -p "$REAPER_TMP/reaper"
  tar -C "$REAPER_TMP/reaper" -xf "$REAPER_TMP/reaper.tar.xz"
  "$REAPER_TMP/reaper/reaper_linux_x86_64/install-reaper.sh" --install "$HOME/" --integrate-desktop
  rm -rf "$REAPER_TMP"

  # An empty reaper.ini next to the binary is what makes the install portable.
  touch "$HOME/REAPER/reaper.ini"
fi

# ------------------------------------------------------------------------------------
# Wine (staging)
# https://wiki.winehq.org/Winetricks
# ------------------------------------------------------------------------------------
notify "Wine (staging)"

# Omarchy enables [multilib] out of the box; only touch pacman.conf if it isn't.
if pacman-conf --repo-list 2>/dev/null | grep -qx multilib; then
  echo "[multilib] is already enabled."
else
  echo "Enabling [multilib]"
  sudo cp /etc/pacman.conf "/etc/pacman.conf.bak.$(date +%Y%m%d%H%M%S)"
  # Uncomment the [multilib] section header and the Include line that follows it.
  # Strip the '#' from the header first: `n` prints the current line as-is and
  # pulls in the next one, so a later command can no longer touch the header.
  sudo sed -i '/^#\[multilib\]$/{s/^#//;n;s/^#Include/Include/}' /etc/pacman.conf
  sudo pacman -Sy --noconfirm
fi

pkg_add winetricks

# Keep the wine-staging pin alive across Omarchy updates.
#
# `omarchy refresh pacman` (which runs as part of an Omarchy update) copies its
# own template over /etc/pacman.conf, which would wipe a plain IgnorePkg line.
# Omarchy's documented escape hatch is a pre-refresh-pacman hook, which runs
# after the template is written and before `pacman -Syyuu`. We write the pin
# logic there and then execute that same file once, so the hook and the live
# config can never drift apart.
install_wine_pin_hook() {
  local hook_dir="$HOME/.config/omarchy/hooks/pre-refresh-pacman.d"
  local hook="$hook_dir/10-pin-wine-staging"
  mkdir -p "$hook_dir"
  cat >"$hook" <<'HOOK'
#!/bin/bash
# Re-apply the wine-staging pin after `omarchy refresh pacman` rewrites
# /etc/pacman.conf. Installed by omarchy_audio_setup.sh.
#
# yabridge 5.1.1 does not work with Wine >= 9.22, so wine-staging is held at
# 9.21. Delete this file (and the IgnorePkg line) to let Wine float again.
CONF=/etc/pacman.conf

grep -qE '^IgnorePkg.*(=| )wine-staging( |$)' "$CONF" && exit 0

if grep -qE '^IgnorePkg' "$CONF"; then
  sudo sed -i 's/^\(IgnorePkg *=.*\)$/\1 wine-staging/' "$CONF"
else
  sudo sed -i '0,/^\[options\]/s||[options]\nIgnorePkg = wine-staging|' "$CONF"
fi
HOOK
  chmod +x "$hook"
  # Apply it now to the current pacman.conf.
  bash "$hook"
}

case "$WINE_STRATEGY" in
  pin)
    installed_wine="$(pacman -Q wine-staging 2>/dev/null | awk '{print $2}' || true)"
    if [[ $installed_wine == "$WINE_PIN_VERSION" ]]; then
      echo "wine-staging is already pinned at $WINE_PIN_VERSION."
      install_wine_pin_hook
    else
      notify "Pinning wine-staging to $WINE_PIN_VERSION for yabridge"
      echo "Installed: ${installed_wine:-none}  ->  target: $WINE_PIN_VERSION"
      echo "(yabridge 5.1.1 breaks on Wine 9.22+; see the notes at the top.)"

      # Pin BEFORE installing, so a concurrent -Syu can't pull it forward again.
      install_wine_pin_hook

      WINE_PKG="wine-staging-$WINE_PIN_VERSION-x86_64.pkg.tar.zst"
      WINE_URL="https://archive.archlinux.org/packages/w/wine-staging/$WINE_PKG"
      WINE_TMP="$(mktemp -d)"
      echo "Downloading $WINE_PKG from the Arch Linux Archive (~60MB)..."
      curl -fL --retry 3 -o "$WINE_TMP/$WINE_PKG" "$WINE_URL"
      # Fetch the signature too, so pacman can verify rather than being told
      # to skip the check.
      curl -fL --retry 3 -o "$WINE_TMP/$WINE_PKG.sig" "$WINE_URL.sig" || true

      if sudo pacman -U --noconfirm "$WINE_TMP/$WINE_PKG"; then
        echo "Pinned wine-staging at $WINE_PIN_VERSION."
      else
        warn "Could not install the pinned wine-staging $WINE_PIN_VERSION."
        warn "This usually means a dependency in current Arch has moved on"
        warn "since that build. Options:"
        warn "  1. Re-run with WINE_STRATEGY=latest and build yabridge from"
        warn "     master (it has unreleased Wine 10 embedding support)."
        warn "  2. Use the AUR 'downgrade' tool to pick a nearby version:"
        warn "       sudo env DOWNGRADE_FROM_ALA=1 downgrade wine-staging"
      fi
      rm -rf "$WINE_TMP"
    fi
    ;;
  latest)
    pkg_add wine-staging
    warn "WINE_STRATEGY=latest: you are on current wine-staging."
    warn "The RELEASED yabridge (5.1.1) will have broken plugin editor windows."
    warn "Build yabridge from master, which has merged Wine 10 embedding support:"
    warn "  https://github.com/robbert-vdh/yabridge#installing-a-development-build"
    ;;
esac

# Base wine packages required for proper plugin functionality.
# winetricks is not idempotent-friendly, so only run it on a fresh prefix.
if [[ -d $HOME/.wine/drive_c/windows/Fonts ]] && compgen -G "$HOME/.wine/drive_c/windows/Fonts/times*" >/dev/null; then
  echo "corefonts already installed in the Wine prefix."
else
  winetricks -q corefonts || warn "winetricks corefonts failed; plugin GUIs may render without fonts."
fi

# ------------------------------------------------------------------------------------
# yabridge
# ------------------------------------------------------------------------------------
notify "yabridge"

# Verify the Wine we ended up with is one the released yabridge can drive.
# vercmp is pacman's own version comparator: it prints 1 when $1 > $2.
WINE_VER="$(wine --version 2>/dev/null | sed 's/^wine-//; s/ .*//' || true)"
if [[ -n $WINE_VER ]]; then
  echo "Wine version in use: $WINE_VER"
  wine_cmp="$(vercmp "$WINE_VER" 9.21 2>/dev/null || echo 0)"
  if [[ ${wine_cmp:-0} -gt 0 ]]; then
    warn "Wine $WINE_VER is newer than 9.21, which the released yabridge"
    warn "(5.1.1) cannot drive -- plugin editor windows will misbehave."
    warn "Either re-run with the default WINE_STRATEGY=pin, or build yabridge"
    warn "from master instead of installing yabridge-bin."
  fi
fi

if [[ $WINE_STRATEGY == "pin" ]]; then
  aur_add yabridge-bin || warn "yabridge-bin install failed; skipping yabridge setup."
else
  # On 'latest', yabridge-bin is knowingly the wrong build, so don't install it
  # over a master build the user may have put in place themselves.
  if command -v yabridgectl &>/dev/null; then
    echo "Using the yabridge already installed (expected: a master build)."
  else
    warn "No yabridge found. Install a master build before running yabridgectl:"
    warn "  https://github.com/robbert-vdh/yabridge#installing-a-development-build"
  fi
fi

if command -v yabridgectl &>/dev/null; then
  # Create common VST paths
  VST_DIRS=(
    "$HOME/.wine/drive_c/Program Files/Steinberg/VstPlugins"
    "$HOME/.wine/drive_c/Program Files/Common Files/VST2"
    "$HOME/.wine/drive_c/Program Files/Common Files/VST3"
  )
  for dir in "${VST_DIRS[@]}"; do
    mkdir -p "$dir"
    # `yabridgectl add` is already a no-op on a known path, but checking keeps
    # the output clean on re-runs.
    if yabridgectl status 2>/dev/null | grep -Fq "$dir"; then
      echo "Already registered: $dir"
    else
      yabridgectl add "$dir"
    fi
  done
  yabridgectl sync || warn "yabridgectl sync failed -- run it by hand once Wine is working."
fi

# ---------------------------
# Install Windows VST plugins
# This is a manual step for you to run when you download plugins.
# First, run the plugin installer .exe file.
# When the installer asks for a directory, make sure you select
# one of the directories above.
#
# VST2 plugins:
#   C:\Program Files\Steinberg\VstPlugins
# OR
#   C:\Program Files\Common Files\VST2
#
# VST3 plugins:
#   C:\Program Files\Common Files\VST3
#
# Each time you install a new plugin, run:
#   yabridgectl sync
# ---------------------------

# ---------------------------
# FINISHED!
# ---------------------------
notify "Verifying"

check() { # check <label> <ok-condition-output> ; prints PASS/TODO
  local label=$1 ok=$2 detail=${3:-}
  if [[ $ok == yes ]]; then
    printf '  [ok]   %s\n' "$label"
  else
    printf '  [todo] %s%s\n' "$label" "${detail:+  -- $detail}"
  fi
}

grep -q threadirqs /proc/cmdline && cmdline_ok=yes || cmdline_ok=no
[[ -f /etc/security/limits.d/audio.conf ]] && limits_file_ok=yes || limits_file_ok=no
cur_rtprio=$(ulimit -r 2>/dev/null || echo 0)
# ulimit can print "unlimited", which is not a number -- treat it as passing.
if [[ $cur_rtprio == unlimited ]] || { [[ $cur_rtprio =~ ^[0-9]+$ ]] && ((cur_rtprio >= 90)); }; then
  rtprio_ok=yes
else
  rtprio_ok=no
fi
id -nG "$USER" | tr ' ' '\n' | grep -qx audio && group_ok=yes || group_ok=no
[[ -d $HOME/REAPER ]] && reaper_ok=yes || reaper_ok=no
command -v yabridgectl &>/dev/null && yab_ok=yes || yab_ok=no

check "kernel parameters live (threadirqs in /proc/cmdline)" "$cmdline_ok" "needs a reboot"
check "realtime limits file written" "$limits_file_ok"
check "realtime limits active in this shell (rtprio >= 90)" "$rtprio_ok" "needs a full logout or reboot"
check "member of the audio group" "$group_ok" "needs a full logout or reboot"
check "REAPER installed at ~/REAPER" "$reaper_ok"
check "yabridgectl available" "$yab_ok"

notify "Done - please reboot."
cat <<'EOF'
Every [todo] above that says "needs a reboot" clears on the next boot. Re-run
this script afterwards to re-check; it is idempotent.

After rebooting, confirm by hand:

  cat /proc/cmdline                 # should contain threadirqs
  ulimit -r -l                      # rtprio 90, memlock unlimited
  id -nG | tr ' ' '\n' | grep audio # you are in the audio group
  pw-top                            # live graph; watch the ERR column for xruns
  wine --version                    # 9.21 if pinned for yabridge
  yabridgectl status                # reports Wine/yabridge version mismatches

Then run alsamixer to raise the base level of your sound card, and make music!
EOF
