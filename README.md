# Terminal Tint

An [Omarchy](https://omarchy.org) shell plugin for telling terminal windows apart.
Give each one its own background tint and matching border, while whatever runs
inside keeps running. That's handy when a handful of coding agents are going at once.

Press a key and a picker shows every terminal with a live preview. Hover a color
to try it on the real window, click to keep it.

## Features

- **Live previews**: every terminal appears as a live thumbnail, on any workspace.
- **Try before you pick**: hovering a swatch tints the actual window. Move away and it goes back.
- **Nothing restarts**: the tint is an `OSC 11` escape sent to the window's pty, so agents, editors and shells keep running.
- **Matching borders**: the Hyprland border takes the same hue (press `B` to turn it off).
- **Fits every theme**: tints are your theme's background with a little of the hue mixed in, so text stays readable on light and dark themes. Switching themes re-derives them.
- **Scriptable**: `terminal-tint red --title Atlas` from a shell, a keybinding or an agent.

## Install

```bash
omarchy plugin add https://github.com/ekkostech/omarchy-terminal-tint.git --enable --yes
omarchy restart shell
```

Then bind a key to open the picker. Add this to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + T", "Terminal Tint", "omarchy-shell shell toggle ekkostech.terminal-tint '{}'")
```

## Using the picker

| Key | Action |
|-----|--------|
| Hover a swatch | Preview it on that terminal |
| Click a swatch | Keep it |
| `1`–`8` | Red, orange, amber, green, teal, blue, purple, pink |
| `0` / `Backspace` | Clear the tint |
| `Space` / `N` | Next color |
| Arrows / `Tab` / `hjkl` | Move between terminals |
| `B` | Borders on/off |
| `Esc` / `Enter` | Close |

The terminal you were in is selected when the picker opens.

## Scripting

`bin/terminal-tint` wraps the plugin's IPC. To use it, link it onto your `PATH`:

```bash
ln -s ~/.config/omarchy/plugins/ekkostech.terminal-tint/bin/terminal-tint ~/.local/bin/
```

```bash
terminal-tint                      # open the picker
terminal-tint red                  # tint the focused terminal
terminal-tint next                 # cycle the focused terminal
terminal-tint blue --title Atlas   # every terminal whose title contains "Atlas"
terminal-tint '#203040' --pid 1234 # any hex color, by terminal pid
terminal-tint reset --all          # clear everything
terminal-tint borders off
terminal-tint --list
```

Under the hood these call
`omarchy-shell shell call ekkostech.terminal-tint apply '{"value":"red","target":"title:Atlas"}'`.
The targets are `focused`, `title:TEXT`, `pid:N`, `address:HEX` and `all`. The
values are a hue name, `#rrggbb`, `next` or `reset`.

## How it works

The plugin lists Hyprland's windows and finds each terminal's pty: the
controlling tty of the window process's children. It then writes
`ESC ] 11 ; #rrggbb ESC \` to that pty. The terminal treats it like any program
output that sets its background color. Clearing sends `OSC 111`, which restores
the configured background. Tints are recorded per pty in
`$XDG_RUNTIME_DIR/terminal-tint/` so the picker can show them. Each record is
tied to the terminal's pid, so a reused pty starts clean. The border setting is
saved in `~/.config/omarchy/terminal-tint.json`.

## Compatibility

- **foot**: tested.
- **Alacritty, Kitty**: should work, since they also run one process per window and support `OSC 11`. Not tested yet.
- **foot `--server` / `footclient`, single-instance Ghostty**: these serve every window from one process, so their windows can't be told apart. They're left out of the picker.
- A program that sets its own background color (a few TUIs do) overrides the tint while it runs.

## Uninstall

```bash
terminal-tint reset --all
omarchy plugin remove ekkostech.terminal-tint
```

## License

MIT
