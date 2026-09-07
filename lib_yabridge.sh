#!/usr/bin/env bash
#
# lib_yabridge.sh -- install yabridge and yabridgectl from upstream's own build
# artifacts. Sourced by omarchy_audio_setup.sh and ni_yabridge_setup.sh so both
# get the same yabridge from the same place.
#
# Not meant to be executed directly:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib_yabridge.sh"
#   install_yabridge_from_upstream
#
# WHY UPSTREAM AND NOT THE AUR
#
# Provenance is the first reason: an AUR PKGBUILD is a third-party recipe, while
# these artifacts are produced by yabridge's own GitHub Actions workflow from the
# commit they are named after.
#
# The second is that on Wine 11 the AUR build cannot succeed at all. Wine's
# Unix-side import libraries (/usr/lib/wine/x86_64-unix/lib*.a) are full of
# references to __wine$func$<dll>$<ordinal>$<name> placeholder symbols that
# winebuild is supposed to resolve while linking. On Arch's wine 11.16 nothing on
# the system defines them (1236 references in libkernel32.a alone, zero
# definitions anywhere) and winebuild only emits thunks for a handful of CRT
# entry points, so linking yabridge-host.exe.so dies with ~200 undefined
# references. Both the 64-bit host and the bitbridge fail, so -Dbitbridge=false
# does not help either.
#
# WHY MASTER AND NOT A RELEASE
#
# The last tagged release (5.1.1, Nov 2024) predates Wine 10 editor embedding and
# breaks on Wine 9.22+, so master is what is wanted -- and master ships only as a
# CI artifact. Upstream repository, for the record:
#
#   https://github.com/robbert-vdh/yabridge
#
# (It is GitHub. There is no GitLab mirror.)

# PINNING, AND WHY IT IS NOT JUST A PIN
#
# YABRIDGE_VERSION pins the exact build, so two machines set up months apart get
# the same yabridge rather than whatever master happened to be that day.
#
# A pin on its own would be a slow-acting bug, though, because GitHub Actions
# artifacts EXPIRE (90 days here). Master builds land roughly three times a
# year -- there were 96 days between the Apr 2026 and Aug 2026 builds -- so a
# pinned artifact reliably outlives its own download link. Observed:
#
#   run 30739764611  b580a9f7  Aug 2026  expires 2026-10-31
#   run 25067934796  48ea9749  Apr 2026  EXPIRED 2026-07-27
#
# There was a stretch in late July 2026 when no master artifact existed at all.
# So the pin is a preference, not a hard requirement:
#
#   1. Already installed at the pinned version?  Do nothing. This is what makes
#      an existing install immune to later expiry -- the common case after the
#      first run is no download at all.
#   2. Otherwise resolve the pin to a concrete workflow run whose artifacts are
#      still live, and install that.
#   3. If the pinned run has expired, fall back to the newest live build and say
#      so loudly, rather than leaving the machine with no yabridge.
#
# A failed download never touches an existing install, so the worst case is
# "you keep what you already had".
#
# Set YABRIDGE_VERSION=latest to always track master HEAD instead.
#
# Both artifacts are resolved from the SAME run. Fetching them independently
# could straddle a new build and pair yabridge with a yabridgectl from a
# different commit.

YABRIDGE_REPO="${YABRIDGE_REPO:-robbert-vdh/yabridge}"
YABRIDGE_WORKFLOW="${YABRIDGE_WORKFLOW:-build}"
YABRIDGE_BRANCH="${YABRIDGE_BRANCH:-master}"
YABRIDGE_NIGHTLY="https://nightly.link/$YABRIDGE_REPO/workflows/$YABRIDGE_WORKFLOW/$YABRIDGE_BRANCH"
YABRIDGE_VERSION="${YABRIDGE_VERSION:-5.1.1-57-gb580a9f7}"
YABRIDGE_LIB_DIR="${YABRIDGE_LIB_DIR:-$HOME/.local/share/yabridge}"
YABRIDGE_BIN_DIR="${YABRIDGE_BIN_DIR:-$HOME/.local/bin}"

# Only define these if the sourcing script has not already.
declare -F warn >/dev/null || warn() { echo "WARNING: $1" >&2; }

# `grep -c`, not `grep -q`: these scripts run under `set -o pipefail`, and a
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

# What is installed right now, as a version string, or nothing.
yabridge_installed_version() {
  local exe=$YABRIDGE_LIB_DIR/yabridge-host.exe banner
  [[ -x $exe ]] || return 1
  # Prints its banner on stderr, and takes a moment because it starts Wine.
  banner="$("$exe" 2>&1 || true)"
  [[ $banner =~ yabridge[[:space:]]host[[:space:]]version[[:space:]]([^[:space:]]+) ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# Resolve <version|latest> to a workflow run that still has BOTH artifacts live.
# Prints "<run_id> <version>". Uses the public API, which needs no login (60
# requests/hour unauthenticated, and this costs a handful).
_yabridge_resolve_run() { # <version|latest>
  python3 - "$YABRIDGE_REPO" "$YABRIDGE_WORKFLOW" "$YABRIDGE_BRANCH" "$1" <<'PY' 2>/dev/null
import json, sys, urllib.request

repo, workflow, branch, want = sys.argv[1:5]
api = "https://api.github.com/repos/%s/actions" % repo


def get(url):
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


try:
    runs = get("%s/workflows/%s.yml/runs?branch=%s&status=success&per_page=15"
               % (api, workflow, branch))["workflow_runs"]
except Exception:
    sys.exit(1)

for run in runs:
    try:
        arts = get("%s/runs/%s/artifacts" % (api, run["id"]))["artifacts"]
    except Exception:
        continue
    # Expired artifacts still appear in the listing; they just cannot be
    # downloaded, so they have to be filtered out here rather than discovered
    # as a 404 later.
    live = {a["name"] for a in arts if not a["expired"]}
    versions = [n[len("yabridge-"):-len(".tar.gz")] for n in live
                if n.startswith("yabridge-") and n.endswith(".tar.gz")]
    for version in versions:
        # Require yabridgectl from this same run, so the two cannot mismatch.
        if "yabridgectl-%s.tar.gz" % version not in live:
            continue
        if want == "latest" or want == version:
            print(run["id"], version)
            sys.exit(0)
sys.exit(1)
PY
}

# Download artifact <name>-<version>.tar.gz from <run> and unpack it into
# <tmpdir>, leaving <tmpdir>/<name>/.
#
# `gh` talks to api.github.com directly, which is the cleanest provenance, but
# GitHub requires a login to download workflow artifacts at all. When gh is
# missing or logged out we fall back to nightly.link, a third-party proxy for
# exactly that endpoint -- it serves the bytes itself rather than redirecting to
# GitHub, so it is trusted infrastructure in the chain. Both routes end at the
# same artifact from the same upstream run.
fetch_yabridge_artifact() { # <name> <version> <run-id> <tmpdir>
  local name=$1 version=$2 run=$3 tmp=$4 tarball="" url

  if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    echo "Fetching '$name' from api.github.com via gh (run $run)"
    gh run download "$run" --repo "$YABRIDGE_REPO" --pattern "$name-$version*" \
      --dir "$tmp/gh" &>/dev/null || true
    # gh unzips artifacts on the way in, so the tarball may already be here.
    tarball="$(find "$tmp" -name "$name-$version.tar.gz" -print -quit 2>/dev/null || true)"
    [[ -n $tarball ]] || warn "gh download did not yield '$name'; using nightly.link"
  fi

  if [[ -z $tarball ]]; then
    url="https://nightly.link/$YABRIDGE_REPO/actions/runs/$run/$name-$version.tar.gz.zip"
    echo "Fetching '$name' from $url"
    curl -fsSL --retry 3 -o "$tmp/$name.zip" "$url" || return 1
    # GitHub wraps the project's own .tar.gz inside the artifact .zip, so this
    # has to be unpacked twice.
    unzip -oq "$tmp/$name.zip" -d "$tmp" || return 1
    tarball="$(find "$tmp" -name "$name-$version.tar.gz" -print -quit 2>/dev/null || true)"
  fi

  [[ -n $tarball ]] || { warn "no '$name' tarball in the downloaded artifact"; return 1; }
  echo "Unpacking $(basename "$tarball")"
  tar xzf "$tarball" -C "$tmp" || return 1
  [[ -d $tmp/$name ]] || { warn "unexpected layout in $(basename "$tarball")"; return 1; }
}

# Install both artifacts from one resolved run. Nothing is copied over an
# existing install until both downloads have succeeded.
_install_yabridge_pair_into() { # <tmpdir> <version> <run-id>
  local tmp=$1 version=$2 run=$3 banner
  fetch_yabridge_artifact yabridge "$version" "$run" "$tmp" || return 1
  fetch_yabridge_artifact yabridgectl "$version" "$run" "$tmp" || return 1

  mkdir -p "$YABRIDGE_LIB_DIR" "$YABRIDGE_BIN_DIR"
  cp -a "$tmp/yabridge/." "$YABRIDGE_LIB_DIR/" || return 1
  install -m755 "$tmp/yabridgectl/yabridgectl" "$YABRIDGE_BIN_DIR/yabridgectl" || return 1
  echo "Installed yabridge to $YABRIDGE_LIB_DIR and yabridgectl to $YABRIDGE_BIN_DIR"

  # Prove the Winelib host actually loads under this Wine before calling it
  # done -- a downloaded binary that cannot start is worth catching here, not
  # in a DAW. Captured rather than piped into `grep -q`, which would SIGPIPE
  # the host and trip pipefail on a yabridge that is in fact working.
  banner="$("$YABRIDGE_LIB_DIR/yabridge-host.exe" 2>&1 || true)"
  if [[ $banner != *"yabridge host version"* ]]; then
    warn "yabridge-host.exe did not report a version; it may not run on this Wine."
    return 1
  fi
  echo "Verified: yabridge-host.exe runs under Wine $(wine --version 2>/dev/null || echo '?')"
  [[ $banner == *"$version"* ]] ||
    warn "installed host reports a different version than the requested $version"
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

# AUR builds of the same software shadow what we install: yabridge-git and
# yabridge-bin drop their libraries in /usr/lib, which yabridgectl prefers over
# ~/.local/share, and /usr/bin precedes ~/.local/bin on the default Arch PATH.
# Remove them rather than leaving a half-shadowed install behind; a fresh
# machine has none of them, so this is a no-op there.
remove_aur_yabridge() {
  local pkgs=() pkg
  for pkg in yabridge-git yabridge-bin yabridgectl-git; do
    pacman -Qq "$pkg" &>/dev/null && pkgs+=("$pkg")
  done
  ((${#pkgs[@]})) || return 0
  echo "Removing AUR yabridge packages that would shadow the upstream build:"
  echo "  ${pkgs[*]}"
  # -Rns also takes the matching -debug packages' orphaned deps with it. If the
  # removal fails the upstream install still lands, it is just outranked, so
  # this warns rather than aborting.
  if sudo pacman -Rns --noconfirm "${pkgs[@]}"; then
    echo "Removed: ${pkgs[*]}"
  else
    warn "Could not remove ${pkgs[*]}. They will take precedence over the"
    warn "upstream build until you remove them:  sudo pacman -Rns ${pkgs[*]}"
  fi
}

# PATH sanity: ~/.local/bin has to be reachable, or yabridgectl is installed and
# invisible. Omarchy puts it on PATH already; a bare Arch login shell may not.
_warn_if_bin_dir_unreachable() {
  case ":$PATH:" in
    *":$YABRIDGE_BIN_DIR:"*) ;;
    *)
      warn "$YABRIDGE_BIN_DIR is not on your PATH, so yabridgectl will not be"
      warn "found. Add it to your shell profile:"
      warn "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
      ;;
  esac
}

# The entry point both scripts call.
install_yabridge_from_upstream() {
  local want=$YABRIDGE_VERSION installed resolved run version
  remove_aur_yabridge

  installed="$(yabridge_installed_version || true)"
  if [[ -n $installed ]]; then
    echo "yabridge currently installed: $installed"
    if [[ $want != latest && $installed == "$want" ]]; then
      echo "Already at the pinned version; nothing to download."
      _warn_if_bin_dir_unreachable
      return 0
    fi
  fi

  if wine_import_libs_broken; then
    echo
    echo "This Wine ($(wine --version 2>/dev/null || echo unknown)) cannot link"
    echo "Winelib binaries, so yabridge cannot be compiled here. Installing"
    echo "upstream's build instead."
  fi

  resolved="$(_yabridge_resolve_run "$want" || true)"
  if [[ -z $resolved && $want != latest ]]; then
    warn "Pinned yabridge $want is not available -- its build artifacts have"
    warn "most likely expired (GitHub keeps them 90 days, and master builds"
    warn "are months apart). Falling back to the newest available build."
    resolved="$(_yabridge_resolve_run latest || true)"
  fi

  if [[ -z $resolved ]]; then
    warn "Could not resolve any yabridge build with live artifacts."
    if [[ -n $installed ]]; then
      warn "Keeping the yabridge you already have ($installed)."
      return 0
    fi
    warn "Install one by hand from:"
    warn "  https://nightly.link/$YABRIDGE_REPO/workflows/$YABRIDGE_WORKFLOW/$YABRIDGE_BRANCH"
    return 1
  fi

  read -r run version <<<"$resolved"
  if [[ $want != latest && $version != "$want" ]]; then
    warn "Installing yabridge $version instead of the pinned $want."
    warn "Update YABRIDGE_VERSION in lib_yabridge.sh to $version to make this"
    warn "the new pin, or set YABRIDGE_VERSION=latest to stop pinning."
  else
    echo "Installing yabridge $version (run $run)"
  fi

  if [[ -n $installed && $installed == "$version" ]]; then
    echo "Already at $version; nothing to download."
    _warn_if_bin_dir_unreachable
    return 0
  fi

  local rc=0
  run_in_tmpdir _install_yabridge_pair_into "$version" "$run" || rc=1
  _warn_if_bin_dir_unreachable
  return "$rc"
}
