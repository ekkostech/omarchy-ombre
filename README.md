# Terminal Tint

An [Omarchy](https://omarchy.org) shell plugin for telling terminal windows apart.
Give each one its own look while whatever runs inside keeps running: a background
tint, an [Aether](https://github.com/bjarneo/aether) mood made from a wallpaper,
or a whole Omarchy theme, plus a matching border. That's handy when a handful of
coding agents are going at once.

Press a key and a picker shows every terminal with a live preview. Hover a color,
mood or theme to try it on the real window, click to keep it.

## Features

- **Live previews**: every terminal appears as a live thumbnail, on any workspace.
- **Try before you pick**: hovering a swatch, mood or theme changes the actual window. Move away and it goes back.
- **Aether moods**: Fire, Ocean, Forest, Neon, Sunset, Vaporwave, Midnight, Aurora and the rest of Aether's modes, generated from your current wallpaper or any wallpaper in Aether's library.
- **Themes per terminal**: give one terminal Tokyo Night and another Gruvbox. Every installed Omarchy theme is listed with its wallpaper, including themes Aether made.
- **Nothing restarts**: looks are escape sequences sent to the window's pty, so agents, editors and shells keep running.
- **Matching borders**: the Hyprland border takes the look's accent color (press `B` to turn it off).
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
| Hover a swatch, mood or theme | Preview it on that terminal |
| Click it | Keep it |
| `1`–`8` | Tint: red, orange, amber, green, teal, blue, purple, pink |
| `0` / `Backspace` | Back to the terminal's own colors |
| `N` | Next tint |
| `Space` / `Shift+Space` | Next / previous mood or theme |
| `Tab` | Switch between Moods and Themes |
| `W` / `Shift+W` | Next / previous wallpaper for moods |
| Arrows / `hjkl` | Move between terminals |
| `B` | Borders on/off |
| `Esc` / `Enter` | Close |

The terminal you were in is selected when the picker opens. The tint dots sit on
each terminal's card; moods and themes apply to the selected terminal.

Moods need Aether (`aether --list-modes` should work). Without it, the Moods tab
is disabled and tints and themes still work.

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
terminal-tint mood:fire --title Atlas
terminal-tint mood:ocean@/path/to/wallpaper.jpg
terminal-tint theme:tokyo-night --pid 1234
terminal-tint --looks              # list moods and themes
terminal-tint borders off
terminal-tint --list
```

Under the hood these call
`omarchy-shell shell call ekkostech.terminal-tint apply '{"value":"red","target":"title:Atlas"}'`.
The targets are `focused`, `title:TEXT`, `pid:N`, `address:HEX` and `all`. The
values are a hue name, `#rrggbb`, `next`, `reset`, `mood:NAME[@WALLPAPER]` or
`theme:NAME`.

## How it works

The plugin lists Hyprland's windows and finds each terminal's pty: the
controlling tty of the window process's children. It then writes standard
escape sequences to that pty, which the terminal treats like any program output
that changes its colors:

- `OSC 11` sets the background (a tint is only this),
- `OSC 4` sets the 16 ANSI colors, `OSC 10` the text and `OSC 12` the cursor,
- `OSC 104`, `110`, `111` and `112` put them back to the terminal's configuration.

Tints mix a hue into your theme's background, and they're re-mixed when you
switch themes. Moods come from `aether --extract-palette WALLPAPER
--extract-mode MODE`. Themes map `colors.toml` onto the 16 colors the same way
Omarchy's foot template does.

Looks are recorded per pty in `$XDG_RUNTIME_DIR/terminal-tint/` so the picker
can show them. Each record is tied to the terminal's pid, so a reused pty starts
clean. The border setting is saved in `~/.config/omarchy/terminal-tint.json`.

## Compatibility

- **foot**: tested.
- **Alacritty, Kitty**: should work, since they also run one process per window and support `OSC 11`. Not tested yet.
- **foot `--server` / `footclient`, single-instance Ghostty**: these serve every window from one process, so their windows can't be told apart. They're left out of the picker.
- A program that sets its own colors (a few TUIs do) overrides the look while it runs.
- Terminals can't show an image behind the text this way, so wallpapers supply colors, not pictures.

## Uninstall

```bash
terminal-tint reset --all
omarchy plugin remove ekkostech.terminal-tint
```

## License

MIT
