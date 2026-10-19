// Ombre Matrix rain. The terminal input uses alpha to keep glyphs crisp.
const float SIZE = 20.0;
const float BLUR = 1.0;
const float OPACITY = 0.25;
const float SPEED = 1.0;
const float DENSITY = 0.55;
const float PAUSED = 0.0;
const float KEEP_ALPHA = 0.0;
float hash21(vec2 p) { return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453); }
float glyph(vec2 p, float seed) {
  vec2 g=floor(p*vec2(5.0,7.0));
  vec2 f=fract(p*vec2(5.0,7.0));
  float bit=step(0.46,hash21(g+seed));
  float edge=step(0.12,f.x)*step(f.x,0.85)*step(0.12,f.y)*step(f.y,0.85);
  return bit*edge*step(0.0,p.x)*step(p.x,1.0)*step(0.0,p.y)*step(p.y,1.0);
}
vec3 rain(vec2 p) {
  vec2 grid=vec2(p.x,iResolution.y-p.y)/vec2(SIZE*0.72,SIZE);
  float column=floor(grid.x);
  float h=hash21(vec2(column,1.0));
  if(h>DENSITY) return vec3(0.0);
  float time=(PAUSED>0.5?0.0:iTime)*SPEED;
  float cycle=36.0+floor(h*36.0);
  float head=mod(time*(4.0+h*9.0)+h*200.0,cycle);
  float row=floor(grid.y);
  float age=mod(head-row+cycle,cycle);
  float trail=pow(max(0.0,1.0-age/18.0),2.0);
  float seed=column*83.0+row*7.0+floor(time*2.0+h*10.0);
  float ink=glyph((fract(grid)-vec2(0.12,0.08))/vec2(0.76,0.84),seed);
  vec3 color=mix(vec3(0.015,0.8,0.16),vec3(0.7,1.0,0.8),1.0-smoothstep(0.0,1.5,age));
  return color*trail*ink;
}
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec4 p=texelFetch(iChannel0,clamp(ivec2(fragCoord),ivec2(0),ivec2(iResolution.xy)-1),0);
  vec3 r=rain(fragCoord)*0.4;
  r+=(rain(fragCoord+vec2(BLUR,0.0))+rain(fragCoord-vec2(BLUR,0.0))
     +rain(fragCoord+vec2(0.0,BLUR))+rain(fragCoord-vec2(0.0,BLUR)))*0.15;
  float background=clamp((1.0-p.a)*2.0,0.0,1.0);
  vec3 color=p.rgb/max(p.a,0.001)+r*OPACITY*background;
  fragColor=KEEP_ALPHA>0.5?vec4(color*p.a,p.a):vec4(color,1.0);
}
