# flac2watch 🎵→⌚

Drop your music in a folder — it lands on your **Galaxy Watch / Wear OS** watch
automatically. No Bluetooth, no Galaxy Wearable, no one‑song‑at‑a‑time misery.

The official way to put your own music on a Galaxy Watch (Bluetooth sync via the
Galaxy Wearable app) is slow and constantly aborts. `flac2watch` does it over
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
- 🖱️ **Drag & drop app** to add music; or just drop files in the folder in Finder

## Requirements

- macOS with [Homebrew](https://brew.sh)
- `brew install ffmpeg`
- `brew install --cask android-platform-tools` (gives you `adb`)
- A Wear OS watch (built/tested on a **Galaxy Watch 8, SM‑L320**)

## Install

```sh
git clone https://github.com/LordHayne/flac2watch.git
cd flac2watch
./install.sh
```

This installs the `flac2watch` CLI, builds the **FLAC2Watch** drag‑and‑drop app
into `~/Applications`, and loads the auto‑sync agent.

## First‑time setup (pair the watch)

On the **watch**:

1. Settings → About watch → Software information → tap **Software version** 7×
2. Settings → **Developer options** → enable **ADB debugging** + **Wireless debugging**
3. Put the watch on the **same Wi‑Fi** as your Mac
4. Wireless debugging → **Pair new device** (shows `IP:Port` + a 6‑digit code)

Then on the Mac:

```sh
flac2watch pair        # enter the IP:Port and code shown on the watch
```

Pairing is **one‑time** — the Mac remembers the watch and reconnects on its own.

## Use

Just put music into **`~/Music/WatchSync`** (drag onto the **FLAC2Watch** app, or
copy in Finder). The auto‑sync agent pushes it whenever the watch is reachable.

Manual control:

```sh
flac2watch sync        # convert + push everything missing, now
flac2watch status      # library + watch song counts, reachability
flac2watch player      # open the music‑player app page on the watch
flac2watch doctor      # check requirements & connection
flac2watch open        # reveal the music folder in Finder
```

## A watch needs a player app

Galaxy Watch ships **without** a local music player. Install
**“Music for Galaxy Watch”** (`com.samsung.android.wearable.music`) from the
Play Store on the watch — `flac2watch player` opens it for you. It then plays
everything `flac2watch` pushed. Pair Bluetooth earbuds and the phone can stay home.

## Honest limitations (Wear OS, not us)

- The watch must have **Wireless debugging on** and be on the **same Wi‑Fi**.
- After a **watch reboot**, wireless debugging turns itself off — re‑enable it in
  Developer options. No need to pair again; sync resumes automatically.

## Uninstall

```sh
launchctl unload ~/Library/LaunchAgents/com.lordhayne.flac2watch.plist
rm ~/Library/LaunchAgents/com.lordhayne.flac2watch.plist
rm ~/.local/bin/flac2watch /opt/homebrew/bin/flac2watch 2>/dev/null
rm -rf ~/Applications/FLAC2Watch.app ~/.config/flac2watch ~/.cache/flac2watch
```

## License

MIT
