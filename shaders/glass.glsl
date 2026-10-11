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
// Ghostty shaders take no settings, so bin/ombre-glass writes each window its
// own copy with TINT, AMOUNT and RADIUS filled in from Ombre's Glass controls.
const float A = 0.5;                       // background-opacity Ombre sets with glass
const float CELL = A + A * (1.0 - A);      // alpha of a cell background
const vec3 TINT = vec3(0.0);               // glass colour, in linear light
const float AMOUNT = 0.86;                 // how much the colour covers the wallpaper (0.86 reads about 60%)
const float RADIUS = 36.0;                 // blur radius in pixels
const int TAPS = 80;

bool isCell(float a) { return abs(a - CELL) < 0.03; }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / iResolution.xy;
  vec4 p = texture(iChannel0, uv);
  if (!isCell(p.a)) {
    fragColor = vec4(p.rgb / max(p.a, 0.001), 1.0);
    return;
  }
  // Frosted: average what's behind the cells over a disc (golden-angle
  // spiral), skipping text and the plain background. A fixed per-pixel turn
  // of the spiral trades banding for a fine grain.
  vec2 px = 1.0 / iResolution.xy;
  float turn = fract(sin(dot(fragCoord, vec2(12.9898, 78.233))) * 43758.5453) * 6.2831853;
  vec3 sum = vec3(0.0);
  float weight = 0.0;
  for (int i = 0; i < TAPS; i++) {
    float r = sqrt((float(i) + 0.5) / float(TAPS)) * RADIUS;
    float t = float(i) * 2.39996323 + turn;
    vec4 q = texture(iChannel0, uv + vec2(cos(t), sin(t)) * r * px);
    if (!isCell(q.a)) continue;
    float k = RADIUS > 0.5 ? exp(-2.0 * (r * r) / (RADIUS * RADIUS)) : 1.0;
    sum += q.rgb / (1.0 - q.a) * k;
    weight += k;
  }
  vec3 behind = weight > 0.0 ? sum / weight : p.rgb / (1.0 - p.a);
  fragColor = vec4(mix(behind, TINT, AMOUNT), 1.0);
}
