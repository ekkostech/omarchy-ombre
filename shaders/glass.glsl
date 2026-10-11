// Ombre glass: cells with their own background colour (Claude's message band,
// Codex blocks, selections, status bars) become frosted glass over the wallpaper.
//
// Ombre runs the window with background-opacity A and background-opacity-cells,
// so the frame tells the layers apart by alpha: A on the plain background,
// A + A(1 - A) where a cell paints its own background over it, and more on
// text. Colour is premultiplied, so dividing a cell pixel by what the cell let
// through gives the wallpaper behind it plus the cell's colour. Blurring and
// darkening that turns a dark cell into dark frosted glass and a coloured one
// into tinted glass. Everything comes back opaque, so the window stays solid.
const float A = 0.5;                       // background-opacity Ombre sets with glass
const float CELL = A + A * (1.0 - A);      // alpha of a cell background
const float DARK = 0.68;                   // how dark the glass is (0 clear, 1 black)
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
    float k = exp(-2.0 * (r * r) / (RADIUS * RADIUS));
    sum += q.rgb / (1.0 - q.a) * k;
    weight += k;
  }
  vec3 behind = weight > 0.0 ? sum / weight : p.rgb / (1.0 - p.a);
  fragColor = vec4(behind * (1.0 - DARK), 1.0);
}
