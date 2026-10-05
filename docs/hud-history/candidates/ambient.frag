#version 440
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
  mat4 qt_Matrix; float qt_Opacity;
  float uTime; float uLoad; float uMem; float uAlert; float uPulse; vec2 uRes;
};
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void main() {
  // uv from gl_FragCoord — no vertex-stage texcoord needed,
  // which removes the qt_TexCoord0 link dependency entirely.
  vec2 uv = gl_FragCoord.xy / uRes; uv.y = 1.0 - uv.y;
  float asp = uRes.x / max(uRes.y, 1.0);
  vec2 p = vec2(uv.x * asp, uv.y);
  float t = uTime;
  // staggered drifting grid — horizontal runs + offset verticals
  vec2 gp = p * vec2(22.0, 22.0) + vec2(t * 0.045, t * 0.022);
  vec2 cell = fract(gp) - 0.5;
  vec2 id = floor(gp);
  float hline = 1.0 - smoothstep(0.0, 0.045, abs(cell.y));
  float vline = 1.0 - smoothstep(0.0, 0.045, abs(fract(gp.x + 0.5 * mod(id.y, 2.0)) - 0.5));
  float node = 1.0 - smoothstep(0.0, 0.06, length(cell));
  float gate = step(0.55, hash(id));
  float grid = (hline * 0.6 + vline * 0.4 + node * 0.5) * (0.5 + 0.5 * gate);
  // pulses travelling along grid rows
  float row = id.y;
  float spd = 0.10 + 0.30 * hash(vec2(row, 7.3));
  float ph = fract(hash(vec2(row, 3.1)) + t * spd);
  float pulse = exp(-42.0 * abs(fract(gp.x / 22.0) - ph)) * hline * gate;
  // two slow plasma blooms
  vec2 c1 = vec2(0.24 * asp + 0.05 * sin(t * 0.10), 0.30 + 0.06 * cos(t * 0.08));
  vec2 c2 = vec2(0.76 * asp + 0.06 * cos(t * 0.06), 0.70 + 0.05 * sin(t * 0.11));
  float b1 = exp(-6.5 * length(p - c1));
  float b2 = exp(-7.0 * length(p - c2));
  // palette
  vec3 cyan = vec3(0.0, 0.55, 0.68);
  vec3 green = vec3(0.10, 0.60, 0.20);
  vec3 mag = vec3(0.55, 0.08, 0.42);
  vec3 red = vec3(0.70, 0.10, 0.14);
  float loadK = 0.45 + 0.75 * clamp(uLoad, 0.0, 1.0);
  vec3 col = vec3(0.004, 0.012, 0.020);
  col += cyan * grid * (0.045 + 0.055 * loadK);
  col += mix(cyan, green, 0.5) * pulse * 0.16;
  col += cyan * b1 * (0.045 + 0.075 * uLoad) + mag * b2 * (0.035 + 0.06 * uMem);
  // alert wash lerps the field toward red
  col = mix(col, red * (0.05 + grid * 0.10 + b1 * 0.10), clamp(uAlert, 0.0, 1.0) * 0.85);
  // faint vertical shimmer + breathing global gain
  col *= 0.94 + 0.06 * sin(uv.y * uRes.y * 0.7854) + 0.04 * uPulse;
  float vig = smoothstep(1.15, 0.35, length((uv - 0.5) * vec2(1.15, 0.95)));
  col *= vig;
  // mostly-opaque near-black field — wallpaper still ghosts through
  fragColor = vec4(col, 0.85 * qt_Opacity);
}
