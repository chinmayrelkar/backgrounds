# Backgrounds

macOS app for things **you** started, not system processes.

- **Running** — user apps and user background processes. Apple / system paths stay hidden.
- **Login jobs** — plists that come back at login. Stop unloads them. Purge deletes the plist.
- **Watches** — leftover Watchman roots.

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
