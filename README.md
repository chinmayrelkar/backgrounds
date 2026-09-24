# Backgrounds

macOS app for things **you** started, plus a live system monitor.

**System**
- **Overview**: CPU total and per core, load, memory breakdown, swap, pressure, disk and network speed, volumes, GPU, battery, uptime. All with rolling graphs.
- **Processes**: every process. Sort any column, tree view, filter, only yours, CPU per core or whole machine. Send any signal, change priority, and see per-process CPU and memory graphs.

**Background**
- **Running**: user apps and user background processes. Apple / system paths stay hidden.
- **Login jobs**: plists that come back at login. Stop unloads them. Disable keeps the plist but stops it loading. Purge deletes the plist. Shows logs and why it last exited.
- **Login items**: apps that open at login (System Settings).
- **Cron**: your crontab. Enable, disable (comment out), remove.
- **Brew services**: start, stop, restart.
- **Containers**: Docker, OrbStack, Podman. Start, stop, restart, remove.
- **Ports**: what is listening, and whether it is open to the network.
- **Extensions**: system extensions (read only).
- **Watches**: leftover Watchman roots.

Also: multi-select, hide list, Reveal in Finder, auto reload, menu bar monitor, and a notification when a new login job shows up.

## Download

[v1.1.0](https://github.com/chinmayrelkar/backgrounds/releases/tag/v1.1.0) — grab `Backgrounds.app.zip`, unzip, move the app to `/Applications`.

First launch: right-click the app → Open. It is ad-hoc signed, so Gatekeeper will complain once.

The first time you open Login items, macOS asks to let Backgrounds control System Events.

## Requirements

macOS 14+, Xcode / Swift 6.

## Build

```
git clone https://github.com/chinmayrelkar/backgrounds.git
cd backgrounds
make run
```

`make run` builds `dist/Backgrounds.app` and opens it.

```
make dump    # print the inventory and a system sample to the terminal
make test
BG_ACTIONS=1 swift test --filter ActionTests   # real start/stop/purge on throwaway targets
```

## Not done yet

These need an Apple Developer account or private APIs:

- Notarization, so Gatekeeper stops warning.
- Auto-update (Sparkle): needs a signing key and a place to host updates.
- A privileged helper, so machine-wide jobs stop asking for a password every time.
- CPU temperature and fan speed: only through private SMC calls.
- "Allow in the background" items from System Settings: `sfltool dumpbtm` needs root.
