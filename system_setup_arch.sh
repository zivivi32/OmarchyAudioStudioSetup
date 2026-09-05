#!/usr/bin/env bash
# =============================================================================
# setup_system.sh  —  CachyOS / Arch minimal system setup
# Gaming · Game Development · Music Production (prep)
#
# HOW TO USE:
#   • Comment out any line in PACMAN_PKGS or AUR_PKGS or FLATPAK_APPS to skip it
#   • Add new packages the same way — pacman name, AUR name, or Flatpak app ID
#   • paru is used for AUR packages (CachyOS default). If missing it will be
#     installed automatically from the AUR using a temporary makepkg build.
#
# ⚠  Run this BEFORE linux_audio_studio_setup.sh
#
# Usage:
#   ./setup_system.sh          # full install
#   ./setup_system.sh -n       # dry-run
# =============================================================================

set -uo pipefail
DRY_RUN=false
[[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]] && DRY_RUN=true

LOG="$HOME/setup_system_$(date +%Y%m%d_%H%M%S).log"
echo "" >"$LOG"

# Colours
if [ -t 1 ]; then
  R='\033[0m' G='\033[32m' Y='\033[33m' RED='\033[31m' C='\033[36m' BOLD='\033[1m'
else R='' G='' Y='' RED='' C='' BOLD=''; fi

log() { echo -e "$*" | tee -a "$LOG"; }
info() { log "${C}  ➜  $*${R}"; }
ok() { log "${G}  ✔  $*${R}"; }
warn() { log "${Y}  ⚠  $*${R}"; }
section() {
  log
  log "${BOLD}── $* ──${R}"
}
run() { $DRY_RUN && log "  [dry-run] $*" || eval "$*" >>"$LOG" 2>&1; }
append_once() {
  touch "$2"
  grep -qxF "$1" "$2" || echo "$1" >>"$2"
}
in_list() {
  local t="$1"
  shift
  for i in "$@"; do [[ "$i" == "$t" ]] && return 0; done
  return 1
}

print_list() {
  local i=1
  for item in "$@"; do
    log "  ${BOLD}$(printf '%3d' $i).${R} $item"
    ((i++))
  done
}

# pacman install — one at a time with [N/total] counter
pacman_install_with_progress() {
  local total=$#
  local i=1
  for pkg in "$@"; do
    log
    log "  ${BOLD}[${i}/${total}]${R} ${C}${pkg}${R}"
    if $DRY_RUN; then
      log "  [dry-run] sudo pacman -S --noconfirm --needed $pkg"
    else
      sudo pacman -S --noconfirm --needed "$pkg" 2>&1 | tee -a "$LOG" ||
        warn "Failed to install $pkg, skipping..."
    fi
    ((i++))
  done
}

# paru (AUR) install — one at a time with [N/total] counter
aur_install_with_progress() {
  local total=$#
  local i=1
  for pkg in "$@"; do
    log
    log "  ${BOLD}[${i}/${total}]${R} ${C}${pkg}${R} ${Y}(AUR)${R}"
    if $DRY_RUN; then
      log "  [dry-run] paru -S --noconfirm --needed $pkg"
    else
      paru -S --noconfirm --needed "$pkg" 2>&1 | tee -a "$LOG" ||
        warn "Failed to install AUR pkg $pkg, skipping..."
    fi
    ((i++))
  done
}

# Flatpak install with [N/total] counter — one app at a time
flatpak_install_with_progress() {
  local total=$#
  local i=1
  for app in "$@"; do
    log
    log "  ${BOLD}[${i}/${total}]${R} ${C}${app}${R}"
    if $DRY_RUN; then
      log "  [dry-run] flatpak install -y flathub $app"
    else
      flatpak install --or-update -y flathub "$app" 2>&1 | tee -a "$LOG" |
        grep --line-buffered -E '(Installing|Updating|Already|Error)' |
        while IFS= read -r line; do echo "    $line"; done
    fi
    ((i++))
  done
}

# =============================================================================
# ── EDIT THESE LISTS ─────────────────────────────────────────────────────────
# =============================================================================

# Official repo packages (pacman)
PACMAN_PKGS=(
  # ── Safety ────────────────────────────────────────────────────────────
  ufw # firewall
  timeshift
  # ── System ────────────────────────────────────────────────────────────
  irqbalance # distributes IRQs across CPU cores
  cpupower   # inspect/set CPU governor manually
  alsa-utils # alsamixer — needed by audio script setup notes

  # ── Build tools ───────────────────────────────────────────────────────
  base-devel # gcc, g++, make, and friends
  cmake
  ninja
  meson
  pkgconf
  python-pip
  python-virtualenv
  jq # JSON in scripts
  openssl
  libffi

  # ── Archives + codecs ─────────────────────────────────────────────────
  p7zip
  unrar
  zip
  unzip
  ffmpeg # implicit dep of many tools and exporters

  # ── Fonts ─────────────────────────────────────────────────────────────
  noto-fonts-emoji # prevents emoji rendering as empty squares
  ttf-jetbrains-mono

  # ── GPU / Vulkan ──────────────────────────────────────────────────────
  # NOTE: NVIDIA users — uncomment the nvidia block, comment out the mesa block
  # NVIDIA:
  nvidia-dkms
  nvidia-utils
  lib32-nvidia-utils
  nvidia-settings
  # Mesa / AMD / Intel:
  #mesa
  #lib32-mesa
  #vulkan-radeon           # AMD — swap for vulkan-intel if on Intel iGPU
  #lib32-vulkan-radeon     # AMD 32-bit — swap for lib32-vulkan-intel if needed
  #vulkan-intel
  #lib32-vulkan-intel
  #mesa-utils
  vulkan-icd-loader
  lib32-vulkan-icd-loader
  vulkan-tools
  vulkan-headers

  # ── Gaming ────────────────────────────────────────────────────────────
  steam
  gamemode       # CPU/IO optimiser while gaming — use: gamemoderun %command%
  lib32-gamemode # 32-bit Steam games need this
  mangohud       # in-game overlay — use: MANGOHUD=1 %command%
  lib32-mangohud # 32-bit support

  # libgl1-mesa-dev / libegl1-mesa-dev equivalents are included in mesa

  # ── Productivity ──────────────────────────────────────────────────────
  poppler   # provides pdfunite and other PDF tools
  qemu-full # replaces qemu-kvm + extras
  libvirt
  virt-manager
  bridge-utils
  virt-install
  vlc

  # ── Neovim ────────────────────────────────────────────────────────────
  neovim  # always up to date in Arch repos — no PPA needed
  ripgrep # LazyVim live grep
  fd      # LazyVim file finder — no rename needed on Arch
  nodejs
  npm
  xclip # system clipboard for Neovim

  # ── Shell + terminal ──────────────────────────────────────────────────
  zsh
  zoxide # smarter cd — learns your directories
  tmux

  # ── CLI utils ─────────────────────────────────────────────────────────
  htop
  btop      # process monitor with GPU support
  fastfetch # system info display
  ncdu      # interactive disk usage
  tree
  duf          # modern df
  bat          # cat with syntax highlighting — no alias needed on Arch
  eza          # modern ls with git info
  fzf          # fuzzy finder + Ctrl+R / Ctrl+T shell keybindings
  wl-clipboard # Wayland clipboard (wl-copy / wl-paste)

  # ── KDE ───────────────────────────────────────────────────────────────
  plasma-systemmonitor # task manager with GPU usage
  spectacle            # screenshot tool
  filelight            # visual disk usage map
  kfind
  #kdeconnect

  # ── Network ───────────────────────────────────────────────────────────
  net-tools # ifconfig, netstat
  mtr       # better traceroute (mtr-tiny on Ubuntu = mtr on Arch)
  nmap
  brave
)

# AUR packages (paru)
AUR_PKGS=(
  #timeshift               # system snapshots — run it before anything else
  realtime-privileges # creates 'realtime' group + rtprio/memlock limits
  unityhub            # Unity game engine launcher
  1password           # password manager
)

FLATPAK_APPS=(
  # ── Gaming ────────────────────────────────────────────────────────────
  com.heroicgameslauncher.hgl # Epic + GOG launcher
  com.discordapp.Discord
  com.usebottles.bottles # Windows apps via Wine (isolated from audio Wine)

  # ── Game dev ──────────────────────────────────────────────────────────
  io.github.MakovWait.Godots # Godot version manager
  org.kde.krita              # 2D painting + texture work

  # ── Productivity ──────────────────────────────────────────────────────
  #com.brave.Browser
  md.obsidian.Obsidian
  org.localsend.localsend_app
  com.github.tchx84.Flatseal # Flatpak permissions manager
  com.spotify.Client
)

# =============================================================================
# ── POST-INSTALL CONFIG ───────────────────────────────────────────────────────
# =============================================================================

post_install() {
  section "Post-install configuration"

  # UFW
  if command -v ufw &>/dev/null; then
    info "Configuring UFW..."
    run "sudo ufw default deny incoming"
    run "sudo ufw default allow outgoing"
    run "sudo ufw allow 1714:1764/udp" # KDE Connect
    run "sudo ufw allow 1714:1764/tcp"
    # LocalSend
    run "sudo ufw allow 53317/tcp"
    run "sudo ufw allow 53317/udp"
    run "sudo ufw --force enable"
    ok "UFW enabled."
  fi

  # Kernel params
  local sysctl_file="/etc/sysctl.d/99-gaming-performance.conf"
  if [ ! -f "$sysctl_file" ]; then
    info "Setting vm.max_map_count (Steam/Proton)..."
    run "echo 'vm.max_map_count=2147483642' | sudo tee '$sysctl_file' > /dev/null"
    run "sudo sysctl -p '$sysctl_file'"
  fi

  # irqbalance
  command -v irqbalance &>/dev/null && run "sudo systemctl enable --now irqbalance"

  # NVIDIA — only if nvidia-dkms was installed
  if pacman_installed nvidia-dkms; then
    warn "NVIDIA: reboot required after first boot to load the driver."
  fi

  # Realtime + audio groups
  if pacman_installed realtime-privileges; then
    run "sudo usermod -aG realtime,audio '$USER'"
    warn "Group change (realtime, audio): takes effect on next login."
  fi

  # GameMode group
  if command -v gamemoded &>/dev/null && getent group gamemode &>/dev/null; then
    run "sudo usermod -aG gamemode '$USER'"
    ok "Added to gamemode group. Steam launch option: gamemoderun %command%"
  fi

  # virt-manager
  if pacman_installed virt-manager; then
    run "sudo usermod -aG libvirt,kvm '$USER'"
    run "sudo systemctl enable --now libvirtd"
    $DRY_RUN || sudo virsh net-autostart default 2>/dev/null || true
    warn "Group change (libvirt, kvm): takes effect on next login."
  fi

  # LazyVim
  if command -v nvim &>/dev/null; then
    local nvim_cfg="$HOME/.config/nvim"
    if [ ! -f "$nvim_cfg/lua/config/lazy.lua" ]; then
      for d in "$nvim_cfg" "$HOME/.local/share/nvim" \
        "$HOME/.local/state/nvim" "$HOME/.cache/nvim"; do
        [ -e "$d" ] && run "mv '$d' '${d}.bak'"
      done
      run "git clone https://github.com/LazyVim/starter '$nvim_cfg'"
      run "rm -rf '$nvim_cfg/.git'"
      ok "LazyVim installed. Run 'nvim' once to bootstrap plugins."
    else
      ok "LazyVim config already present."
    fi
  fi

  # Zsh + Starship + Zoxide
  if command -v zsh &>/dev/null; then
    if ! command -v starship &>/dev/null; then
      run "curl -sS https://starship.rs/install.sh | sh -s -- --yes"
    fi
    append_once 'eval "$(starship init zsh)"' "$HOME/.zshrc"
    append_once 'eval "$(zoxide init zsh)"' "$HOME/.zshrc"
    append_once 'eval "$(zoxide init bash)"' "$HOME/.bashrc"
    if [ "$SHELL" != "$(which zsh)" ]; then
      run "chsh -s $(which zsh) $USER"
      warn "Shell changed to zsh — takes effect on next login."
    fi
  fi

  # Wayland clipboard aliases (bat and fd need no aliases on Arch)
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    append_once 'alias pbcopy="wl-copy"' "$rc"
    append_once 'alias pbpaste="wl-paste"' "$rc"
  done

  # fzf shell keybindings: Ctrl+R, Ctrl+T, Alt+C
  # Arch installs these to /usr/share/fzf/ — different from Ubuntu
  local fzf_kb="/usr/share/fzf/key-bindings.bash"
  local fzf_co="/usr/share/fzf/completion.bash"
  append_once "[ -f $fzf_kb ] && source $fzf_kb" "$HOME/.bashrc"
  append_once "[ -f $fzf_co ] && source $fzf_co" "$HOME/.bashrc"

  # Font cache
  command -v fc-cache &>/dev/null && run "fc-cache -f"

  ok "Post-install configuration complete."
}

# =============================================================================
# ── MAIN ──────────────────────────────────────────────────────────────────────
# =============================================================================

pacman_installed() { pacman -Qi "$1" &>/dev/null; }

log "${BOLD}setup_system.sh${R}  •  CachyOS/Arch  •  $(date)"
log "Log: $LOG"
$DRY_RUN && warn "DRY-RUN — nothing will be changed."

# Sanity checks
command -v pacman &>/dev/null || {
  echo "Not an Arch-based system. Aborting."
  exit 1
}
sudo -v 2>/dev/null || {
  echo "sudo required. Aborting."
  exit 1
}

# =============================================================================
section "Base prerequisites"
# =============================================================================

# Enable multilib (32-bit support) — needed for Steam, Wine, lib32-* packages
PACMAN_CONF="/etc/pacman.conf"
if ! grep -q '^\[multilib\]' "$PACMAN_CONF"; then
  info "Enabling [multilib] in pacman.conf..."
  run "sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' '$PACMAN_CONF'"
  warn "[multilib] enabled — pacman -Sy will refresh the database shortly."
else
  ok "[multilib] already enabled."
fi

info "Updating package database..."
run "sudo pacman -Sy"

# Ensure base tools are present
info "Installing base prerequisites..."
run "sudo pacman -S --noconfirm --needed git curl wget base-devel"

# Flatpak
if ! command -v flatpak &>/dev/null; then
  info "Installing Flatpak..."
  run "sudo pacman -S --noconfirm --needed flatpak"
  run "flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
  warn "Flatpak installed — reboot may be needed before GUI apps show in launcher."
fi

# paru (AUR helper) — CachyOS ships with it; install from AUR if missing
if ! command -v paru &>/dev/null; then
  info "paru not found — installing from AUR..."
  PARU_BUILD=$(mktemp -d)
  run "git clone https://aur.archlinux.org/paru-bin.git '$PARU_BUILD'"
  run "cd '$PARU_BUILD' && makepkg -si --noconfirm"
  run "rm -rf '$PARU_BUILD'"
  command -v paru &>/dev/null && ok "paru installed." || {
    echo "${RED}paru install failed. Aborting.${R}"
    exit 1
  }
fi

# =============================================================================
section "pacman packages — ${#PACMAN_PKGS[@]} queued"
# =============================================================================
print_list "${PACMAN_PKGS[@]}"
log
pacman_install_with_progress "${PACMAN_PKGS[@]}"
ok "pacman installs done."

# =============================================================================
section "AUR packages — ${#AUR_PKGS[@]} queued"
# =============================================================================
print_list "${AUR_PKGS[@]}"
log
aur_install_with_progress "${AUR_PKGS[@]}"
ok "AUR installs done."

# =============================================================================
section "Flatpak apps — ${#FLATPAK_APPS[@]} queued"
# =============================================================================
print_list "${FLATPAK_APPS[@]}"
flatpak_install_with_progress "${FLATPAK_APPS[@]}"
ok "Flatpak installs done."

post_install

section "Done"
log "Full log: $LOG"
log
log "Next steps:"
log "  1. ${BOLD}Reboot${R}"
log "  2. Run ${BOLD}linux_audio_studio_setup.sh${R}"
log "  3. Open ${BOLD}Timeshift${R} — create your first snapshot"
log "  4. Open ${BOLD}Unity Hub${R} — install your editor version"
log "  5. Run ${BOLD}nvim${R} — LazyVim bootstraps on first launch"
