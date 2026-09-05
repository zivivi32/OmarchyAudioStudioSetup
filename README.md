# Pro audio setup for Omarchy

Configures a fresh [Omarchy](https://omarchy.org/) install for pro audio work
on PipeWire: realtime scheduling, low-latency kernel parameters, REAPER, and
Windows VST plugins via Wine + yabridge.

| File | Purpose |
| --- | --- |
| `omarchy_audio_setup.sh` | The Omarchy version. **Use this one.** |
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
- **`yabridge-git` is not installed automatically.** Its AUR PKGBUILD has not
  been touched since 2022, so it is not a safe unattended install even though
  master itself is current.
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
