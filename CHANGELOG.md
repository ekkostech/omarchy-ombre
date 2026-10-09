# Changelog

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
