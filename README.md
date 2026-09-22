# JetBrains Toolbox 3.8.1 native Wayland patch (Linux)

This patch runs the Linux tar build of JetBrains Toolbox 3.8.1.88030 directly
on Wayland, without X11 or XWayland.

It is useful on Wayland-only systems, when XWayland is intentionally disabled,
or when you want to test Toolbox through JBR's native Wayland AWT toolkit. The
trade-off is that Compose uses the CPU-backed `SwingGraphics` renderer, so some
animations and scrolling may be slower or consume more CPU than the normal Skia
renderer.

## Install

Copy [install-native-wayland.sh](./install-native-wayland.sh) into the fresh
bundle's `bin` directory, then run it from there:

```sh
cd jetbrains-toolbox-3.8.1.88030/bin
chmod +x install-native-wayland.sh
./install-native-wayland.sh
```

The existing desktop entry does not need changing because it launches
`jetbrains-toolbox`, which is now the wrapper.

## What the installer changes

The original Toolbox launcher and Compose JAR are kept as `.vendor` backups.
The installer then makes two targeted changes:

1. It patches `ComposeWindowPanel` so it constructs
   `RenderSettings.SwingGraphics` instead of `RenderSettings.SkiaSurface`.
   This avoids the Skia drawing-surface path that expects X11.
2. It replaces `jetbrains-toolbox` with a small launcher that verifies a Wayland
   socket exists, removes `DISPLAY`, sets `-Dawt.toolkit.name=WLToolkit`, and
   forwards every argument to the backed-up vendor executable.

The installer checks the exact SHA-256 hashes for Toolbox 3.8.1.88030 before it
writes anything. It refuses to patch another release or an already modified
bundle. Toolbox updates may replace the patched files, in which case use an
installer made for the new version rather than bypassing the checksum check.

## Requirements

- A freshly extracted Linux tar bundle of JetBrains Toolbox 3.8.1.88030
- A working Wayland session (`WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` set)
- Standard command-line tools: `sha256sum`, `unzip`, and `grep`
- A full JDK 21, used to compile the embedded ASM bytecode patcher

On Arch Linux, the JDK dependency is provided by `jdk21-openjdk`.

## Roll back

Restore the untouched launcher and JAR with:

```sh
./install-native-wayland.sh --rollback
```

The `.vendor` files remain available after rollback so their original checksums
can still be verified.
