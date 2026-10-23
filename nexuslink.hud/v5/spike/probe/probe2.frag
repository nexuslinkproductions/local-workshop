#version 440

// Probe 2: invert the sRGB decode Qt applies to an 8 bit image texture on Metal,
// so packed integers survive. Reads a 1x1 calibration texture (byte 128) to
// decide whether the platform decoded at all, then reads the data texture and
// writes back floor(byte) in three channels for the four quadrants.
// Expected bytes: see mkprobe16.py (R=133, G=200, B=7).

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 u_texSize;
    vec2 u_calSize;
};

layout(binding = 1) uniform sampler2D u_tex;
layout(binding = 2) uniform sampler2D u_cal;

vec3 invSrgb(vec3 c)
{
    vec3 lo = c * 12.92;
    vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(lo, hi, step(vec3(0.0031308), c));
}

void main()
{
    vec2 q = step(vec2(0.5), qt_TexCoord0);
    vec2 pick = mix(vec2(3.5, 3.5), u_texSize - vec2(3.5), q);
    vec4 t = texture(u_tex, pick / u_texSize);
    float cal = texture(u_cal, vec2(0.5) / u_calSize).r;
    float inv = step(cal, 0.35);            // decoded (0.216) -> invert, raw (0.502) -> leave
    vec3 raw = t.rgb;
    vec3 rgb = mix(raw, invSrgb(raw), inv);
    fragColor = vec4(floor(rgb * 255.0 + 0.5) / 255.0, 1.0);
}
