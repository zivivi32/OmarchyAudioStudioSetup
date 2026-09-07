#!/bin/bash
# ---------------------------
# Native Instruments (ni-wine) + yabridge, side by side.
#
# Run this AFTER omarchy_audio_setup.sh. It does three things:
#
#   1. Fixes ni-wine's dead Native Access download URL, and makes that fix
#      survive `pacman -Syu` via a pacman hook.
#   2. Runs `ni setup` (idempotent) and verifies it actually installed
#      something, rather than trusting its exit code.
#   3. Installs yabridge from master and registers the NI prefix with it.
#
# ---------------------------
# WHY THE URL FIX EXISTS
#
# ni-wine 2.1.3 hardcodes
#     https://www.native-instruments.com/fileadmin/downloads/Native-Access_2.exe
# which NI retired: it now 301-redirects to an HTML landing page. ni-wine's
# download() does not check the content type, so it saves ~1MB of HTML as
# "Native-Access_2.exe"; Wine is then handed that HTML with check=False, so the
# failed install passes silently. Setup only notices one step later and dies
# with the misleading message:
#
#     error: NTKDaemon installer not found under .../resources/daemon/win
#
# The daemon is not the problem. Native Access was never installed at all.
# The current URL is on Google Cloud Storage (verified: application/x-msdownload,
# ~186MB, MZ header).
#
# The fix is a one-line sed on a pacman-owned file, so a package upgrade would
# silently revert it and reproduce the same misleading error. That is why it is
# installed as a PostTransaction hook rather than applied once by hand.
#
# ---------------------------
# WHY WINE IS NOT PINNED HERE
#
# omarchy_audio_setup.sh defaults to WINE_STRATEGY=pin, which holds wine-staging
# at 9.21 because the released yabridge (5.1.1, Nov 2024) breaks on Wine 9.22+.
# That pin is incompatible with Native Access: NA2 is an Electron app verified
# working on Wine 11.16, and downgrading Wine underneath it is untested and
# would require rebuilding the prefix (Wine prefixes do not downgrade cleanly).
#
# So this pairing deliberately takes the other branch: keep current Wine, and
# get yabridge from master, which has merged (but not released) Wine 10+ editor
# embedding support. Use WINE_STRATEGY=latest for the audio script to match.
#
# yabridge and yabridgectl come from upstream's own GitHub Actions artifacts
# (github.com/robbert-vdh/yabridge), never from the AUR -- both for provenance
# and because on Wine 11 the AUR build cannot link at all. See the yabridge
# section below for the details.
#
# ---------------------------
# WHY THE PREFIXES STAY SEPARATE
#
# yabridge detects the Wine prefix per plugin, so plugins do NOT all have to
# live in one prefix. Native Access keeps its own prefix (~/.wine-ni) and
# yabridgectl is simply pointed at it. That keeps `ni setup`'s wineboot,
# winetricks and registry tweaks out of your plugin prefix, while NI plugins
# still bridge into your DAW normally.
#
# What actually has to match is the Wine VERSION, not the prefix: yabridge
# hosts every plugin with the system `wine`, whichever prefix it came from.
# ---------------------------
# NOTE: Run it with:
#   chmod +x ni_yabridge_setup.sh && ./ni_yabridge_setup.sh
# ---------------------------

set -eEuo pipefail

notify() {
  echo
  echo "--------------------------------------------------------------------"
  echo "$1"
  echo "--------------------------------------------------------------------"
}

warn() { echo "WARNING: $1" >&2; }

# The retired URL and its replacement. Kept as constants because both the
# live patch and the pacman hook below have to agree on them exactly.
NA_URL_OLD='https://www.native-instruments.com/fileadmin/downloads/Native-Access_2.exe'
NA_URL_NEW='https://storage.googleapis.com/ni-assets/downloads/Native-Access_2.exe'

URL_FIX_BIN=/usr/local/bin/ni-wine-url-fix
URL_FIX_HOOK=/etc/pacman.d/hooks/95-ni-wine-url-fix.hook

# ------------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  echo "Do not run this script as root -- it uses sudo where it needs to," >&2
  echo "and the Wine prefix and yabridge config live in your own \$HOME." >&2
  exit 1
fi

if ! command -v pacman &>/dev/null; then
  echo "This script targets Omarchy/Arch. No pacman found." >&2
  exit 1
fi

on_error() {
  local rc=$1 line=$2 cmd=$3 i
  echo >&2
  echo "--------------------------------------------------------------------" >&2
  echo "FAILED at line $line (exit $rc):" >&2
  echo "  $cmd" >&2
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

sudo -v
while true; do
  sudo -n true 2>/dev/null || true
  sleep 60
  kill -0 "$$" 2>/dev/null || exit 0
done &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

write_system_file() {
  local path=$1
  sudo mkdir -p "$(dirname "$path")"
  sudo tee "$path" >/dev/null
}

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

# Ask ni-wine itself where things live, so NI_WINE_PREFIX and XDG overrides are
# honoured instead of hardcoding ~/.wine-ni.
#
# The expression is interpolated into a double-quoted string, so it must not
# itself contain double quotes -- those would close the string early and Python
# would get a syntax error, which 2>/dev/null would then hide. Build paths by
# appending in the shell instead (see NA_CACHE below).
ni_config() { # ni_config <python expression against `config`>
  python -c "from ni_wine import config; print($1)" 2>/dev/null || true
}

# ------------------------------------------------------------------------------------
# ni-wine itself
# ------------------------------------------------------------------------------------
notify "ni-wine"

if command -v ni &>/dev/null; then
  echo "ni-wine present: $(ni --version 2>&1)"
else
  echo "ni-wine not installed; pulling it from the AUR."
  aur_add ni-wine || {
    warn "Could not install ni-wine. Install it by hand and re-run:"
    warn "  https://github.com/selimbucher/native-instruments"
    exit 1
  }
fi

# ------------------------------------------------------------------------------------
# Native Access download URL fix
# ------------------------------------------------------------------------------------
notify "Native Access download URL fix"

# Confirm the replacement URL still serves a binary before baking it into a
# pacman hook. If NI moves it again this is the check that tells you, instead of
# the setup failing later with the misleading NTKDaemon message.
na_content_type() {
  curl -fsSLI --max-time 25 "$1" 2>/dev/null |
    tr -d '\r' | awk 'tolower($1)=="content-type:"{ct=$2} END{print ct}'
}

NA_CT="$(na_content_type "$NA_URL_NEW" || true)"
case "$NA_CT" in
  application/x-msdownload* | application/octet-stream* | binary/octet-stream*)
    echo "Replacement URL serves a binary ($NA_CT) -- good."
    ;;
  text/html*)
    warn "The replacement URL now serves HTML ($NA_CT), not an installer."
    warn "NI has moved the download again. Find the current .exe link on"
    warn "https://www.native-instruments.com/pages/native-access and update"
    warn "NA_URL_NEW at the top of this script."
    ;;
  "")
    warn "Could not reach $NA_URL_NEW (offline?). Applying the fix anyway."
    ;;
  *)
    warn "Unexpected content type for the installer URL: $NA_CT"
    ;;
esac

# The patcher. Globs over python3* so a Python upgrade (which moves
# site-packages to a new directory) does not quietly strand the fix.
cat <<PATCHER | write_system_file "$URL_FIX_BIN"
#!/bin/bash
# Re-apply the Native Access download URL fix to ni-wine's config.py.
#
# ni-wine hardcodes a Native Access URL that NI retired; it now redirects to an
# HTML landing page which ni-wine saves as the installer, producing a misleading
# "NTKDaemon installer not found" error. Installed by ni_yabridge_setup.sh and
# re-run automatically after every ni-wine install/upgrade.
set -euo pipefail

OLD='$NA_URL_OLD'
NEW='$NA_URL_NEW'

shopt -s nullglob
for cfg in /usr/lib/python3*/site-packages/ni_wine/config.py; do
  grep -qF "\$NEW" "\$cfg" && continue
  grep -qF "\$OLD" "\$cfg" || continue
  sed -i "s|\$OLD|\$NEW|" "\$cfg"
  echo "ni-wine: patched Native Access download URL in \$cfg"
done
PATCHER
sudo chmod 755 "$URL_FIX_BIN"
echo "Installed $URL_FIX_BIN"

# Without this hook the sed is reverted by the next `pacman -Syu` that touches
# ni-wine, and the same misleading NTKDaemon error comes back with no clue why.
cat <<HOOK | write_system_file "$URL_FIX_HOOK"
# Re-apply the Native Access download URL fix after ni-wine is installed or
# upgraded, since the patch targets a pacman-owned file.
# Installed by ni_yabridge_setup.sh.
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = ni-wine

[Action]
Description = Re-applying the Native Access download URL fix to ni-wine...
When = PostTransaction
Exec = $URL_FIX_BIN
HOOK
echo "Installed $URL_FIX_HOOK"

sudo "$URL_FIX_BIN"

NA_URL_LIVE="$(ni_config 'config.NA_INSTALLER_URL')"
if [[ $NA_URL_LIVE == "$NA_URL_NEW" ]]; then
  echo "ni-wine now resolves: $NA_URL_LIVE"
else
  warn "ni-wine still resolves the installer URL as: ${NA_URL_LIVE:-<unknown>}"
  warn "The patch did not take. Check $URL_FIX_BIN by hand."
fi

# A previous failed run leaves the HTML landing page cached under the installer's
# name. Its mtime is newer than the real installer's Last-Modified, so ni-wine's
# If-Modified-Since check would return 304 and keep the HTML even now that the
# URL is fixed. Drop it.
NA_CACHE_DIR="$(ni_config 'config.cache_dir()')"
NA_CACHE="${NA_CACHE_DIR:+$NA_CACHE_DIR/Native-Access_2.exe}"
if [[ -n $NA_CACHE && -f $NA_CACHE ]] && file -b "$NA_CACHE" | grep -qi 'html'; then
  echo "Removing cached HTML masquerading as the installer: $NA_CACHE"
  rm -f "$NA_CACHE"
fi

# ------------------------------------------------------------------------------------
# ni setup
# ------------------------------------------------------------------------------------
notify "Native Access (ni setup)"

NA_EXE="$(ni_config 'config.na_exe(config.default_prefix())')"
NI_PREFIX="$(ni_config 'config.default_prefix()')"
: "${NI_PREFIX:=$HOME/.wine-ni}"

if [[ -n $NA_EXE && -f $NA_EXE ]]; then
  echo "Native Access already installed at:"
  echo "  $NA_EXE"
  echo "Delete $NI_PREFIX and re-run to rebuild the prefix from scratch."
else
  echo "Running ni setup (downloads ~186MB, then installs under Wine)..."
  ni setup
fi

# Do not trust the exit code: the bug this script exists to fix is precisely a
# setup that reports success while installing nothing. Check the artefacts.
NA_EXE="$(ni_config 'config.na_exe(config.default_prefix())')"
NTK_EXE="$(ni_config 'config.ntk_daemon_exe(config.default_prefix())')"
if [[ -n $NA_EXE && -f $NA_EXE ]]; then
  echo "Verified Native Access:  $NA_EXE"
else
  warn "Native Access is STILL not installed after ni setup."
  warn "Run 'ni doctor' and check the download URL fix above."
fi
if [[ -n $NTK_EXE && -f $NTK_EXE ]]; then
  echo "Verified NTKDaemon:      $NTK_EXE"
else
  warn "NTKDaemon is not installed; Native Access will be slow to start and"
  warn "may reinstall it on every launch. Re-run 'ni setup'."
fi

# ------------------------------------------------------------------------------------
# yabridge (master build)
# ------------------------------------------------------------------------------------
notify "yabridge"

# yabridge is taken from upstream's own build artifacts -- never from the AUR.
#
# Provenance is the first reason: an AUR PKGBUILD is a third-party recipe, while
# these artifacts are produced by yabridge's own GitHub Actions workflow from the
# commit they are named after.
#
# The second reason is that on Wine 11 the AUR build cannot succeed at all. Wine's
# Unix-side import libraries (/usr/lib/wine/x86_64-unix/lib*.a) are full of
# references to __wine$func$<dll>$<ordinal>$<name> placeholder symbols that
# winebuild is supposed to resolve while linking. On Arch's wine 11.16 nothing on
# the system defines them (1236 references in libkernel32.a alone, zero
# definitions anywhere) and winebuild only emits thunks for a handful of CRT entry
# points, so linking yabridge-host.exe.so dies with ~200 undefined references.
# Both the 64-bit host and the bitbridge fail, so -Dbitbridge=false does not help.
#
# The last tagged release (5.1.1, Nov 2024) predates Wine 10 editor embedding and
# breaks on Wine 9.22+, so master is what we want, and master ships only as a CI
# artifact. Upstream repository, for the record:
#
#   https://github.com/robbert-vdh/yabridge
#
# (It is GitHub, not GitLab -- there is no GitLab mirror.)
YABRIDGE_REPO=robbert-vdh/yabridge
YABRIDGE_WORKFLOW=build
YABRIDGE_BRANCH=master
YABRIDGE_NIGHTLY="https://nightly.link/$YABRIDGE_REPO/workflows/$YABRIDGE_WORKFLOW/$YABRIDGE_BRANCH"

WINE_VER="$(wine --version 2>/dev/null | sed 's/^wine-//; s/ .*//' || true)"
echo "Wine version in use: ${WINE_VER:-unknown}"

# Same check, made runtime rather than assumed, so this script keeps working on a
# machine whose Wine can still link Winelib binaries.
#
# `grep -c`, not `grep -q`: this script runs under `set -o pipefail`, and a
# `grep -q` that exits on its first match SIGPIPEs the `nm` feeding it, which
# pipefail then reports as a failed pipeline (exit 141). Counting reads all of
# the input, so the exit status means what it looks like it means.
wine_import_libs_broken() {
  local dir=/usr/lib/wine/x86_64-unix refs defs
  [[ -f $dir/libkernel32.a ]] || return 1
  refs="$(nm -u "$dir/libkernel32.a" 2>/dev/null | grep -cF '__wine$func$' || true)"
  ((${refs:-0} > 0)) || return 1
  # Broken only if nothing anywhere actually defines what they reference.
  defs="$(nm -A --defined-only "$dir"/*.a 2>/dev/null | grep -cF '__wine$func$' || true)"
  ((${defs:-0} == 0))
}

# Fetch artifact <name> ("yabridge" or "yabridgectl") from upstream's most recent
# successful master build and unpack it into <tmpdir>, leaving <tmpdir>/<name>/.
#
# `gh` talks to api.github.com directly, which is the cleanest provenance, but
# GitHub requires a login to download workflow artifacts at all. When gh is
# missing or logged out we fall back to nightly.link, a third-party proxy for
# exactly that endpoint -- it serves the bytes itself rather than redirecting to
# GitHub, so it is trusted infrastructure in the chain. Both routes end at the
# same artifact from the same upstream workflow run.
fetch_yabridge_artifact() { # <name> <tmpdir>
  local name=$1 tmp=$2 url="" run="" tarball=""

  if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    echo "Fetching '$name' from api.github.com via gh ($YABRIDGE_REPO@$YABRIDGE_BRANCH)"
    run="$(gh run list --repo "$YABRIDGE_REPO" --workflow "$YABRIDGE_WORKFLOW" \
      --branch "$YABRIDGE_BRANCH" --status success --limit 1 \
      --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
    if [[ -n $run ]]; then
      gh run download "$run" --repo "$YABRIDGE_REPO" --pattern "$name-*" \
        --dir "$tmp/gh" &>/dev/null || true
    else
      warn "could not resolve a successful $YABRIDGE_BRANCH run via gh"
    fi
    # gh unzips artifacts on the way in, so the tarball may already be here.
    tarball="$(find "$tmp" -name "$name-*.tar.gz" -print -quit 2>/dev/null || true)"
    [[ -n $tarball ]] || warn "gh download did not yield '$name'; using nightly.link"
  fi

  if [[ -z $tarball ]]; then
    url="$(curl -fsSL "$YABRIDGE_NIGHTLY" 2>/dev/null |
      grep -oE "https://[^\"]*/$name-[^\"]*\.tar\.gz\.zip" | head -n1 || true)"
    if [[ -z $url ]]; then
      warn "No '$name' artifact found at $YABRIDGE_NIGHTLY"
      return 1
    fi
    echo "Fetching '$name' from $url"
    curl -fsSL -o "$tmp/$name.zip" "$url" || return 1
    # GitHub wraps the project's own .tar.gz inside the artifact .zip, so this
    # has to be unpacked twice.
    unzip -oq "$tmp/$name.zip" -d "$tmp" || return 1
    tarball="$(find "$tmp" -name "$name-*.tar.gz" -print -quit 2>/dev/null || true)"
  fi

  [[ -n $tarball ]] || { warn "no '$name' tarball in the downloaded artifact"; return 1; }
  echo "Unpacking $(basename "$tarball")"
  tar xzf "$tarball" -C "$tmp" || return 1
  [[ -d $tmp/$name ]] || { warn "unexpected layout in $(basename "$tarball")"; return 1; }
}

_install_yabridge_into() { # <tmpdir>
  local tmp=$1
  fetch_yabridge_artifact yabridge "$tmp" || return 1
  mkdir -p "$HOME/.local/share/yabridge"
  cp -a "$tmp/yabridge/." "$HOME/.local/share/yabridge/" || return 1
  echo "Installed yabridge to ~/.local/share/yabridge"
  # Prove the Winelib host actually loads under this Wine before moving on -- a
  # downloaded binary that cannot start is worth catching here, not in a DAW.
  # It prints its banner on stderr, hence the redirect. Captured into a variable
  # rather than piped into `grep -q`, which would SIGPIPE the host and trip
  # pipefail, failing this check on a yabridge that is in fact working.
  local banner
  banner="$("$HOME/.local/share/yabridge/yabridge-host.exe" 2>&1 || true)"
  if [[ $banner == *"yabridge host version"* ]]; then
    echo "Verified: yabridge-host.exe runs under Wine ${WINE_VER:-unknown}"
  else
    warn "yabridge-host.exe did not report a version; it may not run on this Wine."
    return 1
  fi
}

_install_yabridgectl_into() { # <tmpdir>
  local tmp=$1
  fetch_yabridge_artifact yabridgectl "$tmp" || return 1
  mkdir -p "$HOME/.local/bin"
  install -m755 "$tmp/yabridgectl/yabridgectl" "$HOME/.local/bin/yabridgectl" || return 1
  echo "Installed yabridgectl to ~/.local/bin"
}

# mktemp + cleanup wrapper, so every early `return 1` above still tidies up.
run_in_tmpdir() { # <function> [args...]
  local fn=$1 tmp rc=0
  shift
  tmp="$(mktemp -d)" || return 1
  "$fn" "$tmp" "$@" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# AUR builds of the same software would shadow what we install: yabridge-git and
# yabridge-bin drop their libraries in /usr/lib, which yabridgectl prefers over
# ~/.local/share, and /usr/bin precedes ~/.local/bin on the default Arch PATH.
aur_pkgs=()
for pkg in yabridge-git yabridge-bin yabridgectl-git; do
  pacman -Qq "$pkg" &>/dev/null && aur_pkgs+=("$pkg")
done
if ((${#aur_pkgs[@]})); then
  warn "AUR builds of yabridge are installed: ${aur_pkgs[*]}"
  warn "They take precedence over the upstream binaries this script installs"
  warn "(/usr/lib over ~/.local/share, and /usr/bin before ~/.local/bin)."
  warn "Remove them so the upstream build is the one that gets used:"
  warn "  sudo pacman -Rns ${aur_pkgs[*]}"
fi

if wine_import_libs_broken; then
  echo
  echo "This Wine (${WINE_VER:-unknown}) cannot link Winelib binaries, so yabridge"
  echo "cannot be compiled here. Installing upstream's build of the same commit."
fi

run_in_tmpdir _install_yabridge_into ||
  warn "yabridge install failed; see the notes at the end."
run_in_tmpdir _install_yabridgectl_into ||
  warn "yabridgectl install failed; see the notes at the end."

# Upstream ships a bitbridge (32-bit plugin support) in the same artifact, but it
# cannot work against Wine's new WoW64 build mode, which is what Arch now ships.
# 64-bit plugins -- including everything current from NI -- are unaffected.
if ! command -v wine64 &>/dev/null; then
  echo
  echo "Note: this Wine is a WoW64 build (no separate wine64 binary), so"
  echo "yabridge's 32-bit bitbridge will not work. Only 32-bit plugins are"
  echo "affected; Kontakt and current NI products are 64-bit. See"
  echo "https://bugs.winehq.org/show_bug.cgi?id=58377"
fi

# ------------------------------------------------------------------------------------
# Register the prefixes with yabridge
# ------------------------------------------------------------------------------------
if command -v yabridgectl &>/dev/null; then
  notify "Registering VST directories with yabridge"

  # The NI prefix is the point of this script. The ~/.wine entries are the ones
  # omarchy_audio_setup.sh creates; they are only registered if that prefix
  # exists, so this script is useful on its own too.
  VST_DIRS=(
    "$NI_PREFIX/drive_c/Program Files/Common Files/VST3"
    "$NI_PREFIX/drive_c/Program Files/Common Files/VST2"
    "$NI_PREFIX/drive_c/Program Files/Steinberg/VstPlugins"
  )
  if [[ -d $HOME/.wine ]]; then
    VST_DIRS+=(
      "$HOME/.wine/drive_c/Program Files/Common Files/VST3"
      "$HOME/.wine/drive_c/Program Files/Common Files/VST2"
      "$HOME/.wine/drive_c/Program Files/Steinberg/VstPlugins"
    )
  else
    echo "No ~/.wine prefix yet -- skipping it."
    echo "Run omarchy_audio_setup.sh if you also want a general plugin prefix."
  fi

  for dir in "${VST_DIRS[@]}"; do
    # yabridgectl refuses paths that do not exist, and Native Access only
    # creates VST3/ once you install your first plugin.
    mkdir -p "$dir"
    if yabridgectl status 2>/dev/null | grep -Fq "$dir"; then
      echo "Already registered: $dir"
    else
      yabridgectl add "$dir"
    fi
  done

  yabridgectl sync || warn "yabridgectl sync failed -- run it by hand once Wine is working."
else
  warn "yabridgectl not on PATH; skipping directory registration."
fi

# ------------------------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------------------------
notify "Verifying"

check() {
  local label=$1 ok=$2 detail=${3:-}
  if [[ $ok == yes ]]; then
    printf '  [ok]   %s\n' "$label"
  else
    printf '  [todo] %s%s\n' "$label" "${detail:+  -- $detail}"
  fi
}

[[ -x $URL_FIX_BIN ]] && fix_ok=yes || fix_ok=no
[[ -f $URL_FIX_HOOK ]] && hook_ok=yes || hook_ok=no
[[ $(ni_config 'config.NA_INSTALLER_URL') == "$NA_URL_NEW" ]] && url_ok=yes || url_ok=no
[[ -n $NA_EXE && -f $NA_EXE ]] && na_ok=yes || na_ok=no
[[ -n $NTK_EXE && -f $NTK_EXE ]] && ntk_ok=yes || ntk_ok=no
command -v yabridgectl &>/dev/null && yab_ok=yes || yab_ok=no
[[ -f $HOME/.local/share/yabridge/libyabridge-chainloader-vst2.so ]] &&
  yablib_ok=yes || yablib_ok=no
# An AUR build in /usr would win over the upstream one we just installed, so
# treat its presence as unfinished business rather than as success.
((${#aur_pkgs[@]} == 0)) && aurfree_ok=yes || aurfree_ok=no

check "URL fix script installed" "$fix_ok"
check "pacman hook installed (survives -Syu)" "$hook_ok"
check "ni-wine resolves the working installer URL" "$url_ok"
check "Native Access installed" "$na_ok" "run 'ni doctor'"
check "NTKDaemon installed" "$ntk_ok" "re-run 'ni setup'"
check "yabridgectl available" "$yab_ok" "download may have failed"
check "yabridge (upstream build) in ~/.local/share" "$yablib_ok" "download may have failed"
check "no AUR yabridge shadowing it" "$aurfree_ok" "sudo pacman -Rns ${aur_pkgs[*]:-}"

notify "Done"
cat <<EOF
Launch Native Access with:   native-access     (or: ni launch)
Then sign in and install your products (Kontakt, etc.).

Every time you install a new NI product, re-run:

  yabridgectl sync

...so the new plugins get bridged. Check what is registered with:

  yabridgectl status
  ni doctor

yabridge here is upstream's own build from github.com/robbert-vdh/yabridge,
not an AUR package. That is partly provenance and partly necessity: on Wine 11
yabridge cannot be compiled at all, because Wine's Unix-side import libraries
reference __wine\$func\$* symbols that nothing on the system defines, so linking
yabridge-host.exe.so fails with ~200 undefined references.

If the download failed, do it by hand:

  https://nightly.link/robbert-vdh/yabridge/workflows/build/master

Extract it twice (GitHub wraps the tarball in a .zip), copy the contents of the
'yabridge' directory into ~/.local/share/yabridge, put the 'yabridgectl' binary
from the other artifact in ~/.local/bin, then run 'yabridgectl sync'.
EOF
