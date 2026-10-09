// Ombre: a soft drop shadow under light text on a dark background.
// The shader can't see the text layer, so it looks a little up and to the left
// of each pixel: where that is much brighter than here, text sits there and
// this pixel is in its shadow.
const vec3 LUMA = vec3(0.299, 0.587, 0.114);

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / iResolution.xy;
  vec2 px = 1.0 / iResolution.xy;
  vec4 here = texture(iChannel0, uv);
  float lum = dot(here.rgb, LUMA);
  vec2 o = vec2(-2.5, 2.5) * px;
  float above = 0.0;
  above += dot(texture(iChannel0, uv + o).rgb, LUMA);
  above += dot(texture(iChannel0, uv + o + vec2(-px.x * 1.5, 0.0)).rgb, LUMA);
  above += dot(texture(iChannel0, uv + o + vec2(0.0, px.y * 1.5)).rgb, LUMA);
  above += dot(texture(iChannel0, uv + o * 0.55).rgb, LUMA);
  above *= 0.25;
  float shade = smoothstep(0.08, 0.45, above - lum) * 0.95;
  fragColor = vec4(here.rgb * (1.0 - shade), here.a);
}
