#!/usr/bin/env bash
# =============================================================================
# omarchy_system_setup.sh  —  Omarchy system setup
# Gaming · Game Development · Music Production (prep)
#
# Omarchy port of system_setup_arch.sh (which targeted CachyOS/Arch + KDE).
# Tuned for an NVIDIA machine.
#
# HOW TO USE:
#   • Comment out any line in PACMAN_PKGS / AUR_PKGS / OMARCHY_APPS / FLATPAK_APPS
#     to skip it. Add new ones the same way.
#
# Usage:
#   ./omarchy_system_setup.sh          # full install
#   ./omarchy_system_setup.sh -n       # dry-run, changes nothing
#
#   SETUP_ZSH=1 ./omarchy_system_setup.sh    # also switch the login shell to zsh
#
# ⚠  Run this BEFORE omarchy_audio_setup.sh
#
# -----------------------------------------------------------------------------
# WHAT CHANGED FROM THE ARCH/CACHYOS VERSION, AND WHY
#
# NVIDIA is delegated to Omarchy's own hardware detection instead of being
# hardcoded. The original pinned `nvidia-dkms` for everyone and never installed
# kernel headers, so the DKMS build had nothing to build against. Omarchy
# already ships the logic to pick the right branch, and this script reuses it:
#   Turing or newer (GSP)  -> nvidia-open-dkms + nvidia-utils + libva-nvidia-driver
#   Maxwell/Pascal/Volta   -> nvidia-580xx-dkms + nvidia-580xx-utils
# It also writes the early-KMS modprobe and mkinitcpio drop-ins, and -- the part
# that is easy to miss on Omarchy -- rebuilds the UKI with `limine-mkinitcpio`,
# because Omarchy boots Limine + a Unified Kernel Image rather than GRUB.
# Hyprland's NVIDIA env vars are NOT set here: Omarchy's default/hypr/nvidia.lua
# already applies them per session when it detects the card.
#
# paru -> yay. Omarchy ships yay; installs go through omarchy-pkg-add /
# omarchy-pkg-aur-add, which are idempotent and verify the package landed.
#
# The KDE block is gone. Omarchy is Hyprland, and pulling in spectacle,
# plasma-systemmonitor, filelight and kfind drags half of Qt/KDE onto a machine
# that already has btop, hyprshot/grim+slurp, nautilus and dua-cli.
#
# timeshift is gone. Omarchy snapshots with snapper + limine-snapper-sync,
# already wired into the boot menu. A second snapshot manager on the same Btrfs
# root is a good way to lose both.
#
# The LazyVim block is gone. Omarchy ships omarchy-nvim, which IS LazyVim,
# already configured. The original moved ~/.config/nvim to .bak and replaced it
# with the upstream starter -- that silently throws away Omarchy's setup.
#
# The zsh switch is opt-in (SETUP_ZSH=1). Omarchy is a bash desktop with its own
# prompt and shell config; chsh'ing to zsh by default leaves you outside it.
#
# UFW is verified, not reconfigured. Omarchy already sets deny-in/allow-out,
# opens LocalSend, and installs the ufw-docker rules.
#
# p7zip -> 7zip (p7zip was dropped from the Arch repos).
# realtime-privileges moved from AUR to the pacman list; it is in [extra] now.
# Most of the Flatpak list became native packages -- Omarchy's own repo carries
# 1password, heroic, localsend and spotify, and discord/krita/godot/obsidian/
# flatseal are all in [extra]. Native means themed, faster, and no portal
# surprises. Flatpak is only installed if FLATPAK_APPS is non-empty.
# =============================================================================

set -uo pipefail

DRY_RUN=false
[[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]] && DRY_RUN=true
SETUP_ZSH="${SETUP_ZSH:-0}"

LOG="$HOME/omarchy_system_setup_$(date +%Y%m%d_%H%M%S).log"
: >"$LOG"

# Colours
if [ -t 1 ]; then
  R='\033[0m' G='\033[32m' Y='\033[33m' RED='\033[31m' C='\033[36m' BOLD='\033[1m'
else R='' G='' Y='' RED='' C='' BOLD=''; fi

log() { echo -e "$*" | tee -a "$LOG"; }
info() { log "${C}  ➜  $*${R}"; }
ok() { log "${G}  ✔  $*${R}"; }
warn() { log "${Y}  ⚠  $*${R}"; }
err() { log "${RED}  ✘  $*${R}"; }
section() {
  log
  log "${BOLD}── $* ──${R}"
}

# Anything that could not be installed lands here and is replayed at the end,
# so a 200-package run doesn't hide three failures in the scrollback.
FAILED=()
note_failure() { FAILED+=("$1"); }

run() { $DRY_RUN && log "  [dry-run] $*" || eval "$*" >>"$LOG" 2>&1; }

append_once() {
  touch "$2"
  grep -qxF "$1" "$2" || echo "$1" >>"$2"
}

print_list() {
  local i=1
  for item in "$@"; do
    log "  ${BOLD}$(printf '%3d' $i).${R} $item"
    ((i++))
  done
}

pacman_installed() { pacman -Qi "$1" &>/dev/null; }
has_cmd() { command -v "$1" &>/dev/null; }

# --- package helpers ---------------------------------------------------------
# omarchy-pkg-add is idempotent, uses --needed, and re-checks with `pacman -Q`
# afterwards, so a package that silently fails to install is still reported.

pkg_add_one() {
  local pkg=$1
  if $DRY_RUN; then
    log "  [dry-run] install $pkg"
    return 0
  fi
  if has_cmd omarchy-pkg-add; then
    omarchy-pkg-add "$pkg" >>"$LOG" 2>&1
  else
    sudo pacman -S --noconfirm --needed "$pkg" >>"$LOG" 2>&1
  fi
}

aur_add_one() {
  local pkg=$1
  if $DRY_RUN; then
    log "  [dry-run] install $pkg (AUR)"
    return 0
  fi
  if has_cmd omarchy-pkg-aur-add; then
    omarchy-pkg-aur-add "$pkg" >>"$LOG" 2>&1
  elif has_cmd yay; then
    yay -S --noconfirm --needed "$pkg" >>"$LOG" 2>&1
  else
    return 1
  fi
}

install_with_progress() { # install_with_progress <repo|aur> <pkgs...>
  local kind=$1
  shift
  local total=$# i=1 tag=""
  [[ $kind == aur ]] && tag=" ${Y}(AUR)${R}"
  for pkg in "$@"; do
    if pacman_installed "$pkg"; then
      log "  ${BOLD}[${i}/${total}]${R} ${pkg} — ${G}already installed${R}"
      ((i++))
      continue
    fi
    log "  ${BOLD}[${i}/${total}]${R} ${C}${pkg}${R}${tag}"
    if [[ $kind == aur ]]; then
      aur_add_one "$pkg" || { warn "Failed: $pkg (AUR) — skipping"; note_failure "AUR $pkg"; }
    else
      pkg_add_one "$pkg" || { warn "Failed: $pkg — skipping"; note_failure "pkg $pkg"; }
    fi
    ((i++))
  done
}

# =============================================================================
# ── EDIT THESE LISTS ─────────────────────────────────────────────────────────
# =============================================================================

# Official repo packages. Anything Omarchy already ships (bat, eza, fzf, fd,
# ripgrep, btop, fastfetch, zoxide, tmux, wl-clipboard, jq, ffmpeg, neovim,
# starship, ufw, unzip, alsa-utils, base-devel, noto-fonts-emoji, poppler,
# chromium, docker, obsidian, localsend, nautilus, mpv, obs-studio, kdenlive)
# is deliberately absent — it is already there.
PACMAN_PKGS=(
  # ── Safety ────────────────────────────────────────────────────────────
  # ufw ships and is already enabled by Omarchy; snapper replaces timeshift.

  # ── System ────────────────────────────────────────────────────────────
  irqbalance          # distributes IRQs across CPU cores
  cpupower            # inspect/set CPU governor manually
  realtime-privileges # 'realtime' group + rtprio/memlock limits (in [extra] now)

  # ── Build tools ───────────────────────────────────────────────────────
  cmake
  ninja
  meson
  python-pip
  python-virtualenv
  openssl
  libffi

  # ── Archives ──────────────────────────────────────────────────────────
  7zip # replaces p7zip, which was dropped from the Arch repos
  unrar
  zip

  # ── Fonts ─────────────────────────────────────────────────────────────
  ttf-jetbrains-mono # Omarchy ships the Nerd Font variant; this is the plain one

  # ── GPU / Vulkan ──────────────────────────────────────────────────────
  # The NVIDIA driver itself is NOT listed here — see setup_nvidia() below,
  # which picks the right branch for your card. These are vendor-neutral.
  vulkan-icd-loader
  lib32-vulkan-icd-loader
  vulkan-tools # vulkaninfo, vkcube

  # ── Gaming ────────────────────────────────────────────────────────────
  # steam is installed via OMARCHY_APPS so it also pulls the lib32 GPU drivers.
  gamemode       # CPU/IO optimiser while gaming — use: gamemoderun %command%
  lib32-gamemode # 32-bit Steam games need this
  mangohud       # in-game overlay — use: MANGOHUD=1 %command%
  lib32-mangohud

  # ── Productivity ──────────────────────────────────────────────────────
  qemu-full
  libvirt
  virt-manager
  bridge-utils
  vlc

  # ── Game dev / creative ───────────────────────────────────────────────
  # NOTE: this is a single Godot version, not the Godots version manager the
  # Flatpak list used. If you juggle several Godot versions, keep Godots as a
  # Flatpak (io.github.MakovWait.Godots) and drop this line.
  godot
  krita

  # ── Chat / notes ──────────────────────────────────────────────────────
  discord  # native package, was com.discordapp.Discord on Flatpak
  obsidian # in Omarchy's base list, kept here so a trimmed install gets it too

  # ── Neovim extras ─────────────────────────────────────────────────────
  # neovim + LazyVim already ship as omarchy-nvim. These are its helpers.
  nodejs
  npm

  # ── Shell + terminal ──────────────────────────────────────────────────
  # Omarchy is bash + starship. zsh is only installed if you asked for it.

  # ── CLI utils ─────────────────────────────────────────────────────────
  htop
  ncdu
  tree
  duf # modern df

  # ── Network ───────────────────────────────────────────────────────────
  net-tools
  mtr
  nmap
)

# zsh only matters if you opted in.
[[ $SETUP_ZSH == 1 ]] && PACMAN_PKGS+=(zsh)

# AUR packages (via yay / omarchy-pkg-aur-add).
AUR_PKGS=(
  unityhub # Unity game engine launcher — no repo version exists
)

# Installed through Omarchy's own installers, which do more than `pacman -S`:
# the gaming ones also pull the matching lib32 GPU drivers for your card, and
# 1password wires up its Chromium extension.
OMARCHY_APPS=(
  gaming-steam    # steam + lib32 GPU drivers
  gaming-heroic   # Epic + GOG + Amazon
  service-1password
  service-spotify
)

# Flatpak is NOT installed unless this list is non-empty. Everything that used
# to be here has a native package on Omarchy; only add things that genuinely
# have no repo build.
FLATPAK_APPS=(
  #com.usebottles.bottles          # Windows apps, isolated from the audio Wine prefix
  #io.github.MakovWait.Godots      # Godot version manager (see the godot note above)
)

# =============================================================================
# ── NVIDIA ────────────────────────────────────────────────────────────────────
# =============================================================================

# GPU detection mirrors Omarchy's own omarchy-hw-nvidia* helpers and defers to
# them when present. The fallbacks below read the same cached sysfs IDs rather
# than calling lspci, which reads PCI config space and resumes a runtime-
# suspended GPU.
#
# The device-ID boundaries are upstream's: GSP firmware arrived with Turing,
# which is also where IDs cross 0x1e00, and Maxwell opens at 0x1340, one ID
# after the last Kepler part. Anything below that needs a legacy driver Arch no
# longer packages -- hence a third "unsupported" outcome rather than a silent
# fallback to the 580xx branch.
#
# Runs in a subshell so `shopt -s nullglob` cannot leak into the caller.
_nvidia_sysfs_scan() { # <min-device-id> [<max-device-id, exclusive>]
  local min=$1 max=${2:-}
  (
    shopt -s nullglob
    for dev in "${OMARCHY_PCI_DEVICES_PATH:-/sys/bus/pci/devices}"/*; do
      [[ -r $dev/vendor && -r $dev/class && -r $dev/device ]] || continue
      [[ $(<"$dev/vendor") == 0x10de ]] || continue
      [[ $(<"$dev/class") == 0x03* ]] || continue
      id=$(<"$dev/device")
      ((id >= min)) || continue
      [[ -z $max ]] || ((id < max)) || continue
      exit 0
    done
    exit 1
  )
}

has_nvidia() {
  has_cmd omarchy-hw-nvidia && { omarchy-hw-nvidia; return; }
  _nvidia_sysfs_scan 0
}

# Turing (RTX 20xx) and newer ship GSP firmware and take the open modules.
has_nvidia_gsp() {
  has_cmd omarchy-hw-nvidia-gsp && { omarchy-hw-nvidia-gsp; return; }
  _nvidia_sysfs_scan $((0x1e00))
}

# Maxwell, Pascal and Volta: no GSP firmware, but still covered by 580xx.
has_nvidia_without_gsp() {
  has_cmd omarchy-hw-nvidia-without-gsp && { omarchy-hw-nvidia-without-gsp; return; }
  _nvidia_sysfs_scan $((0x1340)) $((0x1e00))
}

setup_nvidia() {
  section "NVIDIA"

  if ! has_nvidia; then
    ok "No NVIDIA GPU detected — skipping the whole NVIDIA section."
    return
  fi

  local rebuild_uki=false

  # DKMS needs headers for the running kernel. The original script installed
  # nvidia-dkms without them, so the module never built.
  local kernel_pkg
  kernel_pkg=$(pacman -Qqs '^linux(-zen|-lts|-hardened|-t2|-ptl)?$' 2>/dev/null | head -1)
  if [[ -n $kernel_pkg ]]; then
    info "Installing ${kernel_pkg}-headers for the DKMS build..."
    pkg_add_one "${kernel_pkg}-headers" || note_failure "pkg ${kernel_pkg}-headers"
  else
    warn "Could not identify the kernel package; install <kernel>-headers by hand."
  fi

  local -a pkgs
  if has_nvidia_gsp; then
    info "GPU is Turing or newer (GSP firmware) — using the open modules."
    pkgs=(nvidia-open-dkms nvidia-utils lib32-nvidia-utils libva-nvidia-driver nvidia-settings)
  elif has_nvidia_without_gsp; then
    info "GPU is Maxwell/Pascal/Volta — using the 580xx legacy branch."
    pkgs=(nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils nvidia-settings)
  else
    # Kepler and older. The 580xx branch does not support these, so installing
    # it would put a driver on the system that cannot drive the card -- and the
    # UKI rebuild further down would then hand a black screen to the next boot.
    # Omarchy's own installer bails here for the same reason.
    err "NVIDIA GPU detected, but it predates Maxwell and no packaged driver"
    err "supports it. Leaving graphics alone; see"
    err "https://wiki.archlinux.org/title/NVIDIA"
    note_failure "nvidia (GPU too old for any packaged driver)"
    return
  fi
  install_with_progress repo "${pkgs[@]}"

  # Early KMS. Without modeset=1 you get a black screen or a torn handoff into
  # Hyprland on Wayland.
  local modprobe_conf=/etc/modprobe.d/nvidia.conf
  if [[ -f $modprobe_conf ]] && grep -q 'nvidia_drm modeset=1' "$modprobe_conf"; then
    ok "modprobe early-KMS already configured."
  else
    info "Writing $modprobe_conf (nvidia_drm modeset=1)..."
    run "printf 'options nvidia_drm modeset=1\n' | sudo tee '$modprobe_conf' >/dev/null"
    rebuild_uki=true
  fi

  local mkinit_conf=/etc/mkinitcpio.conf.d/nvidia.conf
  if [[ -f $mkinit_conf ]] && grep -q 'nvidia_drm' "$mkinit_conf"; then
    ok "mkinitcpio NVIDIA modules already configured."
  else
    info "Writing $mkinit_conf (early module load)..."
    run "sudo mkdir -p /etc/mkinitcpio.conf.d"
    run "printf 'MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n' | sudo tee '$mkinit_conf' >/dev/null"
    rebuild_uki=true
  fi

  # THE Omarchy-specific step. Omarchy boots Limine + a UKI, so the modules and
  # kernel command line only take effect once the UKI is rebuilt. On plain Arch
  # a bare `mkinitcpio -P` would do; here it has to go through Limine's hook.
  if $rebuild_uki; then
    if has_cmd limine-mkinitcpio; then
      info "Rebuilding the initramfs / UKI so early KMS takes effect..."
      run "sudo limine-mkinitcpio"
      ok "UKI rebuilt."
    elif has_cmd mkinitcpio; then
      warn "limine-mkinitcpio not found — falling back to mkinitcpio -P."
      run "sudo mkinitcpio -P"
    else
      err "No way to rebuild the initramfs. Run 'sudo limine-mkinitcpio' by hand."
      note_failure "initramfs rebuild"
    fi
  else
    ok "NVIDIA boot configuration already in place — no UKI rebuild needed."
  fi

  # Deliberately NOT setting LIBVA_DRIVER_NAME / __GLX_VENDOR_LIBRARY_NAME:
  # Omarchy's default/hypr/nvidia.lua sets them per session when it detects the
  # card, and a second copy in a shell rc only drifts out of date.
  ok "Hyprland NVIDIA env vars are handled by Omarchy — nothing to add."
  warn "NVIDIA: reboot required before the driver is actually in use."
}

# =============================================================================
# ── POST-INSTALL CONFIG ───────────────────────────────────────────────────────
# =============================================================================

post_install() {
  section "Post-install configuration"

  # --- UFW ---
  # Omarchy already sets deny-in/allow-out, opens LocalSend (53317) and installs
  # the ufw-docker rules. Don't re-run `ufw --force enable` over that; just say
  # what the state is.
  if has_cmd ufw; then
    if systemctl is-enabled ufw &>/dev/null; then
      ok "UFW is enabled (configured by Omarchy: deny in, allow out, LocalSend open)."
    else
      info "Enabling UFW..."
      run "sudo ufw default deny incoming"
      run "sudo ufw default allow outgoing"
      run "sudo ufw allow 53317/tcp" # LocalSend
      run "sudo ufw allow 53317/udp"
      run "sudo ufw --force enable"
      ok "UFW enabled."
    fi
  fi

  # --- Steam / Proton map count ---
  # Omarchy's own sysctl drop-in is 99-omarchy-sysctl.conf and does not set
  # this; a separate file keeps an Omarchy update from clobbering it.
  local sysctl_file="/etc/sysctl.d/99-gaming-performance.conf"
  if [ -f "$sysctl_file" ]; then
    ok "vm.max_map_count already configured."
  else
    info "Setting vm.max_map_count for Steam/Proton..."
    run "sudo mkdir -p /etc/sysctl.d"
    run "echo 'vm.max_map_count=2147483642' | sudo tee '$sysctl_file' >/dev/null"
    run "sudo sysctl --system >/dev/null"
  fi

  # --- irqbalance ---
  if pacman_installed irqbalance; then
    run "sudo systemctl enable --now irqbalance"
    ok "irqbalance enabled."
  fi

  # --- Groups ---
  # realtime-privileges gives @realtime rtprio/memlock. omarchy_audio_setup.sh
  # separately configures @audio; being in both is fine and complementary.
  if pacman_installed realtime-privileges; then
    run "sudo usermod -aG realtime,audio '$USER'"
    warn "Group change (realtime, audio): takes effect on next login."
  fi

  if has_cmd gamemoded && getent group gamemode &>/dev/null; then
    run "sudo usermod -aG gamemode '$USER'"
    ok "Added to gamemode group. Steam launch option: gamemoderun %command%"
  fi

  if pacman_installed virt-manager; then
    run "sudo usermod -aG libvirt,kvm '$USER'"
    run "sudo systemctl enable --now libvirtd"
    $DRY_RUN || sudo virsh net-autostart default &>/dev/null || true
    warn "Group change (libvirt, kvm): takes effect on next login."
  fi

  # --- Neovim ---
  # Omarchy ships omarchy-nvim, which is LazyVim already configured. The Arch
  # version of this script moved ~/.config/nvim aside and cloned the upstream
  # starter over it -- that quietly discards Omarchy's config. Leave it alone.
  if [ -f "$HOME/.config/nvim/lazyvim.json" ] || pacman_installed omarchy-nvim; then
    ok "LazyVim already present (Omarchy's omarchy-nvim) — left untouched."
  elif has_cmd nvim; then
    warn "No LazyVim config found. Install Omarchy's with: omarchy-pkg-add omarchy-nvim"
  fi

  # --- Shell ---
  # Omarchy is a bash desktop: its prompt, aliases and shell integration all
  # live in bash. Switching to zsh is opt-in.
  if [[ $SETUP_ZSH == 1 ]] && has_cmd zsh; then
    append_once 'eval "$(starship init zsh)"' "$HOME/.zshrc"
    append_once 'eval "$(zoxide init zsh)"' "$HOME/.zshrc"
    if [ "$SHELL" != "$(command -v zsh)" ]; then
      run "chsh -s $(command -v zsh) $USER"
      warn "Shell changed to zsh — takes effect on next login."
      warn "Omarchy's own shell config is bash-only; you are on your own there."
    fi
  else
    ok "Keeping bash (Omarchy's default). Re-run with SETUP_ZSH=1 to switch."
  fi

  # starship, zoxide and fzf keybindings are already wired into Omarchy's bash
  # config, so nothing is appended to .bashrc here.

  # --- Clipboard aliases ---
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    append_once 'alias pbcopy="wl-copy"' "$rc"
    append_once 'alias pbpaste="wl-paste"' "$rc"
  done

  has_cmd fc-cache && run "fc-cache -f"

  ok "Post-install configuration complete."
}

# =============================================================================
# ── MAIN ──────────────────────────────────────────────────────────────────────
# =============================================================================

log "${BOLD}omarchy_system_setup.sh${R}  •  $(date)"
log "Log: $LOG"
$DRY_RUN && warn "DRY-RUN — nothing will be changed."

# --- Sanity checks ---
if [[ $EUID -eq 0 ]]; then
  echo "Do not run this as root — it uses sudo where it needs to, and installs" >&2
  echo "into your own \$HOME." >&2
  exit 1
fi

has_cmd pacman || {
  echo "Not an Arch-based system. Aborting." >&2
  exit 1
}

if ! grep -q '^ID=omarchy' /etc/os-release 2>/dev/null &&
  [[ ! -d ${OMARCHY_PATH:-/usr/share/omarchy} ]] &&
  ! has_cmd omarchy-pkg-add; then
  warn "This does not look like an Omarchy install."
  warn "Omarchy-specific steps (NVIDIA UKI rebuild, omarchy-* installers) will"
  warn "fall back or be skipped."
fi

$DRY_RUN || sudo -v || {
  echo "sudo required. Aborting." >&2
  exit 1
}

# Keep the sudo timestamp warm through the long installs.
if ! $DRY_RUN; then
  while true; do
    sudo -n true 2>/dev/null || true
    sleep 60
    kill -0 "$$" 2>/dev/null || exit 0
  done &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
fi

# =============================================================================
section "Base prerequisites"
# =============================================================================

# [multilib] — needed for Steam, Wine and every lib32-* package.
# Omarchy enables it out of the box, so this is a check, not a rewrite.
if pacman-conf --repo-list 2>/dev/null | grep -qx multilib; then
  ok "[multilib] already enabled."
else
  info "Enabling [multilib] in /etc/pacman.conf..."
  run "sudo cp /etc/pacman.conf /etc/pacman.conf.bak.\$(date +%Y%m%d%H%M%S)"
  run "sudo sed -i '/^#\[multilib\]$/{s/^#//;n;s/^#Include/Include/}' /etc/pacman.conf"
  run "sudo pacman -Sy --noconfirm"
fi

info "Updating package database..."
run "sudo pacman -Sy --noconfirm"

# yay is Omarchy's AUR helper and ships with the system.
if ! has_cmd yay; then
  warn "yay not found — AUR packages will be skipped."
fi

# =============================================================================
setup_nvidia
# =============================================================================

# =============================================================================
section "pacman packages — ${#PACMAN_PKGS[@]} queued"
# =============================================================================
print_list "${PACMAN_PKGS[@]}"
log
install_with_progress repo "${PACMAN_PKGS[@]}"
ok "pacman installs done."

# =============================================================================
if ((${#AUR_PKGS[@]} > 0)); then
  section "AUR packages — ${#AUR_PKGS[@]} queued"
  print_list "${AUR_PKGS[@]}"
  log
  install_with_progress aur "${AUR_PKGS[@]}"
  ok "AUR installs done."
fi

# =============================================================================
if ((${#OMARCHY_APPS[@]} > 0)); then
  section "Omarchy apps — ${#OMARCHY_APPS[@]} queued"
  print_list "${OMARCHY_APPS[@]}"
  log
  for app in "${OMARCHY_APPS[@]}"; do
    installer="omarchy-install-$app"
    log
    log "  ${C}${installer}${R}"
    if ! has_cmd "$installer"; then
      warn "$installer not available on this system — skipping."
      note_failure "omarchy $app"
      continue
    fi
    # These installers open the app when they finish. The launch is detached
    # (setsid + backgrounded), so it neither blocks this loop nor fails the
    # install when there is no graphical session to launch into.
    run "$installer </dev/null" ||
      { warn "Failed: $installer"; note_failure "omarchy $app"; }
  done
  ok "Omarchy app installs done."
fi

# =============================================================================
if ((${#FLATPAK_APPS[@]} > 0)); then
  section "Flatpak apps — ${#FLATPAK_APPS[@]} queued"
  if ! has_cmd flatpak; then
    info "Installing Flatpak..."
    pkg_add_one flatpak || note_failure "pkg flatpak"
    run "flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
  fi
  print_list "${FLATPAK_APPS[@]}"
  for app in "${FLATPAK_APPS[@]}"; do
    log "  ${C}${app}${R}"
    run "flatpak install --or-update -y flathub '$app'" ||
      { warn "Failed: $app"; note_failure "flatpak $app"; }
  done
  ok "Flatpak installs done."
else
  section "Flatpak"
  ok "FLATPAK_APPS is empty — Flatpak not installed (everything has a native package)."
fi

post_install

# =============================================================================
section "Verifying"
# =============================================================================

check() {
  local label=$1 ok_flag=$2 detail=${3:-}
  if [[ $ok_flag == yes ]]; then
    log "  ${G}[ok]${R}   $label"
  else
    log "  ${Y}[todo]${R} $label${detail:+  — $detail}"
  fi
}

if has_nvidia; then
  has_cmd nvidia-smi && nv_drv=yes || nv_drv=no
  { [[ -f /etc/modprobe.d/nvidia.conf ]] && grep -q 'modeset=1' /etc/modprobe.d/nvidia.conf; } && nv_kms=yes || nv_kms=no
  check "NVIDIA driver installed (nvidia-smi present)" "$nv_drv" "needs a reboot"
  check "NVIDIA early KMS configured" "$nv_kms"
fi

id -nG "$USER" | tr ' ' '\n' | grep -qx realtime && rt=yes || rt=no
id -nG "$USER" | tr ' ' '\n' | grep -qx gamemode && gm=yes || gm=no
pacman_installed steam && st=yes || st=no
systemctl is-enabled ufw &>/dev/null && fw=yes || fw=no

check "member of the realtime group" "$rt" "needs a full logout or reboot"
check "member of the gamemode group" "$gm" "needs a full logout or reboot"
check "Steam installed" "$st"
check "UFW enabled" "$fw"

# =============================================================================
section "Done"
# =============================================================================

if ((${#FAILED[@]} > 0)); then
  err "${#FAILED[@]} item(s) did not install:"
  for f in "${FAILED[@]}"; do log "      - $f"; done
  log "  Details are in the log; re-running the script retries only these."
else
  ok "Everything installed cleanly."
fi

log
log "Full log: $LOG"
log
log "Next steps:"
log "  1. ${BOLD}Reboot${R}  (NVIDIA driver, group membership, early KMS)"
log "  2. Run ${BOLD}./omarchy_audio_setup.sh${R}"
log "  3. Snapshots are ${BOLD}snapper${R} + the Limine boot menu — no Timeshift needed"
log "  4. Open ${BOLD}Unity Hub${R} — install your editor version"
log "  5. ${BOLD}nvim${R} is already LazyVim via omarchy-nvim"
