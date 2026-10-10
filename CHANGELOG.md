# Changelog

## 1.4.3 — 2026-10-10
- The picker always displays the installed plugin version beneath the Ombre logo. The label reads the manifest, so it follows future updates automatically.

## 1.4.2 — 2026-10-10
- Borders come back. To put a window's border back to the theme, Ombre sent Hyprland `-1`, which Hyprland 0.56 treats as an empty colour: every terminal without a look lost its focus border and its fade. Ombre now reads the theme's border colours from Hyprland (again after each config reload) and sets those explicitly.

## 1.4.1 — 2026-10-10
- Moods look like moods again on dark themes. Aether keeps every mood's background near black, so on a black Omarchy theme Fire, Ocean and Forest looked the same in plain text. A mood's window background now takes 20% of its accent colour and its text 15%, the way a tint takes a hue: Fire reads warm, Ocean blue, Vaporwave magenta. The ANSI colours are unchanged.

## 1.4.0 — 2026-10-10
- Solid Ghostty windows, on by default: Omarchy's window rule makes every window slightly transparent (0.985 focused, 0.96 not), which let the desktop wallpaper bleed through a terminal's own wallpaper. Ombre now sets Ghostty windows fully opaque, including new ones. `O` in the picker, the "Solid Ghostty" toggle or `ombre solid off` hands them back; each window returns to the exact opacity it had before.

## 1.3.2 — 2026-10-09
- The pulse lets Hyprland tween the border colour on the GPU: two updates per cycle instead of sixteen when Hyprland's `border` animation is on, with the old stepping as a fallback.

## 1.3.1 — 2026-10-09
- Security: per-window Ghostty config files and Ombre's state never fall back to `/tmp`. Without `XDG_RUNTIME_DIR` they go under `~/.local/state/ombre`, created `0700`; the launcher and the writer verify the directory is owned by the user and not a symlink, and otherwise run Ghostty without a per-window config. Reported by the Omarchy marketplace review.

## 1.3.0 — 2026-10-09
- Hide wallpapers from the Moods and Wallpapers strips: right-click a tile, `X` on the Moods tab, or `ombre hide PATH`. Files are never touched; `H` or "Show hidden" brings them back.
- Mouse: hovering a tint dot previews on its own card without moving the selection; clicking selects.
- `ombre --version`, a test suite (`node --test tests/`) and CI.

## 1.2.0 — 2026-10-09
- Project folders: a terminal working inside a rule's folder gets that project's look and wallpaper automatically (`F`, Projects tab, `ombre project ...`).
- `~/Wallpapers/Ombre/` is listed first in the Wallpapers tab.

## 1.1.0 — 2026-10-09
- Renamed from Terminal Tint to Ombre.
- Spotlight: the desktop dims around the selected terminal while the picker is open.
- Text shadow for Ghostty windows (`T`).
- A default look for new terminals (`D`).
- Focus stays visible on tinted windows; smoother spotlight; no stuck pulse colours.
- Aether and Ghostty are detected and their absence explained; `ombre --check`.
- Fewer helper processes per picker open; gentler pulse clock.

## 1.0.0 — 2026-10-08
- Pulse a terminal's border when its agent finishes or rings the bell.

## 0.3.0 — 2026-10-08
- Ghostty wallpapers per terminal; first-run notice.

## 0.2.0 — 2026-10-08
- Aether moods and Omarchy themes per terminal.

## 0.1.0 — 2026-10-08
- Picker with live previews; background tints and matching borders.
