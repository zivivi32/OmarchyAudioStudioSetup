#!/usr/bin/env bash
#
# setup_all.sh -- the whole studio setup, in the right order, in one command.
#
# Intended for a fresh Omarchy install:
#
#   ./setup_all.sh
#   sudo reboot
#
# It runs, in this order:
#
#   1. system_setup_arch.sh    base system, NVIDIA drivers, apps      (optional)
#   2. omarchy_audio_setup.sh  PipeWire, realtime limits, kernel params,
#                              REAPER, Wine, yabridge
#   3. ni_yabridge_setup.sh    Native Access + the NI Wine prefix, registered
#                              with yabridge                          (optional)
#
# Order matters. Step 1 installs graphics drivers and rebuilds the UKI; step 2
# adds its own kernel parameters on top; step 3 needs the Wine that step 2
# settled on. Running 3 before 2 would install Native Access against no Wine at
# all.
#
# Options:
#   --no-system     skip step 1 (you have already set the system up)
#   --no-ni         skip step 3 (you do not use Native Instruments)
#   --reboot        reboot at the end instead of just saying to
#   -h, --help      this text
#
# Environment is passed straight through, so the usual knobs still work:
#   WINE_STRATEGY=pin ./setup_all.sh
#   SETUP_ZSH=1 ./setup_all.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

run_system=true
run_ni=true
do_reboot=false

while (($#)); do
  case "$1" in
    --no-system) run_system=false ;;
    --no-ni) run_ni=false ;;
    --reboot) do_reboot=true ;;
    -h | --help)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//; $d'
      exit 0
      ;;
    *)
      echo "Unknown option: $1  (try --help)" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ $EUID -eq 0 ]]; then
  echo "Do not run this as root -- the scripts use sudo where they need to," >&2
  echo "and they install into your own \$HOME." >&2
  exit 1
fi

banner() {
  echo
  echo "===================================================================="
  echo "  $*"
  echo "===================================================================="
}

# Each step is a separate script with its own error handling, so a failure is
# reported with the step name rather than a bare line number from a file the
# reader has to go and find.
step() { # <script> <description>
  local script=$SCRIPT_DIR/$1 desc=$2
  if [[ ! -x $script ]]; then
    if [[ -f $script ]]; then
      chmod +x "$script"
    else
      echo "Missing: $script" >&2
      return 1
    fi
  fi
  banner "$desc"
  if "$script"; then
    return 0
  fi
  echo >&2
  echo "FAILED: $1" >&2
  echo "Nothing after this step ran. All three scripts are idempotent, so fix" >&2
  echo "the cause and re-run setup_all.sh -- completed work is skipped." >&2
  return 1
}

# Take the sudo password once, up front, rather than at three separate points
# spread over a long run.
echo "This installs system packages and needs sudo."
sudo -v

$run_system && step system_setup_arch.sh "1/3  Base system, drivers and apps"
step omarchy_audio_setup.sh "2/3  Audio stack, REAPER, Wine and yabridge"
$run_ni && step ni_yabridge_setup.sh "3/3  Native Instruments"

banner "Done"
cat <<'SUMMARY'
A reboot is required before any of this is actually live: the kernel
parameters, the realtime limits, your new 'audio' group membership and (on
NVIDIA) the graphics driver all only take effect at boot.

After rebooting:

  native-access          sign in and install your NI products
  yabridgectl sync       bridge them -- re-run after every new plugin
  pw-top                 watch the ERR column for xruns

Verify the rest with:

  cat /proc/cmdline | tr ' ' '\n' | grep threadirqs
  ulimit -r -l
  id -nG | tr ' ' '\n' | grep audio
SUMMARY

if $do_reboot; then
  echo
  echo "Rebooting in 10 seconds -- Ctrl-C to cancel."
  sleep 10
  sudo reboot
else
  echo
  echo "Reboot when ready:  sudo reboot"
fi
