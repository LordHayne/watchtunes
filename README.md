# watchtunes 🎵→⌚

Drop your music in a folder — it lands on your **Galaxy Watch / Wear OS** watch
automatically. No Bluetooth, no Galaxy Wearable, no one‑song‑at‑a‑time misery.

The official way to put your own music on a Galaxy Watch (Bluetooth sync via the
Galaxy Wearable app) is slow and constantly aborts. `watchtunes` does it over
**Wi‑Fi with `adb`** instead: it converts FLAC to MP3, finds the watch on your
network, pushes everything that's missing, and triggers the media scan — all in
the background.

## What it does

- 🎚️ **Converts** FLAC → MP3 320 kbps, **44.1 kHz stereo**; keeps tags but **strips
  embedded cover art** (oversized covers + mixed sample rates make some lightweight
  Wear OS players play tracks at the wrong speed). MP3 input is cover‑stripped losslessly.
- ⌚ **Finds** the watch automatically over Wi‑Fi (mDNS) — pair once, then hands‑off
- ♻️ **Auto‑syncs** a music folder via a `launchd` agent (on change + every 5 min)
- 🗑️ **Mirrors** deletions (remove a song locally → it leaves the watch too)
- 🖥️ **Companion app** (native SwiftUI, dark Liquid-Glass UI) — watch status,
  song counts, pending badge, battery & free storage, drag & drop, one‑click
  sync with progress bar, song list with delete, settings, pairing dialog
- 📍 **Menu bar companion** — watch status + pending count in the menu bar,
  sync from anywhere; closing the window keeps it running

## Requirements

- macOS with [Homebrew](https://brew.sh)
- `brew install ffmpeg`
- `brew install --cask android-platform-tools` (gives you `adb`)
- Xcode Command Line Tools (`xcode-select --install`) — already there if Homebrew works
- A Wear OS watch (built/tested on a **Galaxy Watch 8, SM‑L320**)

## Install

```sh
git clone https://github.com/LordHayne/watchtunes.git
cd watchtunes
./install.sh
```

This installs the `watchtunes` CLI, builds the **WatchTunes** app into
`~/Applications`, and loads the auto‑sync agent.

## First‑time setup (pair the watch)

On the **watch**:

1. Settings → About watch → Software information → tap **Software version** 7×
2. Settings → **Developer options** → enable **ADB debugging** + **Wireless debugging**
3. Put the watch on the **same Wi‑Fi** as your Mac
4. Wireless debugging → **Pair new device** (shows `IP:Port` + a 6‑digit code)

Then on the Mac:

```sh
watchtunes pair        # enter the IP:Port and code shown on the watch
```

…or open the **WatchTunes** app and click **Uhr koppeln** — same thing, with
text fields instead of a terminal.

Pairing is **one‑time** — the Mac remembers the watch and reconnects on its own.

## Use

Just put music into **`~/Music/WatchSync`** (drop it into the **WatchTunes** app
window, drag it onto its Dock icon, or copy in Finder). The auto‑sync agent
pushes it whenever the watch is reachable.

The **WatchTunes** app shows whether the watch is reachable, how many songs are
local vs. on the watch, and has a **Jetzt syncen** button when you don't want
to wait for the auto‑sync.

Manual control:

```sh
watchtunes sync        # convert + push everything missing, now
watchtunes status      # library + watch song counts, reachability
watchtunes list        # songs currently on the watch
watchtunes launch      # start the music player on the watch
watchtunes player      # open the player's install page on the watch
watchtunes config set  # bitrate | mirror_delete | library
watchtunes doctor      # check requirements & connection
watchtunes open        # reveal the music folder in Finder
```

## A watch needs a player app

Galaxy Watch ships **without** a local music player. Install
**“Music for Galaxy Watch”** (`com.samsung.android.wearable.music`) from the
Play Store on the watch — `watchtunes player` opens it for you. It then plays
everything `watchtunes` pushed. Pair Bluetooth earbuds and the phone can stay home.

## Honest limitations (Wear OS, not us)

- The watch must have **Wireless debugging on** and be on the **same Wi‑Fi**.
- The watch's Wi‑Fi **naps when its screen is off** — if it shows as unreachable,
  wake the watch (raise wrist / tap the screen) and it reappears within seconds.
- After a **watch reboot**, wireless debugging turns itself off — re‑enable it in
  Developer options. No need to pair again; sync resumes automatically.

## Uninstall

```sh
launchctl unload ~/Library/LaunchAgents/com.lordhayne.watchtunes.plist
rm ~/Library/LaunchAgents/com.lordhayne.watchtunes.plist
rm ~/.local/bin/watchtunes /opt/homebrew/bin/watchtunes 2>/dev/null
rm -rf ~/Applications/WatchTunes.app ~/.config/watchtunes ~/.cache/watchtunes
```

## License

MIT
