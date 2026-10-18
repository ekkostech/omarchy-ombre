// Ombre glass: cells with their own background colour (Claude's message band,
// Codex blocks, selections, status bars) become frosted glass over the wallpaper.
//
// Ombre runs the window with background-opacity A and background-opacity-cells,
// so the frame tells the layers apart by alpha: A on the plain background,
// A + A(1 - A) where a cell paints its own background over it, and more on
// text. Colour is premultiplied, so dividing a cell pixel by what the cell let
// through gives the wallpaper behind it plus the cell's colour. Blurring and
// tinting that turns a dark cell into smoked glass and a coloured one into
// tinted glass. Everything comes back opaque, so the window stays solid.
//
// What keeps the glass clean:
// - Every sample is one whole texel (texelFetch): a bilinear tap half on a glyph
//   can land on the cell alpha and smear text colour into the glass.
// - Text over the plain background reaches the cell alpha at its antialiased
//   edges, so a pixel only counts as glass when its neighbourhood is mostly cells.
// - The blur only mixes cells of the same colour (an edge-preserving weight on
//   the raw pixel), so a green diff line never bleeds into the red one below.
// - Text over glass keeps its glyph and swaps the cell under it for the glass,
//   with coverage (alpha - cell) / (1 - cell), so letters get no fringe of
//   sharp wallpaper.
// And what makes it read as glass: the backdrop a little more saturated (as
// Apple's and Hyprland's blur do), a soft rim lit from the top left with shade
// on the far side, corners rounded by a few pixels, and a fine dither against
// banding in dark gradients.
//
// Ghostty shaders take no settings, so bin/ombre-glass writes each window its
// own copy with TINT, AMOUNT and RADIUS filled in from Ombre's Glass controls.
const float A = 0.5;                       // background-opacity Ombre sets with glass
const float CELL = A + A * (1.0 - A);      // alpha of a cell background
const vec3 TINT = vec3(0.0);               // glass colour, in linear light
const float AMOUNT = 0.86;                 // how much the colour covers the wallpaper (0.86 reads about 60%)
const float RADIUS = 36.0;                 // blur radius in pixels
const int TAPS = 72;
const float SAME = 0.07;                   // how far a raw cell colour may differ and still blend
const float VIBRANCY = 1.25;               // saturation of what shows through the glass
const float RIM = 5.0;                     // width of the lit rim, and the corner rounding, in pixels
const float LIGHT = 0.07;                  // rim highlight toward the light
const float SHADE = 0.25;                  // rim shade on the far side, as a share of the glass
const vec2 TOWARD_LIGHT = vec2(-0.447, 0.894);   // up and to the left; Ghostty's y grows upward
const float DITHER = 0.006;

bool isCell(float a) { return abs(a - CELL) < 0.012; }

vec4 at(vec2 fragCoord, vec2 offset) {
  ivec2 p = clamp(ivec2(floor(fragCoord + offset)), ivec2(0), ivec2(iResolution.xy) - 1);
  return texelFetch(iChannel0, p, 0);
}

// Interleaved gradient noise: an even, blue-ish per-pixel value.
float ign(vec2 p) { return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec4 p = at(fragCoord, vec2(0.0));
  vec3 plain = p.rgb / max(p.a, 0.001);
  bool cell = isCell(p.a);
  if (!cell && p.a < CELL + 0.02) { fragColor = vec4(plain, 1.0); return; }

  // A ring around the pixel: how much of it is the block (cells, or text drawn
  // on them; inside, at a rim, at a corner), which way the block lies, and the
  // raw colour of its cells.
  float inside = 0.0, cells = 0.0;
  vec2 inward = vec2(0.0);
  vec3 ref = vec3(0.0);
  for (int i = 0; i < 16; i++) {
    float t = float(i) * 0.39269908;
    vec2 dir = vec2(cos(t), sin(t));
    for (int k = 1; k <= 2; k++) {
      vec4 q = at(fragCoord, dir * RIM * float(k) * 0.5);
      if (isCell(q.a)) { cells += 1.0; ref += q.rgb; }
      if (q.a > CELL - 0.012) { inside += 1.0; inward += dir; }
    }
  }
  // Text over the plain background, a stray text edge, or a rounded-off corner.
  if (cells < 4.0 || cells / 32.0 < 0.2 || inside / 32.0 < 0.3) { fragColor = vec4(plain, 1.0); return; }
  ref = cell ? p.rgb : ref / cells;
  inside /= 32.0;

  // Frosted: a gaussian-weighted golden-angle spiral over the cells of the same
  // colour, skipping text and the plain background.
  float turn = ign(fragCoord) * 6.2831853;
  vec3 sum = vec3(0.0);
  float weight = 0.0;
  for (int i = 0; i < TAPS; i++) {
    float r = sqrt((float(i) + 0.5) / float(TAPS)) * RADIUS;
    float t = float(i) * 2.39996323 + turn;
    vec4 q = at(fragCoord, vec2(cos(t), sin(t)) * r);
    if (!isCell(q.a)) continue;
    vec3 d = q.rgb - ref;
    float k = (RADIUS > 0.5 ? exp(-2.0 * (r * r) / (RADIUS * RADIUS)) : 1.0) * exp(-dot(d, d) / (SAME * SAME));
    sum += q.rgb / (1.0 - q.a) * k;
    weight += k;
  }
  vec3 behind = weight > 0.001 ? sum / weight : ref / (1.0 - CELL);
  float luma = dot(behind, vec3(0.2126, 0.7152, 0.0722));
  behind = max(mix(vec3(luma), behind, VIBRANCY), 0.0);
  vec3 glass = mix(behind, TINT, AMOUNT);

  // The rim: where the ring is only partly cells, light on the side facing the
  // light and shade on the other.
  float rim = 1.0 - smoothstep(0.55, 0.9, inside);
  if (rim > 0.0 && dot(inward, inward) > 0.0) {
    vec2 n = normalize(inward);
    glass += rim * LIGHT * max(dot(-n, TOWARD_LIGHT), 0.0);
    glass *= 1.0 - rim * SHADE * max(dot(n, TOWARD_LIGHT), 0.0);
  }
  glass = max(glass + (ign(fragCoord + 71.0) - 0.5) * DITHER, 0.0);

  // Text over glass: keep the glyph, swap the cell under it for the glass.
  vec3 color = glass;
  if (!cell) {
    float cover = clamp((p.a - CELL) / (1.0 - CELL), 0.0, 1.0);
    color = clamp(p.rgb + (1.0 - cover) * (glass - ref), 0.0, 1.0);
  }
  fragColor = vec4(color, 1.0);
}
