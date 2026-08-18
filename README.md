# Backgrounds

macOS app for things **you** started, not system processes.

- **Running** — user apps and user background processes. Apple / system paths stay hidden.
- **Login jobs** — plists that come back at login. Stop unloads them. Purge deletes the plist.
- **Watches** — leftover Watchman roots.

## Download

[v1.0.0](https://github.com/chinmayrelkar/backgrounds/releases/tag/v1.0.0) — grab `Backgrounds.app.zip`, unzip, move the app to `/Applications`.

First launch: right-click the app → Open. It is ad-hoc signed, so Gatekeeper will complain once.

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
make dump    # print the inventory to the terminal
make test
```
