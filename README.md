# Pro audio setup for Omarchy

Configures a fresh [Omarchy](https://omarchy.org/) install for pro audio work
on PipeWire: realtime scheduling, low-latency kernel parameters, REAPER, and
Windows VST plugins via Wine + yabridge.

| File | Purpose |
| --- | --- |
| `omarchy_audio_setup.sh` | The Omarchy version. **Use this one.** |
| `ni_yabridge_setup.sh` | Native Instruments (Native Access) + yabridge, side by side. |
| `ni_install_libraries.sh` | Mounts NI library `.iso` files and runs their installers. |
| `arch_audio_setup.sh` | The original plain-Arch script, kept for reference. |

## Quick start

```bash
chmod +x omarchy_audio_setup.sh
./omarchy_audio_setup.sh
sudo reboot          # required: kernel params, group membership and limits
```

Run it as your normal user, not as root — it uses `sudo` where it needs to, and
installs REAPER and the Wine prefix into your `$HOME`. The whole script is
idempotent, so re-running it is safe.

## Why a separate Omarchy script

The Arch script does not run on Omarchy. The blocker is the bootloader.

**Omarchy does not use GRUB.** It boots with Limine and a Unified Kernel Image,
so there is no `/etc/default/grub` to `sed` and no `grub-mkconfig` to run. The
original script fails at exactly that step.

On Omarchy, kernel parameters are assembled by `limine-entry-tool` from
drop-ins. This script writes its own file rather than editing Omarchy's:

```bash
# /etc/limine-entry-tool.d/99-pro-audio.conf
KERNEL_CMDLINE[default]+=" threadirqs cpufreq.default_governor=performance"
```

then applies it with `sudo limine-mkinitcpio`. This is the same pattern Omarchy
uses internally for its own hardware quirks. A separate `99-` file means an
Omarchy update can never clobber your settings.

> `limine-mkinitcpio`, not `limine-update`: the latter also re-deploys the
> bootloader binary to the ESP and rebuilds everything a second time for no
> benefit. Omarchy's own code documents this distinction.

Other differences from the Arch script:

- **No PulseAudio prompt.** Omarchy already ships the full PipeWire stack, and
  there is no PulseAudio to remove.
- **No `pacman.conf` rewrite.** `[multilib]` is already enabled on Omarchy, so
  the fragile `tr`/`sed` dance is replaced with a check.
- **`/etc/sysctl.d/`, not `/etc/sysctl.conf`.** The latter does not exist on
  Arch. The `99-` prefix matters: Omarchy already sets `max_user_watches` in a
  `90-` file, so ours has to sort later to win.
- **Packages go through `omarchy-pkg-add` / `omarchy-pkg-aur-add`** when
  available, falling back to `pacman`/`yay`.
- **REAPER is not pinned to a dead URL.** It resolves the current build from
  reaper.fm, with a known-good fallback.

## Wine and yabridge — read this before running

This is the part most likely to waste your afternoon.

The newest yabridge **release** is 5.1.1 (Nov 2024), and
[it does not work with Wine 9.22 or newer](https://github.com/robbert-vdh/yabridge#downgrading-wine).
Arch currently ships `wine-staging` **11.x**. So installing Wine straight from
the repos gives you a yabridge whose plugin editor windows are broken.

The script handles this with a `WINE_STRATEGY` knob:

```bash
./omarchy_audio_setup.sh                        # pin    (default)
WINE_STRATEGY=latest ./omarchy_audio_setup.sh   # latest
```

**`pin`** (default, and upstream's documented recommendation) installs
`wine-staging 9.21-1` from the Arch Linux Archive, holds it with `IgnorePkg`,
and installs the released `yabridge-bin`.

**`latest`** uses current `wine-staging` and deliberately does *not* install
`yabridge-bin` over a build you may have put in place yourself. You must build
yabridge from master, which has merged (but **not released**) Wine 10 editor
embedding support.

Either way the script checks the resulting Wine version with `vercmp` and warns
loudly on a mismatch, so the problem shows up as a message rather than as
mysterious broken windows.

### The pin needs a hook to survive

`IgnorePkg` on its own is not enough on Omarchy. `omarchy refresh pacman` copies
its own template over `/etc/pacman.conf` during an update, which silently wipes
the pin — you get upgraded back to Wine 11 and your plugins break again with no
obvious cause.

So the pin is applied through Omarchy's documented hook, which runs after the
template is written and before `pacman -Syyuu`:

```
~/.config/omarchy/hooks/pre-refresh-pacman.d/10-pin-wine-staging
```

The script writes that hook and then executes that same file to apply the pin
now, so the hook and the live config cannot drift apart.

### Undoing the pin

```bash
rm ~/.config/omarchy/hooks/pre-refresh-pacman.d/10-pin-wine-staging
sudo sed -i '/^IgnorePkg = wine-staging$/d' /etc/pacman.conf   # or edit the line
sudo pacman -Syu
```

## Native Instruments — `ni_yabridge_setup.sh`

Sets up Native Access (via the `ni-wine` AUR package) so it coexists with
yabridge, and registers the NI prefix so NI plugins reach your DAW.

```bash
WINE_STRATEGY=latest ./omarchy_audio_setup.sh
./ni_yabridge_setup.sh
sudo reboot
```

### It forces the `latest` branch, on purpose

Native Access 2 is an Electron app, verified working on Wine 11.x and untested
on 9.21. Pinning would also downgrade Wine underneath a prefix built with a
newer one, and Wine prefixes do not downgrade cleanly.

So the two halves of this repo pull in opposite directions, and NI wins: keep
current Wine, and take yabridge from master instead of the 5.1.1 release.
`omarchy_audio_setup.sh` now **refuses to pin** when `ni-wine` is installed,
rather than silently breaking a working Native Access:

```
ni-wine is installed, and WINE_STRATEGY=pin would downgrade Wine to
9.21-1 underneath your Native Access install.
```

Override with `NI_ACK_WINE_PIN=1` if you really want the pin.

### The prefixes stay separate

yabridge detects the Wine prefix per plugin, so plugins do **not** all have to
live in one prefix — a common misconception. Native Access keeps `~/.wine-ni`
and yabridgectl is simply pointed at it, which keeps `ni setup`'s wineboot,
winetricks and registry tweaks out of your plugin prefix.

What actually has to match is the Wine **version**: yabridge hosts every plugin
with the system `wine`, whichever prefix it came from.

| Prefix | Holds |
| --- | --- |
| `~/.wine-ni` | Native Access, NTKDaemon, NI plugins |
| `~/.wine` | your other Windows VSTs (registered too, if it exists) |

### It patches a bug in ni-wine

`ni-wine` 2.1.3 hardcodes a Native Access download URL that NI retired. It now
301-redirects to an HTML landing page, and `download()` never checks the content
type — so ~1 MB of HTML gets saved as `Native-Access_2.exe`, handed to Wine with
`check=False`, and the failed install passes silently. Setup only notices one
step later and dies with a message pointing at the wrong thing entirely:

```
error: NTKDaemon installer not found under .../resources/daemon/win
```

The daemon is not the problem; Native Access was never installed at all. The
script repoints the URL at NI's current Google Cloud Storage location, verifies
it still serves a binary before applying it, and drops the poisoned cache entry.

Because the patch edits a **pacman-owned file**, a plain `sed` would be reverted
by the next `pacman -Syu` and the same misleading error would come back with no
obvious cause. So it is installed as a hook instead:

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/ni-wine-url-fix` | Re-applies the URL fix; globs `python3*` so a Python upgrade doesn't strand it |
| `/etc/pacman.d/hooks/95-ni-wine-url-fix.hook` | Runs it `PostTransaction` on every `ni-wine` install/upgrade |

This is worth reporting upstream at
[selimbucher/native-instruments](https://github.com/selimbucher/native-instruments) —
the dead URL, plus the two bugs that turned it into a misleading error (the
unvalidated download content type, and `check=False` on the installer run).

### Caveats

- **The 32-bit bitbridge will not work.** Arch's Wine is now a WoW64 build with
  no `wine64` binary, which yabridge's bitbridge
  [cannot support](https://bugs.winehq.org/show_bug.cgi?id=58377). Only 32-bit
  plugins are affected; Kontakt and current NI products are 64-bit.
- **yabridge comes from upstream, never the AUR.** Both `yabridge` and
  `yabridgectl` are taken from the build artifacts of
  [robbert-vdh/yabridge](https://github.com/robbert-vdh/yabridge)'s own GitHub
  Actions workflow, landing in `~/.local/share/yabridge` and `~/.local/bin`.
  The script prefers `gh` (straight to `api.github.com`) when you are logged in,
  and otherwise falls back to [nightly.link](https://nightly.link), a
  third-party proxy for GitHub's artifact endpoint — GitHub requires
  authentication to download artifacts at all, and nightly.link serves the bytes
  itself rather than redirecting, so it is trusted infrastructure in that chain.
  Both routes end at the same artifact from the same upstream run.
  The last tagged release (5.1.1, Nov 2024) predates Wine 10 editor embedding
  and breaks on Wine 9.22+, so master is what is wanted, and master ships only
  as a CI artifact.
- **Remove any AUR yabridge first.** `yabridge-git` and `yabridge-bin` install
  into `/usr/lib`, which yabridgectl prefers over `~/.local/share`, and
  `/usr/bin` precedes `~/.local/bin` on the default Arch `PATH` — so an AUR
  build silently wins over the upstream one. The script detects this and prints
  the `pacman -Rns` line; it will not remove packages on your behalf.
- **On Wine 11, yabridge cannot be compiled at all** — the script installs
  upstream's prebuilt binaries instead. Wine's Unix-side import libraries
  (`/usr/lib/wine/x86_64-unix/lib*.a`) are full of references to
  `__wine$func$<dll>$<ordinal>$<name>` placeholder symbols that `winebuild` is
  supposed to resolve at link time. On Arch's `wine 11.16` nothing defines them
  (1236 references in `libkernel32.a` alone, zero definitions anywhere), and
  `winebuild` only emits thunks for a handful of CRT entry points, so linking
  `yabridge-host.exe.so` dies with ~200 `undefined reference to __wine$func$...`
  errors. Both the 64-bit host and the bitbridge fail, so `-Dbitbridge=false`
  does not help. The script detects this and pulls the
  upstream artifact for the *same commit* — linked in yabridge's CI against a
  Wine whose import libraries still work — then verifies `yabridge-host.exe`
  actually starts under the local Wine before continuing.
- **Re-run `yabridgectl sync` after installing any NI product.** New plugins are
  not bridged until you do.

## What it changes

**System files** (each written idempotently; `.bak` copies are timestamped):

| Path | Change |
| --- | --- |
| `/etc/limine-entry-tool.d/99-pro-audio.conf` | `threadirqs`, `cpufreq.default_governor=performance` |
| `/etc/security/limits.d/audio.conf` | `@audio` gets `rtprio 90`, `memlock unlimited` |
| `/etc/sysctl.d/99-pro-audio.conf` | `fs.inotify.max_user_watches=600000` |
| `/etc/ld.so.conf.d/pipewire-jack.conf` | Makes PipeWire's JACK libraries discoverable |
| `/etc/pacman.conf` | `IgnorePkg = wine-staging` (only when `WINE_STRATEGY=pin`) |

**Your account:** added to the `audio` group; portable REAPER at `~/REAPER`;
Wine prefix and VST directories under `~/.wine`; the pacman hook above.

**Packages:** `pipewire{,-alsa,-jack,-pulse}`, `wireplumber`, `alsa-utils`,
`helvum`, `ardour`, `wine-staging`, `winetricks`, `yabridge-bin`.

## Verifying after reboot

```bash
cat /proc/cmdline                 # should contain threadirqs
ulimit -r -l                      # rtprio 90, memlock unlimited
id -nG | tr ' ' '\n' | grep audio # you are in the audio group
wine --version                    # 9.21 if pinned for yabridge
yabridgectl status                # reports Wine/yabridge version mismatches
pw-top                            # live graph; watch the ERR column for xruns
```

Then run `alsamixer` to raise the base level of your sound card.

## Installing Windows VST plugins

Run the plugin's `.exe` installer under Wine and point it at one of these:

- VST2 → `C:\Program Files\Steinberg\VstPlugins` or `C:\Program Files\Common Files\VST2`
- VST3 → `C:\Program Files\Common Files\VST3`

Then re-run `yabridgectl sync`. You need to do this after every new plugin.

## Known caveats

- **The CPU governor may not stick.** Omarchy runs `power-profiles-daemon`,
  which manages the governor at runtime and can override the boot default. Use
  `powerprofilesctl set performance` for a session if you see it drop back.
- **Pinning a Nov-2024 Wine onto current Arch can hit dependency drift.** If
  `pacman -U` fails, the script says so and prints the fallbacks rather than
  dying silently.
- **No AUR yabridge package is used by either script.** `yabridge-git` is
  maintained by yabridge's own author and does build master HEAD (the 2022
  `pkgver` on the AUR page is just a stale cached value, recomputed from
  `git describe` at build time) — but on Wine 11 it cannot link, and upstream's
  own artifacts are the more direct source regardless. If you have
  `yabridge-git`, `yabridge-bin` or `yabridgectl-git` installed, remove them so
  they stop shadowing the upstream build.
- **`WINE_STRATEGY=latest` may be rough on Wayland.** yabridge
  [issue #488](https://github.com/robbert-vdh/yabridge/issues/488) reports a
  VST3 editor crash on close under Wine 11.12 on Wayland, and Omarchy is
  Hyprland.
- **Realtime limits use the `@audio` group.** Arch also ships a
  `realtime-privileges` package that does the same thing against a `realtime`
  group; yabridge's docs accept either. This script uses `@audio` to match the
  original.

## Credit

Ported from [tuxaudio/linux-audio-setup-scripts](https://github.com/tuxaudio/linux-audio-setup-scripts).
